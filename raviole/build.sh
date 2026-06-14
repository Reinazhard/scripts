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

#==============================================================================
# LLVM/Clang toolchain download
#==============================================================================

fetch_clang_toolchain() {
    msg "Fetching latest LLVM toolchain..."

    local version
    version=$(curl -sL "${LLVM_BASE_URL}/" \
        | grep -oP 'llvm-\K[0-9]+\.[0-9]+\.[0-9]+(?=-x86_64\.tar\.xz)' \
        | sort -t. -k1,1V -k2,2n -k3,3n \
        | tail -n1) || true

    if [[ -z "${version}" ]]; then
        err "Failed to fetch latest LLVM version"
    fi

    msg "Latest LLVM: ${version}"

    local clang_dir="${KERNEL_DIR}/llvm-${version}"
    if [[ -d "${clang_dir}" ]]; then
        msg "LLVM toolchain already cached: ${clang_dir}"
        CLANG_TOOLCHAIN_DIR="${clang_dir}"
        return 0
    fi

    msg "Downloading LLVM ${version}..."
    mkdir -p "${clang_dir}"

    local tarball="llvm-${version}-x86_64.tar.xz"
    local url="${LLVM_BASE_URL}/${tarball}"

    curl -sLo "${clang_dir}/${tarball}" "${url}"
    msg "Extracting LLVM toolchain..."
    tar -xJf "${clang_dir}/${tarball}" -C "${clang_dir}"
    rm -f "${clang_dir}/${tarball}"

    local inner_dir="${clang_dir}/llvm-${version}-x86_64"
    if [[ -d "${inner_dir}" ]]; then
        mv "${inner_dir}"/* "${clang_dir}/"
        rmdir "${inner_dir}"
    fi

    CLANG_TOOLCHAIN_DIR="${clang_dir}"
    msg "LLVM toolchain installed: ${clang_dir}"
}

#==============================================================================
# Environment setup
#==============================================================================

setup_environment() {
    msg "Setting up build environment..."

    # Check dependencies
    check_dependencies

    # Setup toolchain
    case "${TOOLCHAIN}" in
        gcc)
            fetch_gcc_toolchain
            export CROSS_COMPILE="${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin/aarch64-linux-gnu-"
            export CROSS_COMPILE_COMPAT="${GCC_TOOLCHAIN_DIR}/gcc-arm/bin/arm-linux-gnueabihf-"
            ;;
        clang)
            fetch_clang_toolchain
            export PATH="${CLANG_TOOLCHAIN_DIR}/bin:${PATH}"
            ;;
        *)
            err "Unknown toolchain: ${TOOLCHAIN}. Use 'gcc' or 'clang'."
            ;;
    esac

    # Setup AnyKernel3
    if [[ ! -d "${AK3_DIR}" ]]; then
        msg "Cloning AnyKernel3 from ${AK3_REPO}..."
        git clone "https://github.com/${AK3_REPO}.git" \
            --single-branch --depth 1 "${AK3_DIR}" || err "Failed to clone AnyKernel3"
    fi

    # Architecture
    export ARCH="arm64"

    # Compiler info
    if [[ "${TOOLCHAIN}" == "clang" ]]; then
        KBUILD_COMPILER_STRING=$(clang --version | head -n 1 \
            | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    else
        KBUILD_COMPILER_STRING=$("${CROSS_COMPILE}gcc" --version | head -n 1)
    fi
    export KBUILD_COMPILER_STRING

    # Parallel jobs
    PROCS=$(nproc --all)
    export PROCS

    # Kernel version and git info
    KERVER=$(make kernelversion)
    COMMIT_HEAD=$(git log -n 1 --oneline)
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    export KERVER COMMIT_HEAD CI_BRANCH

    # Build number handling
    if [[ "${RELEASE}" == "1" ]]; then
        KERNEL_BUILD_NUM="1"
    elif [[ -f "${KERNEL_BUILD_NUM_FILE}" ]]; then
        KERNEL_BUILD_NUM=$(($(cat "${KERNEL_BUILD_NUM_FILE}") + 1))
    else
        KERNEL_BUILD_NUM="0"
    fi
    echo "${KERNEL_BUILD_NUM}" > "${KERNEL_BUILD_NUM_FILE}"
    export KERNEL_BUILD_NUM

    # Create output directory
    mkdir -p "${OUT_DIR}"

    # Status message
    local build_label="Build #${KERNEL_BUILD_NUM}"
    [[ "${RELEASE}" == "1" ]] && build_label="RELEASE Build"
    msg "${build_label} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Toolchain: ${TOOLCHAIN} | Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
    [[ "${CLEAN}" == "1" ]] && msg "Clean: Enabled" || msg "Clean: Disabled"
}

#==============================================================================
# Telegram notifications
#==============================================================================

tg_post_msg() {
    local message="$1"

    [[ "${NOTIFY}" != "1" ]] && return 0
    [[ -z "${TELEGRAM_TOKEN:-}" ]] && warn "TELEGRAM_TOKEN not set, skipping notification" && return 0

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${CHATID}" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="${message}" > /dev/null 2>&1 || true
}

tg_post_build() {
    local file="$1"
    local caption="$2"

    [[ "${NOTIFY}" != "1" ]] && return 0
    [[ -z "${TELEGRAM_TOKEN:-}" ]] && warn "TELEGRAM_TOKEN not set, skipping upload" && return 0

    msg "Uploading to Telegram..."
    local max_attempts=5
    local wait_time=5

    for attempt in $(seq 1 ${max_attempts}); do
        msg "Upload attempt ${attempt}/${max_attempts}..."
        if curl --progress-bar --max-time 300 \
            -F document=@"${file}" \
            -F chat_id="${CHATID}" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="${caption}" \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" 2>/dev/null; then
            msg "Upload successful!"
            return 0
        fi
        [[ ${attempt} -lt ${max_attempts} ]] && warn "Upload failed, retrying in ${wait_time}s..." && sleep ${wait_time}
        wait_time=$((wait_time * 2))
    done
    err "Failed to upload after ${max_attempts} attempts"
}

tg_notify_failure() {
    local variant="$1"
    local reason="$2"
    local label="Build"
    [[ "${RELEASE}" != "1" ]] && label="Build #${KERNEL_BUILD_NUM}"
    tg_post_msg "<b>❌ ${variant} ${label} failed: ${reason}</b>"
}

#==============================================================================
# Clean and error handling
#==============================================================================

clean_build() {
    [[ "${CLEAN}" == "0" ]] && msg "Skipping clean (CLEAN=0)" && return 0
    msg "Cleaning build environment..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    if [[ -d "${AK3_DIR}" ]]; then
        rm -f "${AK3_DIR}"/*.zip 2>/dev/null || true
        rm -f "${AK3_DIR}/${KERNEL_IMAGE}" 2>/dev/null || true
        rm -f "${AK3_DIR}/dtb" 2>/dev/null || true
        rm -f "${AK3_DIR}/dtbo.img" 2>/dev/null || true
    fi

    msg "Build environment cleaned"
}

on_error() {
    local exit_code=$?
    local line=$1
    [[ ${exit_code} -ne 0 ]] && tg_notify_failure "Build" "failed at line ${line} (exit code: ${exit_code})"
    exit "${exit_code}"
}
