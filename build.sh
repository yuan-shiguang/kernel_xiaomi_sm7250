#!/usr/bin/env bash
#
#  build.sh - Automatic kernel building script
#
#  Copyright (C) 2021-2023, Crepuscular's AOSP WorkGroup
#  Author: EndCredits <alicization.han@gmail.com>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License version 2 as
#  published by the Free Software Foundation.
#
#  Add clang to your PATH before using this script.
#

# Ensure we run from the kernel source root (script's own directory)
cd "$(dirname "$0")" || { echo "Failed to cd to script directory"; exit 1; }

ARCH=arm64;
CC=clang;
LD=ld.lld
CLANG_TRIPLE=aarch64-linux-gnu-;
CROSS_COMPILE=aarch64-linux-gnu-;
CROSS_COMPILE_COMPAT=arm-linux-gnueabi-;
THREAD=$(nproc --all);
CC_ADDITION_FLAGS="LD=$LD";
OUT="../out";

TARGET_KERNEL_FILE=arch/arm64/boot/Image;
TARGET_KERNEL_DTB=arch/arm64/boot/dtb;
TARGET_KERNEL_DTBO=arch/arm64/boot/dtbo.img
TARGET_KERNEL_NAME=LineageOS-Kernel;

DEFCONFIG_PATH=arch/arm64/configs
DEFCONFIG_NAME=vendor/picasso_user_defconfig;
DISABLE_KSU_FRAGMENT=vendor/disable_ksu.config;

# Extract CONFIG_LOCALVERSION value: anchor to line start, take first match,
# strip quotes and any surrounding whitespace.
LOCAL_VERSION_NUMBER=$(grep '^CONFIG_LOCALVERSION=' "$DEFCONFIG_PATH/$DEFCONFIG_NAME" \
    | head -n 1 \
    | cut -d = -f 2 \
    | sed 's/"//g' \
    | tr -d '[:space:]')
[ -z "$LOCAL_VERSION_NUMBER" ] && LOCAL_VERSION_NUMBER="unknown"
TARGET_KERNEL_MOD_VERSION=$(make kernelversion 2>/dev/null)-$LOCAL_VERSION_NUMBER;

START_SEC=$(date +%s);
CURRENT_TIME=$(date '+%Y%m%d-%H%M');

ANYKERNEL_URL=https://codeload.github.com/yuan-shiguang/AnyKernel3/zip/refs/heads/picasso;
ANYKERNEL_PATH=AnyKernel3-picasso;
ANYKERNEL_FILE=anykernel.zip;

WITH_KERNELSU=1

link_all_dtb_files(){
    local dtb_dir="$OUT/arch/arm64/boot/dts/vendor/qcom"
    if [ ! -d "$dtb_dir" ]; then
        echo "Warning: dtb directory $dtb_dir not found, skipping dtb link"
        return 1
    fi
    find "$dtb_dir" -name '*.dtb' -exec cat {} + > "$OUT/arch/arm64/boot/dtb"
}

pack_dtbo_img(){
    echo "------------------------------";
    echo " Packing dtbo.img ............";
    echo "------------------------------";

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 not found, cannot pack dtbo.img"
        return 1
    fi

    local dts_makefile=arch/arm64/boot/dts/vendor/qcom/Makefile
    local dtbo_dir="$OUT/arch/arm64/boot/dts/vendor/qcom"
    local dtbo_img="$OUT/arch/arm64/boot/dtbo.img"
    local dtbos=() name

    # Only pack overlays enabled for this platform. A plain "find *.dtbo"
    # would also pick up stale overlays left by previously enabled platforms
    # (e.g. lagoon) and produce a wrong image.
    while read -r name; do
        [ -n "$name" ] || continue
        if [ -f "$dtbo_dir/$name" ]; then
            dtbos+=("$dtbo_dir/$name")
        else
            echo " Warning: compiled overlay $name not found, skipped"
        fi
    done < <(sed -n '/^dtbo-\$(CONFIG_ARCH_LITO)/,/^$/p' "$dts_makefile" \
             | grep -oE '[A-Za-z0-9_.-]+\.dtbo' | sort -u)

    if [ "${#dtbos[@]}" -eq 0 ]; then
        echo "Error: no compiled LITO *.dtbo found under $dtbo_dir"
        return 1
    fi

    # Same invocation as the upstream EndCredits tree (cmd_mkdtimg):
    # official AOSP mkdtboimg.py create --page_size=4096, id/rev/custom = 0.
    python3 scripts/mkdtboimg.py create "$dtbo_img" \
        --page_size=4096 "${dtbos[@]}" || return 1
    echo " dtbo.img: $dtbo_img ($(stat -c %s "$dtbo_img") bytes, ${#dtbos[@]} entries)"
}

make_defconfig(){
    echo "------------------------------";
    echo " Building Kernel Defconfig..";
    echo "------------------------------";

    if [ "$WITH_KERNELSU" = "0" ]; then
        DEFCONFIG_NAME="$DEFCONFIG_NAME $DISABLE_KSU_FRAGMENT"
    fi

    make CC=$CC ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_COMPAT=$CROSS_COMPILE_COMPAT CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 $CC_ADDITION_FLAGS O=$OUT -j$THREAD $DEFCONFIG_NAME;
}

build_kernel(){
    echo "------------------------------";
    echo " Building Kernel ...........";
    echo "------------------------------";

    make CC=$CC ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_COMPAT=$CROSS_COMPILE_COMPAT CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 $CC_ADDITION_FLAGS O=$OUT -j$THREAD;
    END_SEC=$(date +%s);
    COST_SEC=$(( END_SEC - START_SEC ));
    echo "Kernel Build Costed $((COST_SEC/60))min $((COST_SEC%60))s"

}

generate_flashable(){
    echo "------------------------------";
    echo " Generating Flashable Kernel";
    echo "------------------------------";

    cd "$OUT" || { echo "Error: cannot cd to $OUT"; return 1; }
    
    if [ ! -d "$ANYKERNEL_PATH" ]; then
        echo ' Getting AnyKernel ';
        curl -fsSL "$ANYKERNEL_URL" -o "$ANYKERNEL_FILE" || { echo "Error: AnyKernel download failed"; return 1; }
        unzip -o "$ANYKERNEL_FILE" || { echo "Error: unzip failed"; return 1; }
    else
        echo ' Anykernel 3 Detected. Skipping download '
    fi

    echo ' Removing old package file ';
    rm -rf "$ANYKERNEL_PATH/$TARGET_KERNEL_NAME"*;

    echo ' Copying Kernel File '; 
    cp -r "$TARGET_KERNEL_FILE" "$ANYKERNEL_PATH/" || return 1;
    cp -r "$TARGET_KERNEL_DTB" "$ANYKERNEL_PATH/" || return 1;
    if [ -f "$TARGET_KERNEL_DTBO" ]; then
        cp -r "$TARGET_KERNEL_DTBO" "$ANYKERNEL_PATH/";
    else
        echo ' Warning: dtbo.img missing, keeping the ROM dtbo partition ';
    fi

    echo ' Packaging flashable Kernel ';
    cd "$ANYKERNEL_PATH" || return 1;
    local zip_name="$TARGET_KERNEL_NAME-$CURRENT_TIME-$TARGET_KERNEL_MOD_VERSION.zip"
    zip -q -r "$zip_name" ./*;
    if [ -f "$zip_name" ]; then
        echo " Target File:  $OUT/$ANYKERNEL_PATH/$zip_name ";
    else
        echo "Error: zip creation failed (is 'zip' installed?)"
        return 1
    fi
}

save_defconfig(){
    echo "------------------------------";
    echo " Saving kernel config ........";
    echo "------------------------------";

    make CC=$CC ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_COMPAT=$CROSS_COMPILE_COMPAT CLANG_TRIPLE=$CLANG_TRIPLE $CC_ADDITION_FLAGS O=$OUT -j$THREAD savedefconfig;
    END_SEC=$(date +%s);
    COST_SEC=$(( END_SEC - START_SEC ));
    echo "Finished. Kernel config saved to $OUT/defconfig"
    echo "Moving kernel defconfig to source tree"
    mkdir -p "$DEFCONFIG_PATH/$DEFCONFIG_NAME" 2>/dev/null
    mkdir -p "$(dirname "$DEFCONFIG_PATH/$DEFCONFIG_NAME")"
    mv "$OUT/defconfig" "$DEFCONFIG_PATH/$DEFCONFIG_NAME"
    echo "Kernel Config Build Costed $((COST_SEC/60))min $((COST_SEC%60))s"

}

clean(){
    echo "Clean source tree and build files..."
    # mrproper already implies clean
    make mrproper -j$THREAD;
    rm -rf "$OUT";
}

main(){
    if [ "${2:-}" = "noksu" ]; then
        echo "Building without Kernel SU"
        WITH_KERNELSU=0
    fi
    case "${1:-}" in
        help|-h)
            echo "build.sh: A very simple Kernel build helper"
            echo "usage: build.sh <operation> <optional argument>"
            echo
            echo "Build operations:"
            echo "    all             Perform a build without cleaning."
            echo "    cleanbuild      Clean the source tree and build files then perform a all build."
            echo
            echo "    flashable       Only generate the flashable zip file. Don't use it before you have built once."
            echo "    savedefconfig   Save the defconfig file to source tree."
            echo "    defconfig       Only build kernel defconfig"
            echo "    help ( -h )     Print help information."
            echo "    version         Display the version number."
            echo
            echo "Optional argument"
            echo "    noksu           Build without Kernel SU (with \"all\" and \"defconfig\" operation)"
            echo
            ;;
        savedefconfig)
            save_defconfig;
            ;;
        cleanbuild)
            clean;
            make_defconfig;
            build_kernel;
            link_all_dtb_files;
            pack_dtbo_img;
            generate_flashable;
            ;;
        flashable)
            pack_dtbo_img;
            generate_flashable;
            ;;
        kernelonly)
            make_defconfig
            build_kernel
            ;;
        all)
            make_defconfig
            build_kernel
            link_all_dtb_files
            pack_dtbo_img
            generate_flashable
            ;;
        defconfig)
            make_defconfig;
            ;;
        version)
            echo "Current version is: $LOCAL_VERSION_NUMBER"
            ;;
        *)
            echo "Incorrect usage. Please run: "
            echo "  bash build.sh help (or -h) "
            echo "to display help message."
            ;;
    esac
}

main "$1" "$2";