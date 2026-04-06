#!/bin/bash -e

# Цветовые переменные для вывода в консоль
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
export branch_name
# Список необходимых зависимостей
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)"
ndkver="android-ndk-r30-beta1"
ndk="$HOME/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="35"
mesasrc="https://github.com/Tornado6896/mesa-tu8.git"
srcfolder="$branch_name"

declare -A BRANCHES=(
    [1]="a825"
    [2]="a829"
)

# Функция отображения меню
show_menu() {
    echo "Доступные ветки для сборки драйвера:"
    for key in "${!BRANCHES[@]}"; do
        echo "$key ${BRANCHES[$key]}"
    done | sort -k1 -n
}

# Функция выбора ветки
choose_branch() {
    local branch_name=""
    while [[ -z "$branch_name" ]]; do
        show_menu
        read -p "Введите номер или название ветки: " choice

        # Проверка, является ли ввод номером
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ -n "${BRANCHES[$choice]}" ]]; then
            branch_name="${BRANCHES[$choice]}"
        # Проверка, является ли ввод названием ветки
        elif [[ "$choice" == "a825" || "$choice" == "a829" ]]; then
            branch_name="$choice"
        else
            echo "Ошибка: неверный выбор. Пожалуйста, введите 1, 2, 825 или 829."
            echo
        fi
    done

    echo "Вы выбрали ветку: $branch_name"
	
	# read -p "Подтвердите выбор (y/n): " confirm
    # if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    #     echo "Выход."
    #     exit 0
    # fi 
	
#SELECTED_BRANCH="$branch_name"
srcfolder="$branch_name"
   # echo "Переменная SELECTED_BRANCH установлена в '$SELECTED_BRANCH'"
}

# Запуск выбора
choose_branch
    # Экспортируем переменную для использования в других скриптах


read -p "Введите номер сборки: " BUILD_VERSION

clear

run_all(){
	echo "====== Начало сборки TU v-$BUILD_VERSION ! ======"
	check_deps
	prepare_workdir
	build_lib_for_android $srcfolder
}

check_deps(){
	echo "Проверка системных зависимостей..."
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
	pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Подготовка рабочей директории..."
	mkdir -p "$workdir" && cd "$workdir"

	#echo "Загрузка Android NDK r31..."
	#curl -L https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	#echo "Распаковка NDK..."
	#unzip -q "$ndkver"-linux.zip &> /dev/null

	echo "Клонирование исходного кода Mesa..."
	rm -rf $srcfolder
	git clone --branch $srcfolder --depth=1 $mesasrc $srcfolder
	cd $srcfolder
	
	echo "Запись версии TU..."
	echo "#define TUGEN8_DRV_VERSION \"v $BUILD_VERSION\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_android(){
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
	meson setup build-android-aarch64 \
		--cross-file "android-aarch64.txt" \
		--native-file "native.txt" \
		--prefix /tmp/turnip-$srcfolder \
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
		-Dperfetto=true \
		-Dandroid-libbacktrace=disabled \
		--reconfigure

	echo "Компиляция через Ninja (это займет время)..."
	ninja -C build-android-aarch64 install

	if [ ! -f /tmp/turnip-$srcfolder/lib/libvulkan_freedreno.so ]; then
		echo -e "$red Ошибка сборки! Библиотека .so не найдена. $nocolor" && exit 1
	fi

	echo "Создание архива с драйвером..."
	cd /tmp/turnip-$srcfolder/lib
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "$srcfolder turnip-v$BUILD_VERSION",
  "description": "Сборка для Adreno $srcfolder. Ветка: $srcfolder",
  "author": "Tornado6896",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
	zip $workdir/$srcfolder"-turnip-v"$BUILD_VERSION.zip libvulkan_freedreno.so meta.json
	cd -
	
	if [ -f $workdir/$srcfolder"-turnip-v"$BUILD_VERSION.zip ]; then
		echo -e "$green Архив успешно создан: $workdir/$srcfolder"-turnip-v"$BUILD_VERSION.zip $nocolor"
	else
		echo -e "$red Не удалось упаковать архив! $nocolor"
	fi
}

run_all