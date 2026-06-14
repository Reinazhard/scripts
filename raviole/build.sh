#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
# Supports Standard and KernelSU build variants

set -euo pipefail

#==============================================================================
# Environment configuration file
#==============================================================================

ENV_FILE="${PWD}/build.env"

if [[ -f "${ENV_FILE}" ]]; then
    echo -e "\e[1;32m[*]\e[0m Loading build.env configuration"
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

#==============================================================================
# Logging and utilities
#==============================================================================

msg()  { echo -e "\e[1;32m[*]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

format_duration() {
    local seconds="$1"
    echo "$((seconds / 60))m $((seconds % 60))s"
}

#==============================================================================
# Configuration and globals
#==============================================================================

readonly KERNEL_DIR="${PWD}"
readonly KERNEL_BUILD_NUM_FILE="${KERNEL_DIR}/.build_number"
readonly TOOLCHAIN_DIR="${KERNEL_DIR}/kernel-toolchain"

# Device configuration (override via env)
ZIPNAME="${ZIPNAME:-86hm}"
DEVICE="${DEVICE:-gs101}"
DEFCONFIG="${DEFCONFIG:-raviole_defconfig}"

# Kernel image filename (override via env)
KERNEL_IMAGE="${KERNEL_IMAGE:-Image.lz4}"

# Device tree files (override via env)
DTB_FILES=($(echo "${DTB_FILES:-gs101-a0.dtb gs101-b0.dtb}"))

# Toolchain selection: gcc or clang (override via env)
TOOLCHAIN="${TOOLCHAIN:-clang}"

# AnyKernel3 configuration (override via env)
AK3_REPO="${AK3_REPO:-Reinazhard/AnyKernel3}"
AK3_DIR="${KERNEL_DIR}/AnyKernel3"

# mkdtimg configuration
MKDTIMG_URL="https://raw.githubusercontent.com/Reinazhard/scripts/refs/heads/main/utility/mkdtimg"
MKDTIMG_FLAGS="--page_size=4096 --id=/:board_id --rev=/:board_rev"

# GCC toolchain source
GCC_REPO="Reinazhard/guacamole_coin_crisis"

# LLVM toolchain source
LLVM_BASE_URL="https://www.kernel.org/pub/tools/llvm/files"

# Build behavior (override via env)
CLEAN="${CLEAN:-0}"
SIGN="${SIGN:-0}"
NOTIFY="${NOTIFY:-0}"
LOG="${LOG:-0}"
RELEASE="${RELEASE:-0}"
KSU="${KSU:-0}"

# Validate config
[[ "${CLEAN}" != "0" && "${CLEAN}" != "1" ]] && err "CLEAN must be 0 or 1, got: ${CLEAN}"
[[ "${SIGN}" != "0" && "${SIGN}" != "1" ]] && err "SIGN must be 0 or 1, got: ${SIGN}"
[[ "${NOTIFY}" != "0" && "${NOTIFY}" != "1" ]] && err "NOTIFY must be 0 or 1, got: ${NOTIFY}"
[[ "${LOG}" != "0" && "${LOG}" != "1" ]] && err "LOG must be 0 or 1, got: ${LOG}"
[[ "${RELEASE}" != "0" && "${RELEASE}" != "1" ]] && err "RELEASE must be 0 or 1, got: ${RELEASE}"
[[ "${KSU}" != "0" && "${KSU}" != "1" ]] && err "KSU must be 0 or 1, got: ${KSU}"

# Set output directory and Telegram chat based on release mode
if [[ -z "${OUT_DIR:-}" ]]; then
    if [[ "${RELEASE}" == "1" ]]; then
        OUT_DIR="${KERNEL_DIR}/out-release"
    else
        OUT_DIR="${KERNEL_DIR}/out"
    fi
else
    [[ "${OUT_DIR}" != /* ]] && OUT_DIR="${KERNEL_DIR}/${OUT_DIR}"
fi

if [[ "${RELEASE}" == "1" ]]; then
    CHATID="-1001493260868"
else
    CHATID="-1001403511595"
fi

readonly OUT_DIR CHATID

# Build artifact paths
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/${KERNEL_IMAGE}"
DTB_PATHS=()
for dtb in "${DTB_FILES[@]}"; do
    DTB_PATHS+=("${OUT_DIR}/google-devices/raviole/dts/gs101/${dtb}")
done

# AnyKernel3 paths
AK3_IMAGE="${AK3_DIR}/${KERNEL_IMAGE}"
AK3_DTB="${AK3_DIR}/dtb"
AK3_DTBO="${AK3_DIR}/dtbo.img"

# Build timing
BUILD_DURATION=0

#==============================================================================
# Dependency checking
#==============================================================================

check_dependencies() {
    local missing=()
    local deps=(git make curl unzip zip)

    if [[ "${TOOLCHAIN}" == "gcc" ]]; then
        deps+=(xz zstd)
    else
        deps+=(xz)
    fi

    if [[ "${SIGN}" == "1" ]]; then
        deps+=(java)
    fi

    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
    fi
}

#==============================================================================
# GCC toolchain download
#==============================================================================

fetch_gcc_toolchain() {
    msg "Fetching latest GCC toolchain release..."

    local tag
    tag=$(curl -sL "https://api.github.com/repos/${GCC_REPO}/releases/latest" \
        | grep -oP '"tag_name":\s*"\K[^"]+') || true

    if [[ -z "${tag}" ]]; then
        err "Failed to fetch latest GCC toolchain tag"
    fi

    msg "Latest GCC toolchain: ${tag}"

    local gcc_dir="${KERNEL_DIR}/gcc-${tag}"
    if [[ -d "${gcc_dir}" ]]; then
        msg "GCC toolchain already cached: ${gcc_dir}"
        GCC_TOOLCHAIN_DIR="${gcc_dir}"
        return 0
    fi

    msg "Downloading GCC toolchains..."
    mkdir -p "${gcc_dir}"

    local assets
    assets=$(curl -sL "https://api.github.com/repos/${GCC_REPO}/releases/latest" \
        | grep -oP '"browser_download_url":\s*"\K[^"]+')

    local arm64_url arm_url
    arm64_url=$(echo "${assets}" | grep 'toolchain-arm64-.*\.tar\.zst$' || true)
    arm_url=$(echo "${assets}" | grep 'toolchain-arm-' | grep -v arm64 | grep '\.tar\.zst$' || true)

    if [[ -z "${arm64_url}" ]]; then
        err "Failed to find arm64 GCC toolchain in release ${tag}"
    fi

    msg "Downloading arm64 GCC toolchain..."
    curl -sLo "${gcc_dir}/arm64.tar.zst" "${arm64_url}"
    msg "Extracting arm64 GCC toolchain..."
    tar -I zstd -xf "${gcc_dir}/arm64.tar.zst" -C "${gcc_dir}"
    rm -f "${gcc_dir}/arm64.tar.zst"

    if [[ -n "${arm_url}" ]]; then
        msg "Downloading arm32 GCC toolchain..."
        curl -sLo "${gcc_dir}/arm.tar.zst" "${arm_url}"
        msg "Extracting arm32 GCC toolchain..."
        tar -I zstd -xf "${gcc_dir}/arm.tar.zst" -C "${gcc_dir}"
        rm -f "${gcc_dir}/arm.tar.zst"
    fi

    GCC_TOOLCHAIN_DIR="${gcc_dir}"
    msg "GCC toolchain installed: ${gcc_dir}"
}
