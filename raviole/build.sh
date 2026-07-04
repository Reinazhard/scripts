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

# Normalize CI env (GitHub Actions sets CI=true, we use 0/1)
CI="${CI:-0}"
[[ "${CI}" == "true" ]] && CI=1
[[ "${CI}" != "0" && "${CI}" != "1" ]] && err "CI must be 0 or 1, got: ${CI}"

# CI=1 forces full release mode
[[ "${CI}" == "1" ]] && { SIGN=1 RELEASE=1 CLEAN=1 LOG=1 NOTIFY=1; }

# Release mode: CI=1 or RELEASE=1
IS_RELEASE=0
[[ "${CI}" == "1" || "${RELEASE}" == "1" ]] && IS_RELEASE=1

# Validate config
[[ "${CLEAN}" != "0" && "${CLEAN}" != "1" ]] && err "CLEAN must be 0 or 1, got: ${CLEAN}"
[[ "${SIGN}" != "0" && "${SIGN}" != "1" ]] && err "SIGN must be 0 or 1, got: ${SIGN}"
[[ "${NOTIFY}" != "0" && "${NOTIFY}" != "1" ]] && err "NOTIFY must be 0 or 1, got: ${NOTIFY}"
[[ "${LOG}" != "0" && "${LOG}" != "1" ]] && err "LOG must be 0 or 1, got: ${LOG}"
[[ "${RELEASE}" != "0" && "${RELEASE}" != "1" ]] && err "RELEASE must be 0 or 1, got: ${RELEASE}"
[[ "${KSU}" != "0" && "${KSU}" != "1" ]] && err "KSU must be 0 or 1, got: ${KSU}"

# Single Telegram chat for all builds
CHATID="${CHATID:--1001403511595}"

readonly CHATID IS_RELEASE

# Set output directory
if [[ -z "${OUT_DIR:-}" ]]; then
    OUT_DIR="${KERNEL_DIR}/out"
else
    [[ "${OUT_DIR}" != /* ]] && OUT_DIR="${KERNEL_DIR}/${OUT_DIR}"
fi
readonly OUT_DIR

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
        rm -rf "${inner_dir}"
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

    # Spoof build date for release builds
    [[ "${IS_RELEASE}" == "1" ]] && export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Jan 28 05:34:14 UTC 2026}"

    # Parallel jobs
    PROCS=$(nproc --all)
    export PROCS

    # Kernel version and git info
    KERVER=$(make kernelversion)
    COMMIT_HEAD=$(git log -n 1 --oneline)
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    export KERVER COMMIT_HEAD CI_BRANCH

    # Build number handling: CI=1 or RELEASE=1 always #1, local increments .build_number
    if [[ "${IS_RELEASE}" == "1" ]]; then
        KERNEL_BUILD_NUM="1"
    elif [[ -f "${KERNEL_BUILD_NUM_FILE}" ]]; then
        KERNEL_BUILD_NUM=$(($(cat "${KERNEL_BUILD_NUM_FILE}") + 1))
    else
        KERNEL_BUILD_NUM="0"
    fi
    # Only persist build number for local builds
    [[ "${IS_RELEASE}" == "0" ]] && echo "${KERNEL_BUILD_NUM}" > "${KERNEL_BUILD_NUM_FILE}"
    export KERNEL_BUILD_NUM

    # Create output directory
    mkdir -p "${OUT_DIR}"

    # Status message
    local build_label="Build #${KERNEL_BUILD_NUM}"
    [[ "${IS_RELEASE}" == "1" ]] && build_label="RELEASE Build"
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
    local label="Release"
    [[ "${IS_RELEASE}" == "0" ]] && label="Build #${KERNEL_BUILD_NUM}"
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

#==============================================================================
# Build number management
#==============================================================================

compute_localversion() {
    local variant="$1"
    local lv=""
    [[ "${variant}" == "KernelSU" ]] && lv="-ybrt"
    [[ "${IS_RELEASE}" == "0" ]] && lv="${lv}-b${KERNEL_BUILD_NUM}"
    echo "${lv}"
}

#==============================================================================
# Kernel build functions
#==============================================================================

make_kernel() {
    local make_args=(-j"${PROCS}" O="${OUT_DIR}" ARCH="${ARCH}")

    case "${TOOLCHAIN}" in
        clang)
            make_args+=(LLVM="${CLANG_TOOLCHAIN_DIR}/bin/" LLVM_IAS=1)
            ;;
        gcc)
            make_args+=(CC="${CROSS_COMPILE}gcc")
            ;;
    esac

    make "${make_args[@]}" \
        LOCALVERSION="${LOCALVERSION}" \
        KBUILD_BUILD_VERSION="${KERNEL_BUILD_NUM}" \
        "$@"
}

configure_kernel() {
    local variant="$1"
    msg "Configuring ${variant} kernel..."

    make_kernel "${DEFCONFIG}" > /dev/null 2>&1 || {
        tg_notify_failure "${variant}" "defconfig generation failed"
        err "Failed to generate ${DEFCONFIG}"
    }

    if [[ "${variant}" == "KernelSU" ]]; then
        msg "Enabling KernelSU features..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU || {
            tg_notify_failure "${variant}" "KernelSU config failed"
            err "Failed to enable KernelSU features"
        }
    fi

    make_kernel olddefconfig > /dev/null 2>&1 || {
        tg_notify_failure "${variant}" "olddefconfig failed"
        err "Failed to finalize configuration"
    }

    msg "Configuration complete"
}

compile_kernel() {
    local variant="$1"
    local start end

    msg "Building ${variant} kernel..."
    start=$(date +"%s")

    if make_kernel; then
        end=$(date +"%s")
        BUILD_DURATION=$((end - start))
        msg "${variant} compilation completed in $(format_duration ${BUILD_DURATION})"
    else
        end=$(date +"%s")
        BUILD_DURATION=$((end - start))
        tg_notify_failure "${variant}" "compilation failed after $(format_duration ${BUILD_DURATION})"
        err "${variant} kernel compilation failed"
    fi
}

verify_build_outputs() {
    local variant="$1"
    msg "Verifying build outputs..."

    [[ -f "${IMAGE_PATH}" ]] || {
        tg_notify_failure "${variant}" "${KERNEL_IMAGE} not found"
        err "${KERNEL_IMAGE} not found at ${IMAGE_PATH}"
    }

    for dtb in "${DTB_PATHS[@]}"; do
        [[ -f "${dtb}" ]] || {
            tg_notify_failure "${variant}" "DTB files not found"
            err "DTB files not found: ${dtb}"
        }
    done

    msg "${variant} build outputs verified"
}

#==============================================================================
# DTBO generation
#==============================================================================

generate_dtbo() {
    local variant="$1"
    msg "Generating dtbo.img..."

    if [[ ! -f "${KERNEL_DIR}/mkdtimg" ]]; then
        msg "Downloading mkdtimg..."
        curl -sLo "${KERNEL_DIR}/mkdtimg" "${MKDTIMG_URL}" || {
            tg_notify_failure "${variant}" "mkdtimg download failed"
            err "Failed to download mkdtimg"
        }
    fi
    chmod +x "${KERNEL_DIR}/mkdtimg"

    local dtbo_files
    # shellcheck disable=SC2207
    dtbo_files=( $(find "${OUT_DIR}" -name 'gs*.dtbo' | sort) )

    [[ ${#dtbo_files[@]} -eq 0 ]] && {
        tg_notify_failure "${variant}" "no dtbo files found"
        err "No gs*.dtbo files found in ${OUT_DIR}"
    }

    cd "${KERNEL_DIR}"
    # shellcheck disable=SC2086
    ./mkdtimg create dtbo.img ${MKDTIMG_FLAGS} "${dtbo_files[@]}" || {
        tg_notify_failure "${variant}" "dtbo.img generation failed"
        err "Failed to generate dtbo.img"
    }

    msg "dtbo.img generated (${#dtbo_files[@]} dtbo file(s))"
}

#==============================================================================
# Packaging
#==============================================================================

construct_zip_filename() {
    local suffix="$1"
    local filename="${ZIPNAME}-${DEVICE}"

    if [[ -n "${suffix}" ]]; then
        filename="${filename}-${suffix}"
    fi

    if [[ "${IS_RELEASE}" == "0" ]]; then
        filename="${filename}-b${KERNEL_BUILD_NUM}"
    fi

    echo "${filename}.zip"
}

generate_zip() {
    local variant="$1"
    local zip_suffix="$2"
    local zip_final
    zip_final=$(construct_zip_filename "${zip_suffix}")

    msg "Packaging ${variant} flashable zip: ${zip_final}"

    cp "${IMAGE_PATH}" "${AK3_IMAGE}" || {
        tg_notify_failure "${variant}" "failed to copy kernel image"
        err "Failed to copy ${KERNEL_IMAGE} to AnyKernel3"
    }

    cat "${DTB_PATHS[@]}" > "${AK3_DTB}" || {
        tg_notify_failure "${variant}" "failed to concatenate DTBs"
        err "Failed to create DTB file"
    }

    cp "${KERNEL_DIR}/dtbo.img" "${AK3_DTBO}" || {
        tg_notify_failure "${variant}" "failed to copy dtbo.img"
        err "Failed to copy dtbo.img to AnyKernel3"
    }

    cd "${AK3_DIR}" || err "Failed to enter AnyKernel3 directory"

    rm -f unsigned.zip

    zip -r9 -q "unsigned.zip" . \
        -x '*.git*/*' \
        -x '*.github*/*' \
        -x '*README.md*' \
        -x '*.zip*' \
        -x '*zipsigner-3.0.jar*' || {
        cd "${KERNEL_DIR}"
        tg_notify_failure "${variant}" "zip creation failed"
        err "Failed to create unsigned zip"
    }

    # Validate zip integrity
    msg "Validating zip integrity..."
    if ! zip -T "unsigned.zip" > /dev/null 2>&1; then
        cd "${KERNEL_DIR}"
        tg_notify_failure "${variant}" "zip validation failed"
        err "Zip validation failed"
    fi

    local zip_final_path
    if [[ "${SIGN}" == "1" ]]; then
        if [[ ! -f "zipsigner-3.0.jar" ]]; then
            msg "Downloading zipsigner..."
            curl -sLo zipsigner-3.0.jar \
                "https://raw.githubusercontent.com/raphielscape/scripts/master/zipsigner-3.0.jar" || {
                cd "${KERNEL_DIR}"
                tg_notify_failure "${variant}" "zipsigner download failed"
                err "Failed to download zipsigner"
            }
        fi

        msg "Signing ${zip_final}..."
        java -jar zipsigner-3.0.jar unsigned.zip "${zip_final}" 2>&1 | grep -v "^$" || true

        if [[ ! -f "${zip_final}" ]]; then
            cd "${KERNEL_DIR}"
            tg_notify_failure "${variant}" "zip signing failed"
            err "Failed to sign zip"
        fi
        rm -f unsigned.zip
        zip_final_path="${AK3_DIR}/${zip_final}"
    else
        mv "unsigned.zip" "${zip_final}"
        zip_final_path="${AK3_DIR}/${zip_final}"
    fi

    local build_info="Build #${KERNEL_BUILD_NUM}"
    [[ "${IS_RELEASE}" == "1" ]] && build_info="Release"

    local caption="✅ ${variant} completed in $(format_duration ${BUILD_DURATION}) | <code>${build_info}</code>"
    tg_post_build "${zip_final_path}" "${caption}"

    msg "Flashable zip: ${zip_final_path}"
    cd "${KERNEL_DIR}"
}

#==============================================================================
# Build orchestration
#==============================================================================

build_variant() {
    local variant="$1"
    local is_ksu="$2"

    msg "========================================"
    msg "  ${variant} Variant Build"
    msg "========================================"

    LOCALVERSION=$(compute_localversion "${variant}")
    msg "LOCALVERSION: ${LOCALVERSION}"

    local zip_suffix=""
    [[ "${is_ksu}" == "1" ]] && zip_suffix="ksu-"
    [[ "${IS_RELEASE}" == "1" ]] && zip_suffix="${zip_suffix}RELEASE" || zip_suffix="${zip_suffix}TEST"

    local build_title="${variant} Build #${KERNEL_BUILD_NUM}"
    [[ "${IS_RELEASE}" == "1" ]] && build_title="${variant} Release Build"

    tg_post_msg "<b>${build_title}</b>%0A\
<b>Variant:</b> <code>${variant}</code>%0A\
<b>Kernel:</b> <code>${KERVER}</code>%0A\
<b>Device:</b> <code>${DEVICE}</code>%0A\
<b>Toolchain:</b> <code>${TOOLCHAIN}</code>%0A\
<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A\
<b>Compiler:</b> <code>${KBUILD_COMPILER_STRING}</code>%0A\
<b>Branch:</b> <code>${CI_BRANCH}</code>%0A\
<b>HEAD:</b> <code>${COMMIT_HEAD}</code>"

    clean_build
    configure_kernel "${variant}"
    compile_kernel "${variant}"
    verify_build_outputs "${variant}"
    generate_dtbo "${variant}"
    generate_zip "${variant}" "${zip_suffix}"

    msg "Cleaning up dtbo artifacts..."
    find "${OUT_DIR}" -name 'gs*.dtbo' -delete
    rm -f "${KERNEL_DIR}/dtbo.img"

    msg "${variant} build complete"
}

#==============================================================================
# Main entry point
#==============================================================================

main() {
    trap 'on_error ${LINENO}' ERR

    msg "========================================"
    [[ "${IS_RELEASE}" == "1" ]] && msg "  RELEASE BUILD MODE"
    msg "  Raviole Kernel Build System"
    if [[ "${KSU}" == "1" ]]; then
        msg "  KernelSU Variant"
    else
        msg "  Standard Variant"
    fi
    msg "========================================"

    setup_environment

    if [[ "${KSU}" == "1" ]]; then
        build_variant "KernelSU" "1"
    else
        build_variant "Standard" "0"
    fi

    msg "========================================"
    msg "  Build Completed Successfully"
    [[ "${IS_RELEASE}" == "0" ]] && msg "  Build #${KERNEL_BUILD_NUM}"
    msg "========================================"
}

# Build log handling: LOG=1 saves output to timestamped file
if [[ "${LOG}" == "1" ]]; then
    mkdir -p "${OUT_DIR:-/dev/null}"
    LOG_FILE="${OUT_DIR:-.}/build-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    msg "Build log: ${LOG_FILE}"
fi

main "$@"
