#!/bin/bash -e

# Цветовые переменные для вывода в консоль
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Список необходимых зависимостей (добавлен ccache)
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator ccache"
workdir="$(pwd)"
ndkver="android-ndk-r29"
ndk="$HOME/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="35"

# Доступные репозитории
declare -A REPOS=(
	[1]="https://github.com/Tornado6896/mesa.git"
	[2]="https://gitlab.freedesktop.org/mesa/mesa.git"
)

# Доступные ветки (зависят от репозитория, но для простоты оставим общие)
declare -A BRANCHES=(
    [1]="a825"
    [2]="main"
)

# Функция выбора репозитория
choose_repo() {
    echo "Доступные репозитории:"
    for key in "${!REPOS[@]}"; do
        echo "$key) ${REPOS[$key]}"
	done | sort -k1 -n

    read -p "Выберите номер репозитория (по умолчанию 1): " repo_choice
    repo_choice=${repo_choice:-1}
    if [[ -n "${REPOS[$repo_choice]}" ]]; then
        mesasrc="${REPOS[$repo_choice]}"
    else
        echo "Неверный выбор, используется репозиторий по умолчанию"
        mesasrc="${REPOS[1]}"
    fi
    echo "Выбран репозиторий: $mesasrc"
}

# Функция отображения меню веток
show_menu() {
    echo "Доступные ветки для сборки драйвера:"
    for key in "${!BRANCHES[@]}"; do
        echo "$key) ${BRANCHES[$key]}"
    done | sort -k1 -n
}

# Функция выбора ветки (глобальная переменная branch_name)
choose_branch() {
    # Не используем local, чтобы переменная стала глобальной
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

    echo "Вы выбрали ветку: $branch_name"
    srcfolder="$branch_name"
}

# Выбор репозитория и ветки
choose_repo
choose_branch

read -p "Введите номер сборки: " BUILD_VERSION
read -p "Введите Описание: " descr
clear

run_all() {
    echo "====== Начало сборки TU $BUILD_VERSION ! ======"
    check_deps
    prepare_workdir
    build_lib_for_android
}

check_deps() {
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
    pip install --user mako &> /dev/null
}

prepare_workdir() {
    echo "Подготовка рабочей директории..."
    mkdir -p "$workdir" && cd "$workdir"

    # Проверяем, что srcfolder не пуст, перед удалением
    if [ -n "$srcfolder" ]; then
        rm -rf "$srcfolder"
    else
        echo "Ошибка: имя ветки не определено" && exit 1
    fi

    echo "Клонирование исходного кода Mesa из $mesasrc (ветка $srcfolder)..."
    git clone --branch "$srcfolder" --depth=1 "$mesasrc" "$srcfolder"
    cd "$srcfolder"
	
    echo "Запись версии TU..."
    echo "#define TUGEN8_DRV_VERSION \"$BUILD_VERSION\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_android() {
    echo "==== Сборка Mesa на ветке $srcfolder ===="

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
    if command -v ccache >/dev/null 2>&1; then
        CCACHE_PREFIX="ccache"
    else
        CCACHE_PREFIX=""
        echo "ccache не найден, компиляция будет без кэширования."
    fi

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = [${CCACHE_PREFIX:+"'$CCACHE_PREFIX',"} '$ndk/aarch64-linux-android$sdkver-clang']
cpp = [${CCACHE_PREFIX:+"'$CCACHE_PREFIX',"} '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
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
c = [${CCACHE_PREFIX:+"'$CCACHE_PREFIX',"} 'clang']
cpp = [${CCACHE_PREFIX:+"'$CCACHE_PREFIX',"} 'clang++']
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
    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/Turnip-$srcfolder" \
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

if [[ "${repo_choice}" == "2" ]]; then
    # Копируем подготовленные файлы
    cp "$workdir/patches/freedreno_devices.py" src/freedreno/common/freedreno_devices.py
    cp "$workdir/patches/freedreno_noop.c" src/freedreno/drm-shim/freedreno_noop.c
    echo "Файлы для A825 заменены."
fi

    echo "Компиляция через Ninja (это займет время)..."
    ninja -C build-android-aarch64 install

    if [ ! -f "/tmp/Turnip-$srcfolder/lib/libvulkan_freedreno.so" ]; then
        echo -e "$red Ошибка сборки! Библиотека .so не найдена. $nocolor" && exit 1
    fi

    echo "Создание архива с драйвером..."
    cd "/tmp/Turnip-$srcfolder/lib"
	
    VULKAN_HEADER="$workdir/$srcfolder/include/vulkan/vulkan_core.h"

    # Извлекаем номер версии (например, 335)
    if [ -f "$VULKAN_HEADER" ]; then
        VK_HEADER_VERSION=$(grep -oP '#define VK_HEADER_VERSION \K\d+' "$VULKAN_HEADER")
        
        if [ -n "$VK_HEADER_VERSION" ]; then
            # Формируем версию "1.4.335"
            VULKAN_VERSION="1.4.$VK_HEADER_VERSION"
        else
            echo "Не удалось определить VK_HEADER_VERSION. Используется версия по умолчанию."
            VULKAN_VERSION="1.4.335"
        fi
    else
        echo "Файл vulkan_core.h не найден. Используется версия по умолчанию."
        VULKAN_VERSION="1.4.335"
    fi

    # Используем полученную версию при создании meta.json
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip $srcfolder $BUILD_VERSION",
  "description": "$descr",
  "author": "Tornado6896",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan $VULKAN_VERSION",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    # Исправленные кавычки для имени архива
    zip "$workdir/$srcfolder Turnip $BUILD_VERSION.zip" libvulkan_freedreno.so meta.json
    cd -
    
    if [ -f "$workdir/$srcfolder Turnip $BUILD_VERSION.zip" ]; then
        echo -e "$green Архив успешно создан: $workdir/$srcfolder Turnip $BUILD_VERSION.zip $nocolor"
    else
        echo -e "$red Не удалось упаковать архив! $nocolor"
    fi
}

run_all
