#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
# Supports Standard and KernelSU build variants

#==============================================================================
# User configuration (environment overrides values below)
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

# AOSP prebuilt clang (used when CLANG_SOURCE=aosp). Pinned name optional (e.g. clang-r614150)
CLANG_PREBUILT_BASE="${CLANG_PREBUILT_BASE:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
CLANG_PREBUILT_BRANCH="${CLANG_PREBUILT_BRANCH:-refs/heads/main-kernel}"
CLANG_PREBUILT_NAME="${CLANG_PREBUILT_NAME:-}"

# Pin LLVM version (used only when CLANG_SOURCE=llvm, empty = latest from kernel.org)
LLVM_VERSION="${LLVM_VERSION:-}"

# Custom toolchain paths (overrides auto-discovery/download)
CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR:-}"
GCC_TOOLCHAIN_DIR="${GCC_TOOLCHAIN_DIR:-}"

# Persistent toolchain cache directory (shared across kernel checkouts)
TOOLCHAIN_CACHE_DIR="${TOOLCHAIN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/android-kernel-tools}"

# AnyKernel3 (empty = auto-detection / ${KERNEL_DIR}/AnyKernel3)
AK3_DIR="${AK3_DIR:-}"
AK3_REPO="${AK3_REPO:-Reinazhard/AnyKernel3}"

# KernelSU (required for Kconfig evaluation even when KSU=0)
KSU_DIR="${KSU_DIR:-}"
KSU_REPO="${KSU_REPO:-Reinazhard/KernelSU}"
KSU_BRANCH="${KSU_BRANCH:-fork}"

# Utility overrides (auto-detected locally before download)
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

# Spoofed kernel build date, user, hostname (RELEASE/CI builds only)
KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Tue Aug 25 11:29:36 UTC 2026}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-build-user}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-build-host}"

# Clang hardening features (auto-enabled when TOOLCHAIN=clang && RELEASE=1):
#   CONFIG_CFI_CLANG, CONFIG_SHADOW_CALL_STACK, CONFIG_LTO_CLANG_THIN

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

http_get() {
    # Upstream (android.googlesource.com) returns transient 503/429 on cold/first hit.
    # Retry with backoff so a flaky response does not abort the build.
    local url="$1" attempt=1 delay=3
    while [ "${attempt}" -le 3 ]; do
        if curl -fsSL --connect-timeout 5 --max-time 60 "${url}" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ "${attempt}" -le 3 ]; then
            warn "Request failed (${url}), retrying in ${delay}s..."
            sleep "${delay}"
            delay=$((delay * 2))
        fi
    done
    return 1
}

http_download() {
    local out="$1" url="$2" attempt=1 delay=5
    while [ "${attempt}" -le 3 ]; do
        if curl -fsSL --connect-timeout 10 -o "${out}" "${url}"; then
            return 0
        fi
        rm -f "${out}"
        attempt=$((attempt + 1))
        if [ "${attempt}" -le 3 ]; then
            warn "Download failed (${url}), retrying in ${delay}s..."
            sleep "${delay}"
            delay=$((delay * 2))
        fi
    done
    return 1
}

verify_archive_hash() {
    local file="$1" expected_hash="${2:-}"
    [ -z "${expected_hash}" ] && return 0
    if command -v sha256sum >/dev/null 2>&1; then
        local actual_hash
        actual_hash=$(sha256sum "${file}" | awk '{print $1}')
        if [ "${actual_hash}" != "${expected_hash}" ]; then
            rm -f "${file}"
            err "Checksum verification failed for ${file} (expected: ${expected_hash}, got: ${actual_hash})"
        fi
        msg "Archive checksum verified: ${file}"
    fi
}

#==============================================================================
# Configuration and globals
#==============================================================================

readonly KERNEL_DIR="${PWD}"
readonly KERNEL_BUILD_NUM_FILE="${KERNEL_DIR}/.build_number"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "${KERNEL_DIR}")"

# Working dirs
AK3_DIR="${AK3_DIR:-${KERNEL_DIR}/AnyKernel3}"
[ ! -d "${AK3_DIR}" ] && [ -d "${SCRIPT_DIR}/../AnyKernel3" ] && AK3_DIR="${SCRIPT_DIR}/../AnyKernel3"
KSU_DIR="${KSU_DIR:-${KERNEL_DIR}/KernelSU}"
[ ! -d "${KSU_DIR}" ] && [ -d "${SCRIPT_DIR}/../KernelSU" ] && KSU_DIR="${SCRIPT_DIR}/../KernelSU"

# Toolchain sources
MKDTIMG_URL="https://raw.githubusercontent.com/Reinazhard/scripts/refs/heads/main/utility/mkdtimg"
MKDTIMG_FLAGS="--page_size=4096 --id=/:board_id --rev=/:board_rev"
GCC_REPO="guacamole-sickness%2Fgs-infra%2Fgcc"
LLVM_BASE_URL="https://www.kernel.org/pub/tools/llvm/files"

# Normalize CI & flags
[ "${CI}" = "true" ] && CI=1
for v in CI CLEAN SIGN NOTIFY LOG RELEASE KSU; do
    eval "val=\$$v"
    case "${val}" in
        0|1) ;;
        *) err "${v} must be 0 or 1, got: ${val}" ;;
    esac
done

[ "${CI}" = "1" ] && { SIGN=1; RELEASE=1; CLEAN=1; LOG=1; NOTIFY=1; }
IS_RELEASE="${RELEASE}"
[ "${CI}" = "1" ] && IS_RELEASE=1
readonly CHATID IS_RELEASE

# Output directory
if [ -z "${OUT_DIR:-}" ]; then
    OUT_DIR="${KERNEL_DIR}/out"
else
    case "${OUT_DIR}" in
        /*) ;;
        *) OUT_DIR="${KERNEL_DIR}/${OUT_DIR}" ;;
    esac
fi
readonly OUT_DIR

# Artifact paths
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/${KERNEL_IMAGE}"
DTB_PATHS=""
for dtb in ${DTB_FILES}; do
    DTB_PATHS="${DTB_PATHS} ${OUT_DIR}/google-devices/raviole/dts/gs101/${dtb}"
done
DTB_PATHS="${DTB_PATHS# }"

AK3_IMAGE="${AK3_DIR}/${KERNEL_IMAGE}"
AK3_DTB="${AK3_DIR}/dtb"
AK3_DTBO="${AK3_DIR}/dtbo.img"
BUILD_DURATION=0
# Default so the EXIT trap can report a failure before setup_environment assigns it
KERNEL_BUILD_NUM="${KERNEL_BUILD_NUM:-1}"

#==============================================================================
# Local resource discovery & compiler fallbacks
#==============================================================================

find_mkdtimg() {
    [ -n "${MKDTIMG:-}" ] && [ -x "${MKDTIMG}" ] && echo "${MKDTIMG}" && return 0
    for p in "${KERNEL_DIR}/mkdtimg" "${KERNEL_DIR}/scripts/dtc/mkdtimg" \
             "${SCRIPT_DIR}/../utility/mkdtimg" "${SCRIPT_DIR}/utility/mkdtimg" \
             "${KERNEL_DIR}/utility/mkdtimg" "${KERNEL_DIR}/scripts/utility/mkdtimg"; do
        [ -x "${p}" ] && echo "${p}" && return 0
    done
    command -v mkdtimg 2>/dev/null && return 0
    return 1
}

find_zipsigner() {
    [ -n "${ZIPSIGNER_JAR:-}" ] && [ -f "${ZIPSIGNER_JAR}" ] && echo "${ZIPSIGNER_JAR}" && return 0
    for p in "${KERNEL_DIR}/zipsigner-3.0.jar" "${KERNEL_DIR}/zipsigner.jar" \
             "${SCRIPT_DIR}/../utility/zipsigner-3.0.jar" "${SCRIPT_DIR}/../utility/zipsigner.jar"; do
        [ -f "${p}" ] && echo "${p}" && return 0
    done
    return 1
}

find_cached_dir() {
    local pattern="$1" check_bin1="$2" check_bin2="${3:-}"
    local search_dirs="${KERNEL_DIR}"
    [ -d "${TOOLCHAIN_CACHE_DIR}" ] && search_dirs="${search_dirs} ${TOOLCHAIN_CACHE_DIR}"

    local latest="" best_dir=""
    for sdir in ${search_dirs}; do
        for cand in "${sdir}"/${pattern}; do
            [ ! -d "${cand}" ] && continue
            if [ -f "${cand}/.done" ] || [ -x "${cand}/${check_bin1}" ] || { [ -n "${check_bin2}" ] && [ -x "${cand}/${check_bin2}" ]; }; then
                local bname="${cand##*/}"
                if [ -z "${latest}" ] || [ "$(printf '%s\n%s' "${latest}" "${bname}" | sort -V | tail -n1)" = "${bname}" ]; then
                    latest="${bname}"
                    best_dir="${cand}"
                fi
            fi
        done
    done
    [ -n "${best_dir}" ] && echo "${best_dir}" && return 0
    return 1
}

find_cached_aosp_clang() {
    if [ -n "${CLANG_PREBUILT_NAME:-}" ]; then
        for b in "${KERNEL_DIR}" "${TOOLCHAIN_CACHE_DIR}"; do
            local p="${b}/${CLANG_PREBUILT_NAME}"
            [ -d "${p}" ] && { [ -f "${p}/.done" ] || [ -x "${p}/bin/clang" ]; } && echo "${p}" && return 0
        done
    fi
    find_cached_dir 'clang-r*' 'bin/clang'
}

find_cached_llvm() {
    if [ -n "${LLVM_VERSION:-}" ]; then
        for b in "${KERNEL_DIR}" "${TOOLCHAIN_CACHE_DIR}"; do
            local p="${b}/llvm-${LLVM_VERSION}"
            [ -d "${p}" ] && { [ -f "${p}/.done" ] || [ -x "${p}/bin/clang" ]; } && echo "${p}" && return 0
        done
    fi
    find_cached_dir 'llvm-*' 'bin/clang'
}

find_cached_gcc() {
    find_cached_dir 'gcc-*' 'gcc-arm64/bin/aarch64-linux-gnu-gcc' 'bin/aarch64-linux-gnu-gcc'
}

resolve_custom_clang() {
    [ -z "${CLANG_TOOLCHAIN_DIR:-}" ] && return 1
    CLANG_TOOLCHAIN_DIR="${CLANG_TOOLCHAIN_DIR%/}"
    [ -x "${CLANG_TOOLCHAIN_DIR}/bin/clang" ] && return 0
    if [ -x "${CLANG_TOOLCHAIN_DIR}/clang" ]; then
        CLANG_TOOLCHAIN_DIR="$(dirname "${CLANG_TOOLCHAIN_DIR}")"
        return 0
    fi
    return 1
}

resolve_custom_gcc() {
    if [ -n "${GCC_TOOLCHAIN_DIR:-}" ]; then
        GCC_TOOLCHAIN_DIR="${GCC_TOOLCHAIN_DIR%/}"
        if [ -x "${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin/aarch64-linux-gnu-gcc" ] || [ -x "${GCC_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-gcc" ]; then
            return 0
        fi
    fi
    return 1
}

fallback_system_clang() {
    local reason="$1"
    if command -v clang >/dev/null 2>&1; then
        local sys_dir
        sys_dir=$(dirname "$(dirname "$(command -v clang)")")
        if [ -x "${sys_dir}/bin/clang" ]; then
            warn "${reason}. Falling back to system Clang: ${sys_dir}"
            CLANG_TOOLCHAIN_DIR="${sys_dir}"
            return 0
        fi
    fi
    return 1
}

fallback_system_gcc() {
    local reason="$1"
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        warn "${reason}. Falling back to system aarch64-linux-gnu-gcc"
        CROSS_COMPILE="aarch64-linux-gnu-"
        [ -z "${CROSS_COMPILE_COMPAT:-}" ] && command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1 && CROSS_COMPILE_COMPAT="arm-linux-gnueabihf-"
        return 0
    fi
    return 1
}

#==============================================================================
# Dependency checking
#==============================================================================

check_dependencies() {
    local missing="" deps="git make unzip zip"
    [ "${SIGN}" = "1" ] && deps="${deps} java"

    local need_curl=0
    [ "${NOTIFY}" = "1" ] && need_curl=1

    case "${TOOLCHAIN}" in
        clang)
            if [ -z "${CLANG_TOOLCHAIN_DIR:-}" ]; then
                case "${CLANG_SOURCE}" in
                    aosp) find_cached_aosp_clang >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || need_curl=1 ;;
                    llvm) find_cached_llvm >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || need_curl=1 ;;
                esac
            fi
            ;;
        gcc)
            deps="${deps} zstd"
            if [ -z "${GCC_TOOLCHAIN_DIR:-}" ] && [ -z "${CROSS_COMPILE:-}" ]; then
                if ! find_cached_gcc >/dev/null 2>&1 && ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
                    need_curl=1
                    deps="${deps} xz"
                fi
            fi
            ;;
    esac

    find_mkdtimg >/dev/null 2>&1 || need_curl=1
    [ "${SIGN}" = "1" ] && { find_zipsigner >/dev/null 2>&1 || need_curl=1; }
    [ "${need_curl}" = "1" ] && deps="${deps} curl"

    for cmd in ${deps}; do
        command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
    done

    if [ -n "${missing}" ]; then
        err "Missing dependencies:${missing}"
    fi
}

#==============================================================================
# Toolchain fetch functions
#==============================================================================

fetch_gcc_toolchain() {
    if resolve_custom_gcc; then
        msg "Using specified GCC toolchain: ${GCC_TOOLCHAIN_DIR}"
        return 0
    fi

    if [ -n "${CROSS_COMPILE:-}" ] && command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
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
    local tag
    tag=$(http_get "https://gitlab.com/api/v4/projects/${GCC_REPO}/releases" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)

    if [ -z "${tag}" ]; then
        fallback_system_gcc "Could not reach GCC releases server (offline?)" && return 0
        err "Failed to fetch latest GCC toolchain tag (offline?) and no local GCC found. Set GCC_TOOLCHAIN_DIR or CROSS_COMPILE."
    fi

    msg "Latest GCC toolchain: ${tag}"
    mkdir -p "${TOOLCHAIN_CACHE_DIR}"
    local gcc_dir="${TOOLCHAIN_CACHE_DIR}/gcc-${tag}"
    if [ -f "${gcc_dir}/.done" ] || [ -x "${gcc_dir}/gcc-arm64/bin/aarch64-linux-gnu-gcc" ]; then
        msg "GCC toolchain already cached: ${gcc_dir}"
        GCC_TOOLCHAIN_DIR="${gcc_dir}"
        return 0
    fi

    msg "Downloading GCC toolchains..."
    mkdir -p "${gcc_dir}"
    local assets
    assets=$(http_get "https://gitlab.com/api/v4/projects/${GCC_REPO}/releases/${tag}" \
        | sed -n 's/.*"direct_asset_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)

    local arm64_url arm_url
    arm64_url=$(echo "${assets}" | grep 'toolchain-arm64-.*\.tar\.zst$' || true)
    arm_url=$(echo "${assets}" | grep 'toolchain-arm-' | grep -v arm64 | grep '\.tar\.zst$' || true)

    if [ -z "${arm64_url}" ]; then
        fallback_system_gcc "Failed to find arm64 GCC in release" && return 0
        err "Failed to find arm64 GCC toolchain in release ${tag}"
    fi

    msg "Downloading arm64 GCC toolchain..."
    if ! http_download "${gcc_dir}/arm64.tar.zst" "${arm64_url}"; then
        fallback_system_gcc "Failed to download arm64 GCC (offline?)" && return 0
        err "Failed to download arm64 GCC toolchain"
    fi

    msg "Extracting arm64 GCC toolchain..."
    tar -I zstd -xf "${gcc_dir}/arm64.tar.zst" -C "${gcc_dir}" || err "Failed to extract arm64 GCC toolchain"
    rm -f "${gcc_dir}/arm64.tar.zst"

    if [ -n "${arm_url}" ]; then
        msg "Downloading arm32 GCC toolchain..."
        if http_download "${gcc_dir}/arm.tar.zst" "${arm_url}"; then
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

# Latest clang-rNNNNNN dir in the prebuilt branch.
# Primary: gitiles directory listing. Fallback: git protocol (blobless partial clone,
# ~1.3MB) because gitiles web is rate-limited/503 far more often than git-upload-pack.
discover_aosp_clang_name() {
    local name=""

    name=$(http_get "${CLANG_PREBUILT_BASE}/+/${CLANG_PREBUILT_BRANCH}" \
        | grep -oE 'clang-r[0-9]+' \
        | sed 's/^clang-//' \
        | sort -V \
        | tail -n1 || true)
    [ -n "${name}" ] && echo "clang-${name}" && return 0

    if command -v git >/dev/null 2>&1; then
        warn "Gitiles listing unavailable, discovering via git protocol..."
        local branch="${CLANG_PREBUILT_BRANCH##*/}"
        local tmp_git="${TOOLCHAIN_CACHE_DIR}/.clang-ls-tree"
        mkdir -p "${TOOLCHAIN_CACHE_DIR}"
        rm -rf "${tmp_git}"
        if git clone --filter=blob:none --no-checkout --depth 1 \
            -b "${branch}" "${CLANG_PREBUILT_BASE}" "${tmp_git}" >/dev/null 2>&1; then
            name=$(git -C "${tmp_git}" ls-tree --name-only HEAD \
                | grep -oE '^clang-r[0-9]+$' \
                | sed 's/^clang-//' \
                | sort -V \
                | tail -n1 || true)
        fi
        rm -rf "${tmp_git}"
        [ -n "${name}" ] && echo "clang-${name}" && return 0
    fi

    return 1
}

fetch_aosp_clang() {
    if resolve_custom_clang; then
        msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
        return 0
    fi

    local cached_dir
    if cached_dir=$(find_cached_aosp_clang); then
        msg "AOSP Clang already cached: ${cached_dir}"
        CLANG_TOOLCHAIN_DIR="${cached_dir}"
        return 0
    fi

    local clang_name="${CLANG_PREBUILT_NAME:-}"
    if [ -z "${clang_name}" ]; then
        msg "Discovering latest AOSP Clang prebuilt..."
        if clang_name=$(discover_aosp_clang_name); then
            msg "Latest AOSP Clang: ${clang_name}"
        else
            clang_name=""
        fi
    fi

    if [ -z "${clang_name}" ]; then
        fallback_system_clang "Could not reach AOSP prebuilt server (offline?)" && return 0
        err "Failed to discover AOSP Clang prebuilt (offline?) and no local Clang found. Set CLANG_TOOLCHAIN_DIR."
    fi

    mkdir -p "${TOOLCHAIN_CACHE_DIR}"
    local clang_dir="${TOOLCHAIN_CACHE_DIR}/${clang_name}"
    if [ -f "${clang_dir}/.done" ] || [ -x "${clang_dir}/bin/clang" ]; then
        msg "AOSP Clang already cached: ${clang_dir}"
        CLANG_TOOLCHAIN_DIR="${clang_dir}"
        return 0
    fi

    local url="${CLANG_PREBUILT_BASE}/+archive/${CLANG_PREBUILT_BRANCH}/${clang_name}.tar.gz"
    local tarball="/tmp/${clang_name}.tar.gz"
    msg "Downloading AOSP Clang..."
    if ! http_download "${tarball}" "${url}"; then
        fallback_system_clang "Failed to download AOSP Clang (offline?)" && return 0
        err "Failed to download AOSP Clang from ${url} (offline?). Set CLANG_TOOLCHAIN_DIR."
    fi

    msg "Extracting AOSP Clang..."
    rm -rf "${clang_dir}"
    mkdir -p "${clang_dir}"
    tar -xzf "${tarball}" -C "${clang_dir}" || err "Failed to extract AOSP Clang"
    rm -f "${tarball}"

    touch "${clang_dir}/.done"
    CLANG_TOOLCHAIN_DIR="${clang_dir}"
    msg "AOSP Clang installed: ${clang_dir}"
}

fetch_clang_toolchain() {
    if resolve_custom_clang; then
        msg "Using specified Clang toolchain: ${CLANG_TOOLCHAIN_DIR}"
        return 0
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
        version=$(http_get "${LLVM_BASE_URL}/" \
            | sed -n 's/.*llvm-\([0-9]*\.[0-9]*\.[0-9]*\)-x86_64\.tar\.xz.*/\1/p' \
            | sort -V \
            | tail -n1 || true)
        [ -n "${version}" ] && msg "Latest LLVM: ${version}"
    fi

    if [ -z "${version}" ]; then
        fallback_system_clang "Could not reach LLVM server (offline?)" && return 0
        err "Failed to determine LLVM version (offline?) and no local Clang found. Set LLVM_VERSION or CLANG_TOOLCHAIN_DIR."
    fi

    mkdir -p "${TOOLCHAIN_CACHE_DIR}"
    local clang_dir="${TOOLCHAIN_CACHE_DIR}/llvm-${version}"
    if [ -f "${clang_dir}/.done" ] || [ -x "${clang_dir}/bin/clang" ]; then
        msg "LLVM toolchain already cached: ${clang_dir}"
        CLANG_TOOLCHAIN_DIR="${clang_dir}"
        return 0
    fi

    msg "Downloading LLVM ${version}..."
    local tarball="/tmp/llvm-${version}-x86_64.tar.xz"
    if ! http_download "${tarball}" "${LLVM_BASE_URL}/llvm-${version}-x86_64.tar.xz"; then
        fallback_system_clang "Failed to download LLVM (offline?)" && return 0
        err "Failed to download LLVM ${version} (offline?). Set CLANG_TOOLCHAIN_DIR."
    fi

    msg "Extracting LLVM toolchain..."
    rm -rf "${clang_dir}"
    mkdir -p "${clang_dir}"
    tar -xJf "${tarball}" --strip-components=1 -C "${clang_dir}" || err "Failed to extract LLVM ${version}"
    rm -f "${tarball}"

    touch "${clang_dir}/.done"
    CLANG_TOOLCHAIN_DIR="${clang_dir}"
    msg "LLVM toolchain installed: ${clang_dir}"
}

#==============================================================================
# Build environment setup
#==============================================================================

setup_environment() {
    msg "Setting up build environment..."
    check_dependencies

    case "${TOOLCHAIN}" in
        gcc)
            fetch_gcc_toolchain
            if [ -n "${GCC_TOOLCHAIN_DIR:-}" ]; then
                local gbin="${GCC_TOOLCHAIN_DIR}/bin"
                [ -d "${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin" ] && gbin="${GCC_TOOLCHAIN_DIR}/gcc-arm64/bin"
                local gcompat="${GCC_TOOLCHAIN_DIR}/bin/arm-linux-gnueabihf-"
                [ -d "${GCC_TOOLCHAIN_DIR}/gcc-arm/bin" ] && gcompat="${GCC_TOOLCHAIN_DIR}/gcc-arm/bin/arm-linux-gnueabihf-"
                export CROSS_COMPILE="${CROSS_COMPILE:-${gbin}/aarch64-linux-gnu-}"
                export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-${gcompat}}"
            else
                export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
                export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-arm-linux-gnueabihf-}"
            fi
            ;;
        clang)
            case "${CLANG_SOURCE}" in
                aosp) fetch_aosp_clang ;;
                llvm) fetch_clang_toolchain ;;
                *) err "Unknown CLANG_SOURCE: ${CLANG_SOURCE}. Use 'aosp' or 'llvm'." ;;
            esac
            resolve_custom_clang || true
            ;;
        *)
            err "Unknown toolchain: ${TOOLCHAIN}. Use 'gcc' or 'clang'."
            ;;
    esac

    # AnyKernel3 setup
    if [ ! -d "${AK3_DIR}" ]; then
        if [ -d "${SCRIPT_DIR}/../AnyKernel3" ]; then
            AK3_DIR="${SCRIPT_DIR}/../AnyKernel3"
            msg "Using AnyKernel3 from: ${AK3_DIR}"
        else
            msg "Cloning AnyKernel3 from ${AK3_REPO}..."
            git clone "https://github.com/${AK3_REPO}.git" --single-branch --depth 1 "${AK3_DIR}" 2>/dev/null || \
                warn "Failed to clone AnyKernel3 (offline?). Flashable zip packaging will be skipped."
        fi
    fi
    AK3_IMAGE="${AK3_DIR}/${KERNEL_IMAGE}"
    AK3_DTB="${AK3_DIR}/dtb"
    AK3_DTBO="${AK3_DIR}/dtbo.img"

    # KernelSU setup (required for Kconfig evaluation even when KSU=0)
    if [ ! -d "${KSU_DIR}" ]; then
        if [ -d "${SCRIPT_DIR}/../KernelSU" ]; then
            KSU_DIR="${SCRIPT_DIR}/../KernelSU"
            msg "Using KernelSU from: ${KSU_DIR}"
        else
            msg "Cloning KernelSU from ${KSU_REPO}..."
            git clone "https://github.com/${KSU_REPO}.git" -b "${KSU_BRANCH}" --single-branch --depth 1 "${KSU_DIR}" || \
                err "KernelSU not found at ${KSU_DIR} and could not be cloned (offline?). Set KSU_DIR."
        fi
    fi
    if [ "${KSU_DIR}" != "${KERNEL_DIR}/KernelSU" ] && [ ! -e "${KERNEL_DIR}/KernelSU" ]; then
        ln -sfn "${KSU_DIR}" "${KERNEL_DIR}/KernelSU"
    fi

    export ARCH="arm64"
    PROCS=$(nproc --all)
    export PROCS

    if [ "${TOOLCHAIN}" = "clang" ]; then
        KBUILD_COMPILER_STRING=$("${CLANG_TOOLCHAIN_DIR}/bin/clang" --version 2>/dev/null | head -n 1 \
            | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    else
        KBUILD_COMPILER_STRING=$("${CROSS_COMPILE}gcc" --version 2>/dev/null | head -n 1)
    fi
    export KBUILD_COMPILER_STRING

    [ "${IS_RELEASE}" = "1" ] && export KBUILD_BUILD_TIMESTAMP
    export KBUILD_BUILD_USER KBUILD_BUILD_HOST

    KERVER=$(make kernelversion 2>/dev/null || echo "unknown")
    COMMIT_HEAD=$(git log -n 1 --oneline 2>/dev/null || echo "unknown")
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    export KERVER COMMIT_HEAD CI_BRANCH

    BUMP="${BUMP:-1}"
    if [ "${IS_RELEASE}" = "1" ]; then
        KERNEL_BUILD_NUM="1"
    elif [ "${BUMP}" = "0" ] && [ -f "${KERNEL_BUILD_NUM_FILE}" ]; then
        KERNEL_BUILD_NUM=$(cat "${KERNEL_BUILD_NUM_FILE}")
    elif [ -f "${KERNEL_BUILD_NUM_FILE}" ]; then
        KERNEL_BUILD_NUM=$(($(cat "${KERNEL_BUILD_NUM_FILE}") + 1))
    else
        KERNEL_BUILD_NUM="0"
    fi
    [ "${IS_RELEASE}" = "0" ] && [ "${BUMP}" != "0" ] && echo "${KERNEL_BUILD_NUM}" > "${KERNEL_BUILD_NUM_FILE}"
    export KERNEL_BUILD_NUM

    mkdir -p "${OUT_DIR}"

    local build_label="Build #${KERNEL_BUILD_NUM}"
    [ "${IS_RELEASE}" = "1" ] && build_label="RELEASE Build"
    msg "${build_label} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Toolchain: ${TOOLCHAIN} | Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS} | Clean: $([ "${CLEAN}" = "1" ] && echo "Enabled" || echo "Disabled")"
}

#==============================================================================
# Telegram notifications
#==============================================================================

tg_post_msg() {
    local message="$1"
    [ "${NOTIFY}" != "1" ] || [ -z "${TELEGRAM_TOKEN:-}" ] && return 0

    local attempt=1 wait_time=2
    while [ "${attempt}" -le 3 ]; do
        curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d chat_id="${CHATID}" -d "disable_web_page_preview=true" \
            -d "parse_mode=html" -d text="${message}" >/dev/null 2>&1 && return 0
        [ "${attempt}" -lt 3 ] && sleep "${wait_time}"
        wait_time=$((wait_time * 2))
        attempt=$((attempt + 1))
    done
    warn "Failed to send Telegram message after 3 attempts"
}

tg_post_build() {
    local file="$1" caption="$2"
    [ "${NOTIFY}" != "1" ] || [ -z "${TELEGRAM_TOKEN:-}" ] && return 0

    msg "Uploading to Telegram..."
    local attempt=1 wait_time=5
    while [ "${attempt}" -le 5 ]; do
        msg "Upload attempt ${attempt}/5..."
        if curl -f --progress-bar --max-time 300 -F document=@"${file}" \
            -F chat_id="${CHATID}" -F "disable_web_page_preview=true" \
            -F "parse_mode=html" -F caption="${caption}" \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" 2>/dev/null; then
            msg "Upload successful!"
            return 0
        fi
        [ "${attempt}" -lt 5 ] && warn "Upload failed, retrying in ${wait_time}s..." && sleep "${wait_time}"
        wait_time=$((wait_time * 2))
        attempt=$((attempt + 1))
    done
    warn "Failed to upload after 5 attempts (build artifact is at: ${file})"
    return 1
}

tg_notify_failure() {
    local variant="$1" reason="$2"
    local label="Build #${KERNEL_BUILD_NUM:-0}"
    [ "${IS_RELEASE}" = "1" ] && label="Release"
    tg_post_msg "<b>❌ ${variant} ${label} failed: ${reason}</b>"
}

#==============================================================================
# Build operations & error trap
#==============================================================================

clean_build() {
    [ "${CLEAN}" = "0" ] && msg "Skipping clean (CLEAN=0)" && return 0
    msg "Cleaning build environment..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    if [ -d "${AK3_DIR}" ]; then
        rm -f "${AK3_DIR}"/*.zip "${AK3_DIR}/${KERNEL_IMAGE}" "${AK3_DIR}/dtb" "${AK3_DIR}/dtbo.img" 2>/dev/null || true
    fi
    msg "Build environment cleaned"
}

on_exit() {
    local exit_code=$?
    cd "${KERNEL_DIR}"
    [ ${exit_code} -ne 0 ] && tg_notify_failure "Build" "failed (exit code: ${exit_code})"
    exit "${exit_code}"
}

compute_localversion() {
    local variant="$1" lv=""
    [ "${variant}" = "KernelSU" ] && lv="-ybrt"
    [ "${IS_RELEASE}" = "0" ] && lv="${lv}-b${KERNEL_BUILD_NUM}"
    echo "${lv}"
}

#==============================================================================
# Kernel compilation & output verification
#==============================================================================

make_kernel() {
    local make_args="-j${PROCS} O=${OUT_DIR} ARCH=${ARCH}"
    case "${TOOLCHAIN}" in
        clang)
            make_args="${make_args} LLVM=${CLANG_TOOLCHAIN_DIR}/bin/ LLVM_IAS=1"
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
    local config_file="${OUT_DIR}/.config"
    local variant_file="${OUT_DIR}/.config_variant"

    if [ "${CLEAN}" = "0" ] && [ -f "${config_file}" ] && [ -f "${variant_file}" ] && [ "$(cat "${variant_file}" 2>/dev/null)" = "${variant}" ]; then
        msg "Reusing existing ${variant} configuration..."
        make_kernel olddefconfig >/dev/null || err "Failed to finalize configuration"
        return 0
    fi

    msg "Configuring ${variant} kernel..."

    make_kernel "${DEFCONFIG}" >/dev/null || err "Failed to generate ${DEFCONFIG}"

    if [ "${variant}" = "KernelSU" ]; then
        msg "Enabling KernelSU features..."
        scripts/config --file "${config_file}" -e KSU || err "Failed to enable KernelSU features"
    fi

    if [ "${TOOLCHAIN}" = "clang" ] && [ "${IS_RELEASE}" = "1" ]; then
        msg "Enabling clang hardening features (CFI, SCS, LTO_THIN)..."
        scripts/config --file "${config_file}" \
            -e CONFIG_CFI_CLANG \
            -e CONFIG_SHADOW_CALL_STACK \
            -e CONFIG_LTO_CLANG_THIN \
            -d CONFIG_LTO_CLANG_FULL || err "Failed to enable clang hardening features"
    fi

    make_kernel olddefconfig >/dev/null || err "Failed to finalize configuration"
    echo "${variant}" > "${variant_file}"
    msg "Configuration complete"
}

compile_kernel() {
    local variant="$1"
    msg "Building ${variant} kernel..."
    local start status=0
    start=$(date +%s)
    make_kernel || status=$?
    BUILD_DURATION=$(($(date +%s) - start))
    [ ${status} -ne 0 ] && err "${variant} kernel compilation failed"
    msg "${variant} compilation completed in $(format_duration ${BUILD_DURATION})"
}

verify_build_outputs() {
    local variant="$1"
    msg "Verifying build outputs..."
    [ -f "${IMAGE_PATH}" ] || err "${KERNEL_IMAGE} not found at ${IMAGE_PATH}"
    for dtb in ${DTB_PATHS}; do
        [ -f "${dtb}" ] || err "DTB files not found: ${dtb}"
    done
    msg "${variant} build outputs verified"
}

#==============================================================================
# DTBO & AnyKernel3 packaging
#==============================================================================

generate_dtbo() {
    local variant="$1"
    msg "Generating dtbo.img..."

    local mkdtimg_bin
    if ! mkdtimg_bin=$(find_mkdtimg); then
        msg "Downloading mkdtimg..."
        http_download "${KERNEL_DIR}/mkdtimg" "${MKDTIMG_URL}" || \
            err "mkdtimg not found and could not be downloaded (offline?). Set MKDTIMG."
        chmod +x "${KERNEL_DIR}/mkdtimg"
        mkdtimg_bin="${KERNEL_DIR}/mkdtimg"
    fi

    local dtbo_files
    dtbo_files=$(find "${OUT_DIR}" -name 'gs*.dtbo' | sort)
    [ -z "${dtbo_files}" ] && err "No gs*.dtbo files found in ${OUT_DIR}"

    cd "${KERNEL_DIR}"
    # shellcheck disable=SC2086
    "${mkdtimg_bin}" create "${OUT_DIR}/dtbo.img" ${MKDTIMG_FLAGS} ${dtbo_files} || \
        err "Failed to generate dtbo.img"

    msg "dtbo.img generated ($(echo ${dtbo_files} | wc -w) dtbo file(s))"
}

construct_zip_filename() {
    local suffix="$1"
    local name="${ZIPNAME}-${DEVICE}"
    [ -n "${suffix}" ] && name="${name}-${suffix}"
    [ "${IS_RELEASE}" = "0" ] && name="${name}-b${KERNEL_BUILD_NUM}"
    echo "${name}.zip"
}

generate_zip() {
    local variant="$1" zip_suffix="$2"

    if [ ! -d "${AK3_DIR}" ]; then
        warn "AnyKernel3 not found at ${AK3_DIR}. Skipping flashable zip packaging."
        msg "Kernel build output is available at: ${IMAGE_PATH}"
        return 0
    fi

    local zip_final
    zip_final=$(construct_zip_filename "${zip_suffix}")
    msg "Packaging ${variant} flashable zip: ${zip_final}"

    cp "${IMAGE_PATH}" "${AK3_IMAGE}" || err "Failed to copy ${KERNEL_IMAGE} to AnyKernel3"
    cat ${DTB_PATHS} > "${AK3_DTB}" || err "Failed to create DTB file"
    cp "${OUT_DIR}/dtbo.img" "${AK3_DTBO}" || err "Failed to copy dtbo.img to AnyKernel3"

    cd "${AK3_DIR}" || err "Failed to enter AnyKernel3 directory"
    rm -f unsigned.zip

    zip -r9 -q "unsigned.zip" . \
        -x '*.git*/*' -x '*.github*/*' -x '*README.md*' -x '*.zip*' -x 'zipsigner*' || {
        cd "${KERNEL_DIR}"
        err "Failed to create unsigned zip"
    }

    msg "Validating zip integrity..."
    zip -T "unsigned.zip" >/dev/null 2>&1 || {
        cd "${KERNEL_DIR}"
        err "Zip validation failed"
    }

    local zip_final_path="${AK3_DIR}/${zip_final}"
    if [ "${SIGN}" = "1" ]; then
        local zipsigner_jar
        if ! zipsigner_jar=$(find_zipsigner); then
            msg "Downloading zipsigner..."
            if http_download "${KERNEL_DIR}/zipsigner-3.0.jar" "https://raw.githubusercontent.com/raphielscape/scripts/master/zipsigner-3.0.jar"; then
                zipsigner_jar="${KERNEL_DIR}/zipsigner-3.0.jar"
            else
                warn "Failed to download zipsigner (offline?). Leaving zip unsigned."
            fi
        fi

        if [ -n "${zipsigner_jar:-}" ] && [ -f "${zipsigner_jar}" ]; then
            msg "Signing ${zip_final}..."
            java -jar "${zipsigner_jar}" unsigned.zip "${zip_final}" || {
                cd "${KERNEL_DIR}"
                err "Failed to sign zip"
            }
            rm -f unsigned.zip
        else
            mv "unsigned.zip" "${zip_final}"
        fi
    else
        mv "unsigned.zip" "${zip_final}"
    fi

    local build_info="Build #${KERNEL_BUILD_NUM}"
    [ "${IS_RELEASE}" = "1" ] && build_info="Release"
    local caption="✅ ${variant} completed in $(format_duration ${BUILD_DURATION}) | <code>${build_info}</code>"
    tg_post_build "${zip_final_path}" "${caption}"

    msg "Flashable zip: ${zip_final_path}"
    cd "${KERNEL_DIR}"
}

#==============================================================================
# Build orchestration
#==============================================================================

build_variant() {
    local variant="$1" is_ksu="$2"

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

    msg "${variant} build complete"
}

#==============================================================================
# Toolchain management CLI operations
#==============================================================================

list_toolchains() {
    msg "Cached Toolchains:"
    local found=0
    for sdir in "${TOOLCHAIN_CACHE_DIR}" "${KERNEL_DIR}"; do
        [ ! -d "${sdir}" ] && continue
        for tc in "${sdir}"/clang-r* "${sdir}"/llvm-* "${sdir}"/gcc-*; do
            [ ! -d "${tc}" ] && continue
            local sz tag="shared-cache"
            sz=$(du -sh "${tc}" 2>/dev/null | cut -f1)
            [ "${sdir}" = "${KERNEL_DIR}" ] && tag="local"
            printf "  - %-22s [%-12s] (%s) -> %s\n" "${tc##*/}" "${tag}" "${sz}" "${tc}"
            found=1
        done
    done
    if [ ${found} -eq 0 ]; then
        msg "  No cached toolchains found in:"
        msg "    - Cache:  ${TOOLCHAIN_CACHE_DIR}"
        msg "    - Kernel: ${KERNEL_DIR}"
    fi
    exit 0
}

clean_cache() {
    if [ -d "${TOOLCHAIN_CACHE_DIR}" ]; then
        msg "Cleaning toolchain cache: ${TOOLCHAIN_CACHE_DIR}..."
        rm -rf "${TOOLCHAIN_CACHE_DIR}"
        msg "Toolchain cache cleaned."
    else
        msg "Toolchain cache directory does not exist: ${TOOLCHAIN_CACHE_DIR}"
    fi
    exit 0
}

prefetch_toolchain() {
    msg "Prefetching toolchain (TOOLCHAIN=${TOOLCHAIN}, CLANG_SOURCE=${CLANG_SOURCE})..."
    check_dependencies
    case "${TOOLCHAIN}" in
        gcc)
            fetch_gcc_toolchain
            msg "GCC toolchain ready: ${GCC_TOOLCHAIN_DIR}"
            ;;
        clang)
            case "${CLANG_SOURCE}" in
                aosp)
                    fetch_aosp_clang
                    msg "AOSP Clang ready: ${CLANG_TOOLCHAIN_DIR}"
                    ;;
                llvm)
                    fetch_clang_toolchain
                    msg "LLVM Clang ready: ${CLANG_TOOLCHAIN_DIR}"
                    ;;
            esac
            ;;
    esac
    msg "Prefetch complete."
    exit 0
}

handle_args() {
    for arg in "$@"; do
        case "${arg}" in
            --list-toolchains)
                list_toolchains
                ;;
            --clean-cache)
                clean_cache
                ;;
            --prefetch)
                prefetch_toolchain
                ;;
            --help|-h)
                cat << EOF
Raviole Kernel Build System

Usage: $0 [OPTIONS]

Options:
  --prefetch          Download and cache active toolchain without starting build
  --list-toolchains   List all cached toolchains and sizes
  --clean-cache       Remove all cached toolchains in TOOLCHAIN_CACHE_DIR
  -h, --help          Show this help message

Environment variables:
  TOOLCHAIN           Compiler toolchain: clang (default) or gcc
  CLANG_SOURCE        Clang source: aosp (default) or llvm
  TOOLCHAIN_CACHE_DIR Cache directory (default: ~/.cache/android-kernel-tools)
  CLANG_TOOLCHAIN_DIR Explicit path to Clang toolchain
  GCC_TOOLCHAIN_DIR   Explicit path to GCC toolchain
  CROSS_COMPILE       Prefix for GCC (e.g. aarch64-linux-gnu-)
  KSU                 Build KernelSU variant (0 or 1)
  CLEAN               Clean before build (0 or 1)
  BUMP                Increment build number (0 or 1, default: 1)
  SIGN                Sign flashable zip (0 or 1)
  NOTIFY              Send Telegram notifications (0 or 1)
  RELEASE             Release build mode (0 or 1)
  OUT_DIR             Build output directory (default: out)
EOF
                exit 0
                ;;
        esac
    done
}

#==============================================================================
# Main entry point
#==============================================================================

main() {
    handle_args "$@"
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

if [ "${LOG}" = "1" ]; then
    mkdir -p "${OUT_DIR}"
    LOG_FILE="${OUT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
    main "$@" 2>&1 | tee -a "${LOG_FILE}"
else
    main "$@"
fi
