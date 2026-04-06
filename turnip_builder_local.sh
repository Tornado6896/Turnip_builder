#!/bin/bash -e

# Цветовые переменные для вывода в консоль
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Список необходимых зависимостей
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)"
ndkver="android-ndk-r27c"                 # стабильная версия NDK
ndk="$HOME/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="31"                               # стабильный API level
mesasrc="https://github.com/Tornado6896/mesa-tu8.git"

declare -A BRANCHES=(
    [1]="a825"
    [2]="a829"
)

# Функция отображения меню
show_menu() {
    echo "Доступные ветки для сборки драйвера:"
    for key in "${!BRANCHES[@]}"; do
        echo "$key) ${BRANCHES[$key]}"
    done | sort -k1 -n
}

# Функция выбора ветки (возвращает выбранное имя через echo)
choose_branch() {
    local branch_name=""
    while [[ -z "$branch_name" ]]; do
        show_menu
        read -p "Введите номер или название ветки: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ -n "${BRANCHES[$choice]}" ]]; then
            branch_name="${BRANCHES[$choice]}"
        elif [[ "$choice" == "a825" || "$choice" == "a829" ]]; then
            branch_name="$choice"
        else
            echo "Ошибка: неверный выбор. Пожалуйста, введите 1, 2, a825 или a829."
            echo
        fi
    done
    echo "$branch_name"
}

# Выбор ветки
SELECTED_BRANCH=$(choose_branch)
echo "Вы выбрали ветку: $SELECTED_BRANCH"

read -p "Введите номер сборки: " BUILD_VERSION

clear

run_all(){
    echo "====== Начало сборки TU v$BUILD_VERSION ! ======"
    check_deps
    prepare_workdir
    build_lib_for_android "$SELECTED_BRANCH"
}

check_deps(){
    echo "Проверка системных зависимостей..."
    local deps_missing=0
    for deps_chk in $deps; do
        sleep 0.1
        if command -v "$deps_chk" >/dev/null 2>&1 ; then
            echo -e "$green - $deps_chk найдено $nocolor"
        else
            echo -e "$red - $deps_chk НЕ найдено, продолжение невозможно. $nocolor"
            deps_missing=1
        fi
    done

    if [ "$deps_missing" == "1" ]; then 
        echo "Пожалуйста, установите недостающие пакеты." && exit 1
    fi

    echo "Установка зависимости python Mako..."
    pip install --user mako &> /dev/null || echo "Предупреждение: не удалось установить mako, возможно, он уже установлен."
}

prepare_workdir(){
    echo "Подготовка рабочей директории..."
    mkdir -p "$workdir" && cd "$workdir"

    # Проверка наличия NDK
    if [ ! -d "$HOME/$ndkver" ]; then
        echo -e "$red NDK $ndkver не найден в $HOME/$ndkver. Пожалуйста, установите его. $nocolor"
        exit 1
    fi

    echo "Клонирование исходного кода Mesa (ветка $1)..."
    # Удаляем старую папку, если она есть
    rm -rf "$1"
    git clone --branch "$1" --depth 1 "$mesasrc" "$1"
    cd "$1"
    
    echo "Запись версии TU..."
    echo "#define TUGEN8_DRV_VERSION \"v$BUILD_VERSION\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_android(){
    local branch="$1"
    echo "==== Сборка Mesa на ветке $branch ===="

    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    echo "Генерация файлов кросс-компиляции..."
    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    echo "Настройка Meson (LTO отключен для стабильности)..."
    meson setup build-android-aarch64 -Dperfetto=true \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-$branch" \
        -Dbuildtype=release \
        -Db_lto=false \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled \
        --reconfigure

    echo "Компиляция через Ninja (это займет время)..."
    ninja -C build-android-aarch64 install

    if [ ! -f "/tmp/turnip-$branch/lib/libvulkan_freedreno.so" ]; then
        echo -e "$red Ошибка сборки! Библиотека .so не найдена. $nocolor" && exit 1
    fi

    echo "Создание архива с драйвером..."
    cd "/tmp/turnip-$branch/lib"
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "$branch turnip-v$BUILD_VERSION",
  "description": "Сборка для Adreno $branch. Ветка: $branch",
  "author": "Tornado6896",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    zip "$workdir/$branch-turnip-v$BUILD_VERSION.zip" libvulkan_freedreno.so meta.json
    cd -
    
    if [ -f "$workdir/$branch-turnip-v$BUILD_VERSION.zip" ]; then
        echo -e "$green Архив успешно создан: $workdir/$branch-turnip-v$BUILD_VERSION.zip $nocolor"
    else
        echo -e "$red Не удалось упаковать архив! $nocolor"
    fi
}

run_all