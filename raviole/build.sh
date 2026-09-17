#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
# Supports Standard and KernelSU build variants

#==============================================================================
# User configuration — edit these directly (replaces build.env)
# External environment still overrides any value below.
#==============================================================================

# Device config
ZIPNAME="${ZIPNAME:-86hm}"
DEVICE="${DEVICE:-gs101}"
DEFCONFIG="${DEFCONFIG:-raviole_defconfig}"
KERNEL_IMAGE="${KERNEL_IMAGE:-Image.lz4}"
DTB_FILES="${DTB_FILES:-gs101-a0.dtb gs101-b0.dtb}"

# Toolchain: gcc or clang
TOOLCHAIN="${TOOLCHAIN:-clang}"

# Clang source: "aosp" (Google prebuilt, default) or "llvm" (kernel.org slim)
CLANG_SOURCE="${CLANG_SOURCE:-aosp}"

# AOSP prebuilt clang (used when CLANG_SOURCE=aosp).
# Latest version is auto-discovered from the branch (largest number wins);
# set CLANG_PREBUILT_NAME to pin, e.g. "clang-r614150".
CLANG_PREBUILT_BASE="${CLANG_PREBUILT_BASE:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
CLANG_PREBUILT_BRANCH="${CLANG_PREBUILT_BRANCH:-refs/heads/main-kernel}"
CLANG_PREBUILT_NAME="${CLANG_PREBUILT_NAME:-}"

# Pin a specific LLVM version (used only when CLANG_SOURCE=llvm).
# Empty = use latest from kernel.org.
LLVM_VERSION="${LLVM_VERSION:-}"

# Custom toolchain paths (optional — overrides auto-discovery/download)
CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR:-}"
GCC_TOOLCHAIN_DIR="${GCC_TOOLCHAIN_DIR:-}"

# AnyKernel3 (leave AK3_DIR empty for auto-detection / ${KERNEL_DIR}/AnyKernel3)
AK3_DIR="${AK3_DIR:-}"
AK3_REPO="${AK3_REPO:-Reinazhard/AnyKernel3}"

# KernelSU (used when KSU=1, leave KSU_DIR empty for ${KERNEL_DIR}/KernelSU)
KSU_DIR="${KSU_DIR:-}"
KSU_REPO="${KSU_REPO:-Reinazhard/KernelSU}"
KSU_BRANCH="${KSU_BRANCH:-fork}"

# Utility overrides (optional — auto-detected locally before download)
MKDTIMG="${MKDTIMG:-}"
ZIPSIGNER_JAR="${ZIPSIGNER_JAR:-}"

# Build behavior (0 or 1)
CLEAN="${CLEAN:-0}"
SIGN="${SIGN:-0}"
NOTIFY="${NOTIFY:-0}"
LOG="${LOG:-0}"
RELEASE="${RELEASE:-0}"
KSU="${KSU:-0}"
CI="${CI:-0}"

# Single Telegram chat for all builds (TELEGRAM_TOKEN comes from env/secrets)
CHATID="${CHATID:--1001403511595}"

# Output directory (empty = ${PWD}/out)
OUT_DIR="${OUT_DIR:-}"

# Spoofed kernel build date (RELEASE/CI builds only)
KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Jan 28 05:34:14 UTC 2026}"

# Spoofed build user and hostname
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-build-user}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-build-host}"

# Clang hardening features (auto-enabled when TOOLCHAIN=clang && RELEASE=1):
#   CONFIG_CFI_CLANG, CONFIG_SHADOW_CALL_STACK, CONFIG_LTO_CLANG_THIN
#   (CONFIG_LTO_CLANG_FULL is disabled to make LTO_THIN stick)
# No manual override needed — controlled by TOOLCHAIN and RELEASE flags.

set -eu
set -o pipefail

#==============================================================================
# Logging and utilities
#==============================================================================

msg()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

format_duration() {
    local seconds="$1"
    echo "$((seconds / 60))m $((seconds % 60))s"
}

#==============================================================================
# Configuration and globals
#==============================================================================

readonly KERNEL_DIR="${PWD}"
readonly KERNEL_BUILD_NUM_FILE="${KERNEL_DIR}/.build_number"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "${KERNEL_DIR}")"

# Working dirs (repos configurable above)
AK3_DIR="${AK3_DIR:-${KERNEL_DIR}/AnyKernel3}"
[ ! -d "${AK3_DIR}" ] && [ -d "${SCRIPT_DIR}/../AnyKernel3" ] && AK3_DIR="${SCRIPT_DIR}/../AnyKernel3"
KSU_DIR="${KSU_DIR:-${KERNEL_DIR}/KernelSU}"

# mkdtimg configuration
MKDTIMG_URL="https://raw.githubusercontent.com/Reinazhard/scripts/refs/heads/main/utility/mkdtimg"
MKDTIMG_FLAGS="--page_size=4096 --id=/:board_id --rev=/:board_rev"

# GCC toolchain source
GCC_REPO="guacamole-sickness%2Fgs-infra%2Fgcc"

# LLVM toolchain source (used when CLANG_SOURCE=llvm)
LLVM_BASE_URL="https://www.kernel.org/pub/tools/llvm/files"

# Normalize CI env (GitHub Actions sets CI=true, we use 0/1)
[ "${CI}" = "true" ] && CI=1
[ "${CI}" != "0" ] && [ "${CI}" != "1" ] && err "CI must be 0 or 1, got: ${CI}"

# CI=1 forces full release mode
[ "${CI}" = "1" ] && { SIGN=1; RELEASE=1; CLEAN=1; LOG=1; NOTIFY=1; }

# Release mode: CI=1 or RELEASE=1
IS_RELEASE=0
if [ "${CI}" = "1" ] || [ "${RELEASE}" = "1" ]; then
    IS_RELEASE=1
fi

# Validate config
[ "${CLEAN}" != "0" ] && [ "${CLEAN}" != "1" ] && err "CLEAN must be 0 or 1, got: ${CLEAN}"
[ "${SIGN}" != "0" ] && [ "${SIGN}" != "1" ] && err "SIGN must be 0 or 1, got: ${SIGN}"
[ "${NOTIFY}" != "0" ] && [ "${NOTIFY}" != "1" ] && err "NOTIFY must be 0 or 1, got: ${NOTIFY}"
[ "${LOG}" != "0" ] && [ "${LOG}" != "1" ] && err "LOG must be 0 or 1, got: ${LOG}"
[ "${RELEASE}" != "0" ] && [ "${RELEASE}" != "1" ] && err "RELEASE must be 0 or 1, got: ${RELEASE}"
[ "${KSU}" != "0" ] && [ "${KSU}" != "1" ] && err "KSU must be 0 or 1, got: ${KSU}"

readonly CHATID IS_RELEASE

# Set output directory
if [ -z "${OUT_DIR:-}" ]; then
    OUT_DIR="${KERNEL_DIR}/out"
else
    case "${OUT_DIR}" in
        /*) ;;
        *) OUT_DIR="${KERNEL_DIR}/${OUT_DIR}" ;;
    esac
fi
readonly OUT_DIR

# Build artifact paths
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/${KERNEL_IMAGE}"
DTB_PATHS=""
for dtb in ${DTB_FILES}; do
    DTB_PATHS="${DTB_PATHS} ${OUT_DIR}/google-devices/raviole/dts/gs101/${dtb}"
done
DTB_PATHS="${DTB_PATHS# }"

# AnyKernel3 paths
AK3_IMAGE="${AK3_DIR}/${KERNEL_IMAGE}"
AK3_DTB="${AK3_DIR}/dtb"
AK3_DTBO="${AK3_DIR}/dtbo.img"

# Build timing
BUILD_DURATION=0

#==============================================================================
# Local resource discovery (offline support)
#==============================================================================

find_mkdtimg() {
    # 1. Custom override
    if [ -n "${MKDTIMG:-}" ] && [ -x "${MKDTIMG}" ]; then
        echo "${MKDTIMG}"
        return 0
    fi
    # 2. Local in KERNEL_DIR
    if [ -x "${KERNEL_DIR}/mkdtimg" ]; then
        echo "${KERNEL_DIR}/mkdtimg"
        return 0
    fi
    # 3. Kernel tree built-in or scripts/dtc
    if [ -x "${KERNEL_DIR}/scripts/dtc/mkdtimg" ]; then
        echo "${KERNEL_DIR}/scripts/dtc/mkdtimg"
        return 0
    fi
    # 4. Relative to build.sh script directory
    if [ -x "${SCRIPT_DIR}/../utility/mkdtimg" ]; then
        echo "${SCRIPT_DIR}/../utility/mkdtimg"
        return 0
    fi
    if [ -x "${SCRIPT_DIR}/utility/mkdtimg" ]; then
        echo "${SCRIPT_DIR}/utility/mkdtimg"
        return 0
    fi
    # 5. In KERNEL_DIR utility directories
    if [ -x "${KERNEL_DIR}/utility/mkdtimg" ]; then
        echo "${KERNEL_DIR}/utility/mkdtimg"
        return 0
    fi
    if [ -x "${KERNEL_DIR}/scripts/utility/mkdtimg" ]; then
        echo "${KERNEL_DIR}/scripts/utility/mkdtimg"
        return 0
    fi
    # 6. In PATH
    if command -v mkdtimg > /dev/null 2>&1; then
        command -v mkdtimg
        return 0
    fi
    return 1
}

find_zipsigner() {
    if [ -n "${ZIPSIGNER_JAR:-}" ] && [ -f "${ZIPSIGNER_JAR}" ]; then
        echo "${ZIPSIGNER_JAR}"
        return 0
    fi
    if [ -f "${KERNEL_DIR}/zipsigner-3.0.jar" ]; then
        echo "${KERNEL_DIR}/zipsigner-3.0.jar"
        return 0
    fi
    if [ -f "${KERNEL_DIR}/zipsigner.jar" ]; then
        echo "${KERNEL_DIR}/zipsigner.jar"
        return 0
    fi
    if [ -f "${SCRIPT_DIR}/../utility/zipsigner-3.0.jar" ]; then
        echo "${SCRIPT_DIR}/../utility/zipsigner-3.0.jar"
        return 0
    fi
    if [ -f "${SCRIPT_DIR}/../utility/zipsigner.jar" ]; then
        echo "${SCRIPT_DIR}/../utility/zipsigner.jar"
        return 0
    fi
    return 1
}

find_cached_aosp_clang() {
    if [ -n "${CLANG_PREBUILT_NAME:-}" ]; then
        local pinned_dir="${KERNEL_DIR}/${CLANG_PREBUILT_NAME}"
        if [ -f "${pinned_dir}/.done" ] || [ -x "${pinned_dir}/bin/clang" ]; then
            echo "${pinned_dir}"
            return 0
        fi
    fi

    local latest
    latest=$(find "${KERNEL_DIR}" -maxdepth 1 -type d -name 'clang-r*' 2>/dev/null \
        | sed -n 's|.*/\(clang-[r0-9]\+\)|\1|p' \
        | sort -t r -k2 -V \
        | tail -n1)
    if [ -n "${latest}" ]; then
        local cdir="${KERNEL_DIR}/${latest}"
        if [ -f "${cdir}/.done" ] || [ -x "${cdir}/bin/clang" ]; then
            echo "${cdir}"
            return 0
        fi
    fi
    return 1
}

find_cached_llvm() {
    if [ -n "${LLVM_VERSION:-}" ]; then
        local pinned_dir="${KERNEL_DIR}/llvm-${LLVM_VERSION}"
        if [ -f "${pinned_dir}/.done" ] || [ -x "${pinned_dir}/bin/clang" ]; then
            echo "${pinned_dir}"
            return 0
        fi
    fi

    local latest
    latest=$(find "${KERNEL_DIR}" -maxdepth 1 -type d -name 'llvm-*' 2>/dev/null \
        | sed -n 's|.*/llvm-\([0-9.]\+\)|\1|p' \
        | sort -t. -k1,1V -k2,2n -k3,3n \
        | tail -n1)
    if [ -n "${latest}" ]; then
        local cdir="${KERNEL_DIR}/llvm-${latest}"
        if [ -f "${cdir}/.done" ] || [ -x "${cdir}/bin/clang" ]; then
            echo "${cdir}"
            return 0
        fi
    fi
    return 1
}

find_cached_gcc() {
    local latest
    latest=$(find "${KERNEL_DIR}" -maxdepth 1 -type d -name 'gcc-*' 2>/dev/null \
        | sed -n 's|.*/gcc-\(.*\)|\1|p' \
        | sort -V \
        | tail -n1)
    if [ -n "${latest}" ]; then
        local gdir="${KERNEL_DIR}/gcc-${latest}"
        if [ -f "${gdir}/.done" ] || [ -x "${gdir}/gcc-arm64/bin/aarch64-linux-gnu-gcc" ] || [ -x "${gdir}/bin/aarch64-linux-gnu-gcc" ]; then
            echo "${gdir}"
            return 0
        fi
    fi
    return 1
}

#==============================================================================
# Dependency checking
#==============================================================================

check_dependencies() {
    local missing=""
    local deps="git make unzip zip"

    [ "${SIGN}" = "1" ] && deps="${deps} java"

    # Only require curl if an artifact or toolchain must be downloaded online
    local need_curl=0
    [ "${NOTIFY}" = "1" ] && need_curl=1

    case "${TOOLCHAIN}" in
        clang)
            if [ -z "${CLANG_TOOLCHAIN_DIR:-}" ]; then
                case "${CLANG_SOURCE}" in
                    aosp)
                        if ! find_cached_aosp_clang > /dev/null 2>&1 && ! command -v clang > /dev/null 2>&1; then
                            need_curl=1
                        fi
                        ;;
                    llvm)
                        if ! find_cached_llvm > /dev/null 2>&1 && ! command -v clang > /dev/null 2>&1; then
                            need_curl=1
                        fi
                        ;;
                esac
            fi
            ;;
        gcc)
            deps="${deps} zstd"
            if [ -z "${GCC_TOOLCHAIN_DIR:-}" ] && [ -z "${CROSS_COMPILE:-}" ]; then
                if ! find_cached_gcc > /dev/null 2>&1 && ! command -v aarch64-linux-gnu-gcc > /dev/null 2>&1; then
                    need_curl=1
                    deps="${deps} xz"
                fi
            fi
            ;;
    esac

    if ! find_mkdtimg > /dev/null 2>&1; then
        need_curl=1
    fi

    if [ "${SIGN}" = "1" ] && ! find_zipsigner > /dev/null 2>&1; then
        need_curl=1
    fi

    [ "${need_curl}" = "1" ] && deps="${deps} curl"

    for cmd in ${deps}; do
        if ! command -v "${cmd}" > /dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done

    if [ -n "${missing}" ]; then
        err "Missing dependencies:${missing}"
    fi
}

#==============================================================================
# GCC toolchain download
#==============================================================================

fetch_gcc_toolchain() {
    if [ -n "${GCC_TOOLCHAIN_DIR:-}" ]; then
        GCC_TOOLCHAIN_DIR="${GCC_TOOLCHAIN_DIR%/}"
        if [ -x "${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin/aarch64-linux-gnu-gcc" ] || [ -x "${GCC_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-gcc" ]; then
            msg "Using specified GCC toolchain: ${GCC_TOOLCHAIN_DIR}"
            return 0
        fi
    fi

    if [ -n "${CROSS_COMPILE:-}" ] && command -v "${CROSS_COMPILE}gcc" > /dev/null 2>&1; then
        msg "Using pre-configured CROSS_COMPILE: ${CROSS_COMPILE}"
        return 0
    fi

    local cached_dir
    if cached_dir=$(find_cached_gcc); then
        msg "GCC toolchain already cached: ${cached_dir}"
        GCC_TOOLCHAIN_DIR="${cached_dir}"
        return 0
    fi

    msg "Fetching latest GCC toolchain release..."

    local tag=""
    tag=$(curl -fsSL --connect-timeout 5 "https://gitlab.com/api/v4/projects/${GCC_REPO}/releases" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)

    if [ -z "${tag}" ]; then
        if command -v aarch64-linux-gnu-gcc > /dev/null 2>&1; then
            warn "Could not reach GCC releases server (offline?). Falling back to system aarch64-linux-gnu-gcc"
            CROSS_COMPILE="aarch64-linux-gnu-"
            [ -z "${CROSS_COMPILE_COMPAT:-}" ] && command -v arm-linux-gnueabihf-gcc > /dev/null 2>&1 && CROSS_COMPILE_COMPAT="arm-linux-gnueabihf-"
            return 0
        fi
        err "Failed to fetch latest GCC toolchain tag (offline?) and no local GCC found. Set GCC_TOOLCHAIN_DIR or CROSS_COMPILE."
    fi

    msg "Latest GCC toolchain: ${tag}"

    local gcc_dir="${KERNEL_DIR}/gcc-${tag}"
    if [ -f "${gcc_dir}/.done" ] || [ -x "${gcc_dir}/gcc-arm64/bin/aarch64-linux-gnu-gcc" ]; then
        msg "GCC toolchain already cached: ${gcc_dir}"
        GCC_TOOLCHAIN_DIR="${gcc_dir}"
        return 0
    fi

    msg "Downloading GCC toolchains..."
    mkdir -p "${gcc_dir}"

    local assets
    assets=$(curl -fsSL --connect-timeout 10 "https://gitlab.com/api/v4/projects/${GCC_REPO}/releases/${tag}" 2>/dev/null \
        | sed -n 's/.*"direct_asset_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)

    local arm64_url arm_url
    arm64_url=$(echo "${assets}" | grep 'toolchain-arm64-.*\.tar\.zst$' || true)
    arm_url=$(echo "${assets}" | grep 'toolchain-arm-' | grep -v arm64 | grep '\.tar\.zst$' || true)

    if [ -z "${arm64_url}" ]; then
        if command -v aarch64-linux-gnu-gcc > /dev/null 2>&1; then
            warn "Failed to find arm64 GCC in release. Falling back to system aarch64-linux-gnu-gcc"
            CROSS_COMPILE="aarch64-linux-gnu-"
            return 0
        fi
        err "Failed to find arm64 GCC toolchain in release ${tag}"
    fi

    msg "Downloading arm64 GCC toolchain..."
    if ! curl -fsSL --connect-timeout 10 -o "${gcc_dir}/arm64.tar.zst" "${arm64_url}"; then
        if command -v aarch64-linux-gnu-gcc > /dev/null 2>&1; then
            warn "Failed to download arm64 GCC (offline?). Falling back to system aarch64-linux-gnu-gcc"
            CROSS_COMPILE="aarch64-linux-gnu-"
            return 0
        fi
        err "Failed to download arm64 GCC toolchain"
    fi
    msg "Extracting arm64 GCC toolchain..."
    if ! tar -I zstd -xf "${gcc_dir}/arm64.tar.zst" -C "${gcc_dir}"; then
        err "Failed to extract arm64 GCC toolchain"
    fi
    rm -f "${gcc_dir}/arm64.tar.zst"

    if [ -n "${arm_url}" ]; then
        msg "Downloading arm32 GCC toolchain..."
        if curl -fsSL --connect-timeout 10 -o "${gcc_dir}/arm.tar.zst" "${arm_url}"; then
            msg "Extracting arm32 GCC toolchain..."
            tar -I zstd -xf "${gcc_dir}/arm.tar.zst" -C "${gcc_dir}" 2>/dev/null || true
            rm -f "${gcc_dir}/arm.tar.zst"
        else
            warn "Failed to download arm32 GCC toolchain (optional), skipping"
        fi
    fi

    touch "${gcc_dir}/.done"
    GCC_TOOLCHAIN_DIR="${gcc_dir}"
    msg "GCC toolchain installed: ${gcc_dir}"
}

#==============================================================================
# AOSP prebuilt Clang download
#==============================================================================

fetch_aosp_clang() {
    if [ -n "${CLANG_TOOLCHAIN_DIR:-}" ]; then
        CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR%/}"
        if [ -x "${CLANG_TOOLCHAIN_DIR}/bin/clang" ]; then
            msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
            return 0
        elif [ -x "${CLANG_TOOLCHAIN_DIR}/clang" ]; then
            CLANG_TOOLCHAIN_DIR="$(dirname "${CLANG_TOOLCHAIN_DIR}")"
            msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
            return 0
        fi
    fi

    local cached_dir
    if cached_dir=$(find_cached_aosp_clang); then
        msg "AOSP Clang already cached: ${cached_dir}"
        CLANG_TOOLCHAIN_DIR="${cached_dir}"
        return 0
    fi

    # Resolve which prebuilt to use: pinned name or latest from the branch.
    local clang_name="${CLANG_PREBUILT_NAME:-}"

    if [ -z "${clang_name}" ]; then
        msg "Discovering latest AOSP Clang prebuilt..."
        clang_name=$(curl -fsSL --connect-timeout 5 "${CLANG_PREBUILT_BASE}/+/${CLANG_PREBUILT_BRANCH}" 2>/dev/null \
            | grep -oE 'clang-[r0-9]+[0-9]' \
            | sed 's/^clang-//' \
            | sort -t r -k2 -V \
            | tail -n1 || true)
        if [ -n "${clang_name}" ]; then
            clang_name="clang-${clang_name}"
            msg "Latest AOSP Clang: ${clang_name}"
        fi
    fi

    if [ -z "${clang_name}" ]; then
        if command -v clang > /dev/null 2>&1; then
            local sys_clang sys_dir
            sys_clang=$(command -v clang)
            sys_dir=$(dirname "$(dirname "${sys_clang}")")
            if [ -x "${sys_dir}/bin/clang" ]; then
                warn "Could not reach AOSP prebuilt server (offline?). Falling back to system Clang: ${sys_dir}"
                CLANG_TOOLCHAIN_DIR="${sys_dir}"
                return 0
            fi
        fi
        err "Failed to discover AOSP Clang prebuilt (offline?) and no local Clang found. Set CLANG_TOOLCHAIN_DIR."
    fi

    msg "Fetching AOSP prebuilt Clang (${clang_name})..."

    local clang_dir="${KERNEL_DIR}/${clang_name}"
    if [ -f "${clang_dir}/.done" ] || [ -x "${clang_dir}/bin/clang" ]; then
        msg "AOSP Clang already cached: ${clang_dir}"
        CLANG_TOOLCHAIN_DIR="${clang_dir}"
        return 0
    fi

    local url="${CLANG_PREBUILT_BASE}/+archive/${CLANG_PREBUILT_BRANCH}/${clang_name}.tar.gz"
    msg "Downloading AOSP Clang..."
    local tarball="/tmp/${clang_name}.tar.gz"
    if ! curl -fsSL --connect-timeout 10 -o "${tarball}" "${url}"; then
        if command -v clang > /dev/null 2>&1; then
            local sys_clang sys_dir
            sys_clang=$(command -v clang)
            sys_dir=$(dirname "$(dirname "${sys_clang}")")
            warn "Failed to download AOSP Clang (offline?). Falling back to system Clang: ${sys_dir}"
            CLANG_TOOLCHAIN_DIR="${sys_dir}"
            return 0
        fi
        err "Failed to download AOSP Clang from ${url} (offline?). Set CLANG_TOOLCHAIN_DIR to use local toolchain."
    fi

    msg "Extracting AOSP Clang..."
    rm -rf "${clang_dir}"
    mkdir -p "${clang_dir}"
    if ! tar -xzf "${tarball}" -C "${clang_dir}"; then
        err "Failed to extract AOSP Clang"
    fi
    rm -f "${tarball}"

    touch "${clang_dir}/.done"
    CLANG_TOOLCHAIN_DIR="${clang_dir}"
    msg "AOSP Clang installed: ${clang_dir}"
}

#==============================================================================
# LLVM/Clang toolchain download (kernel.org slim, used when CLANG_SOURCE=llvm)
#==============================================================================

fetch_clang_toolchain() {
    if [ -n "${CLANG_TOOLCHAIN_DIR:-}" ]; then
        CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR%/}"
        if [ -x "${CLANG_TOOLCHAIN_DIR}/bin/clang" ]; then
            msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
            return 0
        elif [ -x "${CLANG_TOOLCHAIN_DIR}/clang" ]; then
            CLANG_TOOLCHAIN_DIR="$(dirname "${CLANG_TOOLCHAIN_DIR}")"
            msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
            return 0
        fi
    fi

    local cached_dir
    if cached_dir=$(find_cached_llvm); then
        msg "LLVM toolchain already cached: ${cached_dir}"
        CLANG_TOOLCHAIN_DIR="${cached_dir}"
        return 0
    fi

    msg "Fetching latest LLVM toolchain..."

    local version="${LLVM_VERSION:-}"

    if [ -z "${version}" ]; then
        version=$(curl -fsSL --connect-timeout 5 "${LLVM_BASE_URL}/" 2>/dev/null \
            | sed -n 's/.*llvm-\([0-9]*\.[0-9]*\.[0-9]*\)-x86_64\.tar\.xz.*/\1/p' \
            | sort -t. -k1,1V -k2,2n -k3,3n \
            | tail -n1 || true)
        if [ -n "${version}" ]; then
            msg "Latest LLVM: ${version}"
        fi
    fi

    if [ -z "${version}" ]; then
        if command -v clang > /dev/null 2>&1; then
            local sys_clang sys_dir
            sys_clang=$(command -v clang)
            sys_dir=$(dirname "$(dirname "${sys_clang}")")
            if [ -x "${sys_dir}/bin/clang" ]; then
                warn "Could not reach LLVM server (offline?). Falling back to system Clang: ${sys_dir}"
                CLANG_TOOLCHAIN_DIR="${sys_dir}"
                return 0
            fi
        fi
        err "Failed to determine LLVM version (offline?) and no local Clang found. Set LLVM_VERSION or CLANG_TOOLCHAIN_DIR."
    fi

    local clang_dir="${KERNEL_DIR}/llvm-${version}"
    if [ -f "${clang_dir}/.done" ] || [ -x "${clang_dir}/bin/clang" ]; then
        msg "LLVM toolchain already cached: ${clang_dir}"
        CLANG_TOOLCHAIN_DIR="${clang_dir}"
        return 0
    fi

    msg "Downloading LLVM ${version}..."

    local tarball="llvm-${version}-x86_64.tar.xz"
    local url="${LLVM_BASE_URL}/${tarball}"
    local tmpdir="/tmp/llvm-extract.$$"

    if ! curl -fsSL --connect-timeout 10 -o "/tmp/${tarball}" "${url}"; then
        if command -v clang > /dev/null 2>&1; then
            local sys_clang sys_dir
            sys_clang=$(command -v clang)
            sys_dir=$(dirname "$(dirname "${sys_clang}")")
            warn "Failed to download LLVM (offline?). Falling back to system Clang: ${sys_dir}"
            CLANG_TOOLCHAIN_DIR="${sys_dir}"
            return 0
        fi
        err "Failed to download LLVM ${version} (offline?). Set CLANG_TOOLCHAIN_DIR to use local toolchain."
    fi
    msg "Extracting LLVM toolchain..."
    mkdir -p "${tmpdir}"
    if ! tar -xJf "/tmp/${tarball}" -C "${tmpdir}"; then
        err "Failed to extract LLVM ${version}"
    fi
    rm -f "/tmp/${tarball}"

    local inner_dir="${tmpdir}/llvm-${version}-x86_64"
    rm -rf "${clang_dir}"
    if [ -d "${inner_dir}" ]; then
        mv "${inner_dir}" "${clang_dir}"
    else
        mv "${tmpdir}" "${clang_dir}"
    fi
    rm -rf "${tmpdir}"

    touch "${clang_dir}/.done"
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
            if [ -n "${GCC_TOOLCHAIN_DIR:-}" ]; then
                if [ -d "${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin" ]; then
                    export CROSS_COMPILE="${CROSS_COMPILE:-${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin/aarch64-linux-gnu-}"
                    export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-${GCC_TOOLCHAIN_DIR}/gcc-arm/bin/arm-linux-gnueabihf-}"
                else
                    export CROSS_COMPILE="${CROSS_COMPILE:-${GCC_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-}"
                    export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-${GCC_TOOLCHAIN_DIR}/bin/arm-linux-gnueabihf-}"
                fi
            else
                export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
                export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-arm-linux-gnueabihf-}"
            fi
            ;;
        clang)
            case "${CLANG_SOURCE}" in
                aosp)
                    fetch_aosp_clang
                    ;;
                llvm)
                    fetch_clang_toolchain
                    ;;
                *)
                    err "Unknown CLANG_SOURCE: ${CLANG_SOURCE}. Use 'aosp' or 'llvm'."
                    ;;
            esac
            ;;
        *)
            err "Unknown toolchain: ${TOOLCHAIN}. Use 'gcc' or 'clang'."
            ;;
    esac

    # Normalize CLANG_TOOLCHAIN_DIR if set
    if [ -n "${CLANG_TOOLCHAIN_DIR:-}" ]; then
        CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR%/}"
        if [ -x "${CLANG_TOOLCHAIN_DIR}/clang" ] && [ ! -d "${CLANG_TOOLCHAIN_DIR}/bin" ]; then
            CLANG_TOOLCHAIN_DIR="$(dirname "${CLANG_TOOLCHAIN_DIR}")"
        fi
    fi

    # Setup AnyKernel3
    if [ ! -d "${AK3_DIR}" ]; then
        if [ -d "${SCRIPT_DIR}/../AnyKernel3" ]; then
            AK3_DIR="${SCRIPT_DIR}/../AnyKernel3"
            AK3_IMAGE="${AK3_DIR}/${KERNEL_IMAGE}"
            AK3_DTB="${AK3_DIR}/dtb"
            AK3_DTBO="${AK3_DIR}/dtbo.img"
            msg "Using AnyKernel3 from: ${AK3_DIR}"
        else
            msg "Cloning AnyKernel3 from ${AK3_REPO}..."
            if ! git clone "https://github.com/${AK3_REPO}.git" \
                --single-branch --depth 1 "${AK3_DIR}" 2>/dev/null; then
                warn "Failed to clone AnyKernel3 (offline?). Flashable zip packaging will be skipped."
            fi
        fi
    fi

    # Setup KernelSU (only when KSU=1)
    if [ "${KSU}" = "1" ]; then
        if [ ! -d "${KSU_DIR}" ]; then
            msg "Cloning KernelSU from ${KSU_REPO}..."
            if ! git clone "https://github.com/${KSU_REPO}.git" \
                -b "${KSU_BRANCH}" --single-branch --depth 1 "${KSU_DIR}"; then
                err "KernelSU not found at ${KSU_DIR} and could not be cloned (offline?). Please provide KernelSU at ${KSU_DIR} or set KSU_DIR."
            fi
        fi
    fi

    # Architecture
    export ARCH="arm64"

    # Compiler info
    if [ "${TOOLCHAIN}" = "clang" ]; then
        KBUILD_COMPILER_STRING=$("${CLANG_TOOLCHAIN_DIR}/bin/clang" --version | head -n 1 \
            | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    else
        KBUILD_COMPILER_STRING=$("${CROSS_COMPILE}gcc" --version | head -n 1)
    fi
    export KBUILD_COMPILER_STRING

    # Spoof build date for release builds
    [ "${IS_RELEASE}" = "1" ] && export KBUILD_BUILD_TIMESTAMP

    export KBUILD_BUILD_USER KBUILD_BUILD_HOST

    # Parallel jobs
    PROCS=$(nproc --all)
    export PROCS

    # Kernel version and git info
    KERVER=$(make kernelversion 2>/dev/null || echo "unknown")
    COMMIT_HEAD=$(git log -n 1 --oneline 2>/dev/null || echo "unknown")
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    export KERVER COMMIT_HEAD CI_BRANCH

    # Build number handling: CI=1 or RELEASE=1 always #1, local increments .build_number
    if [ "${IS_RELEASE}" = "1" ]; then
        KERNEL_BUILD_NUM="1"
    elif [ -f "${KERNEL_BUILD_NUM_FILE}" ]; then
        KERNEL_BUILD_NUM=$(($(cat "${KERNEL_BUILD_NUM_FILE}") + 1))
    else
        KERNEL_BUILD_NUM="0"
    fi
    # Only persist build number for local builds
    [ "${IS_RELEASE}" = "0" ] && echo "${KERNEL_BUILD_NUM}" > "${KERNEL_BUILD_NUM_FILE}"
    export KERNEL_BUILD_NUM

    # Create output directory
    mkdir -p "${OUT_DIR}"

    # Status message
    local build_label="Build #${KERNEL_BUILD_NUM}"
    [ "${IS_RELEASE}" = "1" ] && build_label="RELEASE Build"
    msg "${build_label} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Toolchain: ${TOOLCHAIN} | Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
    if [ "${CLEAN}" = "1" ]; then
        msg "Clean: Enabled"
    else
        msg "Clean: Disabled"
    fi
}

#==============================================================================
# Telegram notifications
#==============================================================================

tg_post_msg() {
    local message="$1"

    [ "${NOTIFY}" != "1" ] && return 0
    [ -z "${TELEGRAM_TOKEN:-}" ] && warn "TELEGRAM_TOKEN not set, skipping notification" && return 0

    local max_attempts=3
    local wait_time=2
    local attempt=1

    while [ "${attempt}" -le "${max_attempts}" ]; do
        if curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d chat_id="${CHATID}" \
            -d "disable_web_page_preview=true" \
            -d "parse_mode=html" \
            -d text="${message}" > /dev/null 2>&1; then
            return 0
        fi
        [ "${attempt}" -lt "${max_attempts}" ] && sleep "${wait_time}"
        wait_time=$((wait_time * 2))
        attempt=$((attempt + 1))
    done
    warn "Failed to send Telegram message after ${max_attempts} attempts"
}

tg_post_build() {
    local file="$1"
    local caption="$2"

    [ "${NOTIFY}" != "1" ] && return 0
    [ -z "${TELEGRAM_TOKEN:-}" ] && warn "TELEGRAM_TOKEN not set, skipping upload" && return 0

    msg "Uploading to Telegram..."
    local max_attempts=5
    local wait_time=5
    local attempt=1

    while [ "${attempt}" -le "${max_attempts}" ]; do
        msg "Upload attempt ${attempt}/${max_attempts}..."
        if curl -f --progress-bar --max-time 300 \
            -F document=@"${file}" \
            -F chat_id="${CHATID}" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="${caption}" \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" 2>/dev/null; then
            msg "Upload successful!"
            return 0
        fi
        [ "${attempt}" -lt "${max_attempts}" ] && warn "Upload failed, retrying in ${wait_time}s..." && sleep "${wait_time}"
        wait_time=$((wait_time * 2))
        attempt=$((attempt + 1))
    done
    warn "Failed to upload after ${max_attempts} attempts (build artifact is at: ${file})"
    return 1
}

tg_notify_failure() {
    local variant="$1"
    local reason="$2"
    local label="Release"
    [ "${IS_RELEASE}" = "0" ] && label="Build #${KERNEL_BUILD_NUM}"
    tg_post_msg "<b>❌ ${variant} ${label} failed: ${reason}</b>"
}

#==============================================================================
# Clean and error handling
#==============================================================================

clean_build() {
    [ "${CLEAN}" = "0" ] && msg "Skipping clean (CLEAN=0)" && return 0
    msg "Cleaning build environment..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    if [ -d "${AK3_DIR}" ]; then
        rm -f "${AK3_DIR}"/*.zip 2>/dev/null || true
        rm -f "${AK3_DIR}/${KERNEL_IMAGE}" 2>/dev/null || true
        rm -f "${AK3_DIR}/dtb" 2>/dev/null || true
        rm -f "${AK3_DIR}/dtbo.img" 2>/dev/null || true
    fi

    msg "Build environment cleaned"
}

on_exit() {
    local exit_code=$?
    cd "${KERNEL_DIR}"
    [ ${exit_code} -ne 0 ] && tg_notify_failure "Build" "failed (exit code: ${exit_code})"
    exit "${exit_code}"
}

#==============================================================================
# Build number management
#==============================================================================

compute_localversion() {
    local variant="$1"
    local lv=""
    # "-ybrt" suffix on KernelSU builds. Custom localversion to avoid matching
    # Google's database of known custom kernels localversions. If it matches,
    # Play Integrity breaks. Will be changed if necessary.
    [ "${variant}" = "KernelSU" ] && lv="-ybrt"
    [ "${IS_RELEASE}" = "0" ] && lv="${lv}-b${KERNEL_BUILD_NUM}"
    echo "${lv}"
}

#==============================================================================
# Kernel build functions
#==============================================================================

make_kernel() {
    local make_args="-j${PROCS}"
    make_args="${make_args} O=${OUT_DIR}"
    make_args="${make_args} ARCH=${ARCH}"

    case "${TOOLCHAIN}" in
        clang)
            # Point the kernel build at the prebuilt's bin/ directly. Equivalent
            # to LLVM=1 but avoids needing to export PATH; LLVM_IAS=1 uses clang's
            # integrated assembler for both arm64 and arm32 — no GCC compat needed.
            make_args="${make_args} LLVM=${CLANG_TOOLCHAIN_DIR}/bin/"
            make_args="${make_args} LLVM_IAS=1"
            ;;
        gcc)
            make_args="${make_args} CC=${CROSS_COMPILE}gcc"
            ;;
    esac

    make ${make_args} \
        "LOCALVERSION=${LOCALVERSION}" \
        "KBUILD_BUILD_VERSION=${KERNEL_BUILD_NUM}" \
        "$@"
}

configure_kernel() {
    local variant="$1"
    msg "Configuring ${variant} kernel..."

    if ! make_kernel "${DEFCONFIG}" > /dev/null; then
        err "Failed to generate ${DEFCONFIG}"
    fi

    if [ "${variant}" = "KernelSU" ]; then
        msg "Enabling KernelSU features..."
        if ! scripts/config --file "${OUT_DIR}/.config" -e KSU; then
            err "Failed to enable KernelSU features"
        fi
    fi

    # Enable clang hardening features for release clang builds
    if [ "${TOOLCHAIN}" = "clang" ] && [ "${IS_RELEASE}" = "1" ]; then
        msg "Enabling clang hardening features (CFI, SCS, LTO_THIN)..."
        if ! scripts/config --file "${OUT_DIR}/.config" \
            -e CONFIG_CFI_CLANG \
            -e CONFIG_SHADOW_CALL_STACK \
            -e CONFIG_LTO_CLANG_THIN \
            -d CONFIG_LTO_CLANG_FULL; then
            err "Failed to enable clang hardening features"
        fi
    fi

    if ! make_kernel olddefconfig > /dev/null; then
        err "Failed to finalize configuration"
    fi

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
        err "${variant} kernel compilation failed"
    fi
}

verify_build_outputs() {
    local variant="$1"
    msg "Verifying build outputs..."

    [ -f "${IMAGE_PATH}" ] || {
        err "${KERNEL_IMAGE} not found at ${IMAGE_PATH}"
    }

    for dtb in ${DTB_PATHS}; do
        [ -f "${dtb}" ] || {
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

    local mkdtimg_bin
    if ! mkdtimg_bin=$(find_mkdtimg); then
        msg "Downloading mkdtimg..."
        if curl -fsSL --connect-timeout 10 -o "${KERNEL_DIR}/mkdtimg" "${MKDTIMG_URL}"; then
            chmod +x "${KERNEL_DIR}/mkdtimg"
            mkdtimg_bin="${KERNEL_DIR}/mkdtimg"
        else
            err "mkdtimg not found and could not be downloaded (offline?). Please provide mkdtimg in ${KERNEL_DIR} or set MKDTIMG."
        fi
    fi

    local dtbo_files
    dtbo_files=$(find "${OUT_DIR}" -name 'gs*.dtbo' | sort)

    if [ -z "${dtbo_files}" ]; then
        err "No gs*.dtbo files found in ${OUT_DIR}"
    fi

    cd "${KERNEL_DIR}"
    # shellcheck disable=SC2086
    if ! "${mkdtimg_bin}" create "${OUT_DIR}/dtbo.img" ${MKDTIMG_FLAGS} ${dtbo_files}; then
        err "Failed to generate dtbo.img"
    fi

    msg "dtbo.img generated ($(echo ${dtbo_files} | wc -w) dtbo file(s))"
}

#==============================================================================
# Packaging
#==============================================================================

construct_zip_filename() {
    local suffix="$1"
    local filename="${ZIPNAME}-${DEVICE}"

    if [ -n "${suffix}" ]; then
        filename="${filename}-${suffix}"
    fi

    if [ "${IS_RELEASE}" = "0" ]; then
        filename="${filename}-b${KERNEL_BUILD_NUM}"
    fi

    echo "${filename}.zip"
}

generate_zip() {
    local variant="$1"
    local zip_suffix="$2"

    if [ ! -d "${AK3_DIR}" ]; then
        warn "AnyKernel3 not found at ${AK3_DIR}. Skipping flashable zip packaging."
        msg "Kernel build output is available at: ${IMAGE_PATH}"
        return 0
    fi

    local zip_final
    zip_final=$(construct_zip_filename "${zip_suffix}")

    msg "Packaging ${variant} flashable zip: ${zip_final}"

    if ! cp "${IMAGE_PATH}" "${AK3_IMAGE}"; then
        err "Failed to copy ${KERNEL_IMAGE} to AnyKernel3"
    fi

    if ! cat ${DTB_PATHS} > "${AK3_DTB}"; then
        err "Failed to create DTB file"
    fi

    if ! cp "${OUT_DIR}/dtbo.img" "${AK3_DTBO}"; then
        err "Failed to copy dtbo.img to AnyKernel3"
    fi

    if ! cd "${AK3_DIR}"; then
        err "Failed to enter AnyKernel3 directory"
    fi

    rm -f unsigned.zip

    if ! zip -r9 -q "unsigned.zip" . \
        -x '*.git*/*' \
        -x '*.github*/*' \
        -x '*README.md*' \
        -x '*.zip*' \
        -x 'zipsigner*'; then
        cd "${KERNEL_DIR}"
        err "Failed to create unsigned zip"
    fi

    # Validate zip integrity
    msg "Validating zip integrity..."
    if ! zip -T "unsigned.zip" > /dev/null 2>&1; then
        cd "${KERNEL_DIR}"
        err "Zip validation failed"
    fi

    local zip_final_path
    if [ "${SIGN}" = "1" ]; then
        local zipsigner_jar
        if ! zipsigner_jar=$(find_zipsigner); then
            msg "Downloading zipsigner..."
            if curl -fsSL --connect-timeout 10 -o "${KERNEL_DIR}/zipsigner-3.0.jar" \
                "https://raw.githubusercontent.com/raphielscape/scripts/master/zipsigner-3.0.jar"; then
                zipsigner_jar="${KERNEL_DIR}/zipsigner-3.0.jar"
            else
                warn "Failed to download zipsigner (offline?). Leaving zip unsigned."
            fi
        fi

        if [ -n "${zipsigner_jar:-}" ] && [ -f "${zipsigner_jar}" ]; then
            msg "Signing ${zip_final}..."
            if ! java -jar "${zipsigner_jar}" unsigned.zip "${zip_final}"; then
                cd "${KERNEL_DIR}"
                err "Failed to sign zip"
            fi

            if [ ! -f "${zip_final}" ]; then
                cd "${KERNEL_DIR}"
                err "Failed to sign zip"
            fi
            rm -f unsigned.zip
        else
            mv "unsigned.zip" "${zip_final}"
        fi
        zip_final_path="${AK3_DIR}/${zip_final}"
    else
        mv "unsigned.zip" "${zip_final}"
        zip_final_path="${AK3_DIR}/${zip_final}"
    fi

    local build_info="Build #${KERNEL_BUILD_NUM}"
    [ "${IS_RELEASE}" = "1" ] && build_info="Release"

    local caption
    caption="✅ ${variant} completed in $(format_duration ${BUILD_DURATION}) | <code>${build_info}</code>"
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
    [ "${is_ksu}" = "1" ] && zip_suffix="ksu-"
    if [ "${IS_RELEASE}" = "1" ]; then
        zip_suffix="${zip_suffix}release"
    else
        zip_suffix="${zip_suffix}test"
    fi

    local build_title="${variant} Build #${KERNEL_BUILD_NUM}"
    [ "${IS_RELEASE}" = "1" ] && build_title="${variant} Release Build"

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
    rm -f "${OUT_DIR}/dtbo.img"

    msg "${variant} build complete"
}

#==============================================================================
# Main entry point
#==============================================================================

main() {
    trap on_exit EXIT

    msg "========================================"
    [ "${IS_RELEASE}" = "1" ] && msg "  RELEASE BUILD MODE"
    msg "  Raviole Kernel Build System"
    if [ "${KSU}" = "1" ]; then
        msg "  KernelSU Variant"
    else
        msg "  Standard Variant"
    fi
    msg "========================================"

    setup_environment

    if [ "${KSU}" = "1" ]; then
        build_variant "KernelSU" "1"
    else
        build_variant "Standard" "0"
    fi

    msg "========================================"
    msg "  Build Completed Successfully"
    [ "${IS_RELEASE}" = "0" ] && msg "  Build #${KERNEL_BUILD_NUM}"
    msg "========================================"
}

# Build log handling: LOG=1 saves output to timestamped file
if [ "${LOG}" = "1" ]; then
    mkdir -p "${OUT_DIR}"
    LOG_FILE="${OUT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
    main "$@" 2>&1 | tee -a "${LOG_FILE}"
else
    main "$@"
fi
