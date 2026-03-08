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

cleanup() {
    local exit_code=$?
    [[ ${exit_code} -ne 0 ]] && warn "Build interrupted or failed (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap cleanup INT TERM EXIT

#==============================================================================
# Configuration and globals
#==============================================================================

readonly KERNEL_DIR="${PWD}"
readonly KERNEL_BUILD_NUM_FILE="${KERNEL_DIR}/.build_number"

# Device configuration
ZIPNAME="86hm"
DEVICE="gs101"
DEFCONFIG="raviole_defconfig"

# AnyKernel3 paths
AK3_DIR="${KERNEL_DIR}/AnyKernel3"
AK3_IMAGE="${AK3_DIR}/Image.lz4"
AK3_DTB="${AK3_DIR}/dtb"
AK3_DTBO="${AK3_DIR}/dtbo.img"

# mkdtimg configuration
# shellcheck disable=SC2034
MKDTIMG_URL="https://raw.githubusercontent.com/Reinazhard/scripts/refs/heads/main/utility/mkdtimg"
MKDTIMG_FLAGS="--page_size=4096 --id=/:board_id --rev=/:board_rev"

# LLVM toolchain configuration
LLVM_VERSION="${LLVM_VERSION:-22.1.0}"
LLVM_ARCHIVE="llvm-${LLVM_VERSION}-x86_64.tar.xz"
LLVM_URL="https://www.kernel.org/pub/tools/llvm/files/${LLVM_ARCHIVE}"
readonly TOOLCHAIN_DIR="${KERNEL_DIR}/kernel-toolchain"

# Release mode: 0 = test, 1 = release
RELEASE="${RELEASE:-0}"
[[ "${RELEASE}" != "0" && "${RELEASE}" != "1" ]] && err "RELEASE must be 0 or 1, got: ${RELEASE}"

# KernelSU mode: 0 = standard only, 1 = standard + KernelSU
KSU="${KSU:-0}"
if [[ "$KSU" != "0" && "$KSU" != "1" ]]; then
    err "KSU must be 0 or 1"
fi

# Clean control: 0 = skip clean (default), 1 = remove out dir before build
CLEAN="${CLEAN:-0}"
if [[ "$CLEAN" != "0" && "$CLEAN" != "1" ]]; then
    err "CLEAN must be 0 or 1"
fi

# Set output directory and Telegram chat based on release mode
# Allow OUT_DIR to be pre-set via environment variable for parallel CI builds
if [[ -z "${OUT_DIR}" ]]; then
    if [[ "${RELEASE}" == "1" ]]; then
        OUT_DIR="${KERNEL_DIR}/out-release"
    else
        OUT_DIR="${KERNEL_DIR}/out"
    fi
else
    # Ensure OUT_DIR is absolute path
    [[ "${OUT_DIR}" != /* ]] && OUT_DIR="${KERNEL_DIR}/${OUT_DIR}"
fi

if [[ "${RELEASE}" == "1" ]]; then
    CHATID="-1001493260868"
else
    CHATID="-1001403511595"
fi

readonly OUT_DIR CHATID

# Build artifact paths (depend on OUT_DIR)
CONFIG_FILE="${OUT_DIR}/.config"
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/Image.lz4"
DTB_FILES=(
    "${OUT_DIR}/google-devices/raviole/dts/gs101/gs101-a0.dtb"
    "${OUT_DIR}/google-devices/raviole/dts/gs101/gs101-b0.dtb"
)

# Telegram configuration
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
readonly BOT_MSG_URL="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"
readonly BOT_BUILD_URL="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument"

# Build timing
BUILD_DURATION=0

#==============================================================================
# Build number management
#==============================================================================

get_build_num() {
    [[ -f "${KERNEL_BUILD_NUM_FILE}" ]] && cat "${KERNEL_BUILD_NUM_FILE}" || echo "0"
}

increment_build_num() {
    local next=$(( $(get_build_num) + 1 ))
    echo "${next}" > "${KERNEL_BUILD_NUM_FILE}"
    echo "${next}"
}

#==============================================================================
# Toolchain validation
#==============================================================================

validate_toolchain() {
    msg "Validating toolchain..."
    command -v clang &> /dev/null || err "clang not found in PATH"
    command -v ld.lld &> /dev/null || err "ld.lld not found in PATH (required for LLVM=1)"
    msg "Toolchain validation passed"
}

#==============================================================================
# Toolchain setup
#==============================================================================

setup_toolchain() {
    if [[ -f "${TOOLCHAIN_DIR}/bin/clang" ]]; then
        msg "Toolchain already present, skipping download"
    else
        msg "Downloading LLVM ${LLVM_VERSION} toolchain..."
        curl -L -o "${KERNEL_DIR}/${LLVM_ARCHIVE}" "${LLVM_URL}" || err "Failed to download LLVM toolchain"

        msg "Extracting LLVM toolchain..."
        tar -xf "${KERNEL_DIR}/${LLVM_ARCHIVE}" -C "${KERNEL_DIR}" || err "Failed to extract LLVM toolchain"

        local extracted_dir
        extracted_dir=$(find "${KERNEL_DIR}" -maxdepth 1 -name "llvm-*" -type d | head -1)
        [[ -z "${extracted_dir}" ]] && err "Could not find extracted LLVM directory"

        mv "${extracted_dir}" "${TOOLCHAIN_DIR}" || err "Failed to move LLVM toolchain to ${TOOLCHAIN_DIR}"

        rm -f "${KERNEL_DIR}/${LLVM_ARCHIVE}"
        msg "LLVM toolchain installed to ${TOOLCHAIN_DIR}"
    fi

    export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

    command -v clang &> /dev/null || err "LLVM toolchain setup failed"
}

#==============================================================================
# AnyKernel3 setup
#==============================================================================

setup_anykernel() {
    if [[ -d "${KERNEL_DIR}/AnyKernel3" ]]; then
        msg "AnyKernel3 already present, skipping clone"
    else
        msg "Cloning AnyKernel3..."
        git clone https://github.com/Reinazhard/AnyKernel3 \
            --single-branch \
            --depth 1 \
            AnyKernel3 || err "Failed to clone AnyKernel3"
        msg "AnyKernel3 cloned"
    fi
}

#==============================================================================
# Environment setup
#==============================================================================

setup_environment() {
    msg "Setting up build environment..."

    setup_toolchain
    setup_anykernel

    validate_toolchain

    # Architecture
    export ARCH="arm64"

    # Compiler info
    KBUILD_COMPILER_STRING=$(clang --version | head -n 1 \
        | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING

    # Parallel jobs
    PROCS=$(command -v nproc &> /dev/null && nproc --all || echo "8")
    [[ "${PROCS}" == "8" ]] && warn "nproc not available, defaulting to 8 jobs"
    export PROCS

    # Kernel version and git info
    KERVER=$(make kernelversion)
    COMMIT_HEAD=$(git log -n 1 --oneline)
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    export KERVER COMMIT_HEAD CI_BRANCH

    # Build number handling
    unset BUILD_NUMBER
    if [[ "${RELEASE}" == "1" ]]; then
        KERNEL_BUILD_NUM="1"
    else
        KERNEL_BUILD_NUM=$(increment_build_num)
    fi
    export KERNEL_BUILD_NUM

    # Create output directory
    mkdir -p "${OUT_DIR}"

    # Status message
    local build_label="Build #${KERNEL_BUILD_NUM}"
    [[ "${RELEASE}" == "1" ]] && build_label="RELEASE Build"
    msg "${build_label} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
    [[ "${CLEAN}" == "1" ]] && msg "Clean: Enabled (out dir will be removed)" || msg "Clean: Disabled (skipping clean)"
}

#==============================================================================
# Telegram notifications
#==============================================================================

tg_post_msg() {
    local message="$1"
    local chat_id="$2"
    [[ -z "${TELEGRAM_TOKEN}" ]] && return 0
    curl -s -X POST "${BOT_MSG_URL}" \
        -d chat_id="${chat_id}" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="${message}" > /dev/null 2>&1 || true
}

tg_post_build() {
    local file="$1"
    local chat_id="$2"
    local caption="$3"
    local max_attempts=5
    local wait_time=5

    [[ -z "${TELEGRAM_TOKEN}" ]] && return 0

    msg "Uploading to Telegram..."
    for attempt in $(seq 1 ${max_attempts}); do
        msg "Upload attempt ${attempt}/${max_attempts}..."
        if curl --progress-bar --max-time 300 \
            -F document=@"${file}" \
            -F chat_id="${chat_id}" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="${caption}" \
            "${BOT_BUILD_URL}" 2>/dev/null; then
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
    tg_post_msg "<b>❌ ${variant} ${label} failed: ${reason}</b>" "${CHATID}"
}

#==============================================================================
# LOCALVERSION management
#==============================================================================

compute_localversion() {
    local variant="$1"
    local lv=""
    [[ "${variant}" == "KernelSU" ]] && lv="-ybrt"
    [[ "${RELEASE}" != "1" ]] && lv="${lv}-b${KERNEL_BUILD_NUM}"
    echo "${lv}"
}

#==============================================================================
# Build functions
#==============================================================================

make_kernel() {
    make -j"${PROCS}" \
        O="${OUT_DIR}" \
        ARCH="${ARCH}" \
        LLVM="${TOOLCHAIN_DIR}/bin/" \
        LLVM_IAS=1 \
        LOCALVERSION="${LOCALVERSION}" \
        KBUILD_BUILD_VERSION="${KERNEL_BUILD_NUM}" \
        "$@"
}

clean_build_environment() {
    [[ "${CLEAN}" == "0" ]] && msg "Skipping clean (CLEAN=0)" && return 0
    msg "Cleaning build environment..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"
    msg "Build environment cleaned"
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
        scripts/config --file "${CONFIG_FILE}" \
            -e KSU \
            -e KSU_THRONE_TRACKER_ALWAYS_THREADED || {
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
        tg_notify_failure "${variant}" "Image.lz4 not found"
        err "Image.lz4 not found at ${IMAGE_PATH}"
    }

    for dtb in "${DTB_FILES[@]}"; do
        [[ -f "${dtb}" ]] || {
            tg_notify_failure "${variant}" "DTB files not found"
            err "DTB files not found"
        }
    done

    msg "${variant} build outputs verified"
}

#==============================================================================
# dtbo generation
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

    if [[ "${RELEASE}" != "1" ]]; then
        filename="${filename}-b${KERNEL_BUILD_NUM}"
    fi

    echo "${filename}.zip"
}

generate_zip() {
    local variant="$1"
    local zip_suffix="$2"
    local zip_final=$(construct_zip_filename "${zip_suffix}")

    msg "Packaging ${variant} flashable zip: ${zip_final}"

    cp "${IMAGE_PATH}" "${AK3_IMAGE}" || {
        tg_notify_failure "${variant}" "failed to copy kernel image"
        err "Failed to copy Image.lz4 to AnyKernel3"
    }

    cat "${DTB_FILES[@]}" > "${AK3_DTB}" || {
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

    local build_info="Build #${KERNEL_BUILD_NUM}"
    [[ "${RELEASE}" == "1" ]] && build_info="Release"

    local caption="✅ ${variant} completed in $(format_duration ${BUILD_DURATION}) | <code>${build_info}</code>"
    tg_post_build "${zip_final}" "${CHATID}" "${caption}"

    msg "Flashable zip: ${AK3_DIR}/${zip_final}"
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

    # Set LOCALVERSION for this variant
    LOCALVERSION=$(compute_localversion "${variant}")
    msg "LOCALVERSION: ${LOCALVERSION}"

    # Construct zip suffix
    local zip_suffix=""
    [[ "${is_ksu}" == "1" ]] && zip_suffix="ksu-"
    [[ "${RELEASE}" == "1" ]] && zip_suffix="${zip_suffix}RELEASE" || zip_suffix="${zip_suffix}TEST"

    # Send build start notification
    local build_title="${variant} Build #${KERNEL_BUILD_NUM}"
    [[ "${RELEASE}" == "1" ]] && build_title="${variant} Release Build"

    tg_post_msg "<b>${build_title}</b>%0A\
<b>Variant:</b> <code>${variant}</code>%0A\
<b>Kernel:</b> <code>${KERVER}</code>%0A\
<b>Device:</b> <code>${DEVICE}</code>%0A\
<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A\
<b>Compiler:</b> <code>${KBUILD_COMPILER_STRING}</code>%0A\
<b>Branch:</b> <code>${CI_BRANCH}</code>%0A\
<b>HEAD:</b> <code>${COMMIT_HEAD}</code>" "${CHATID}"

    # Execute build pipeline
    clean_build_environment
    configure_kernel "${variant}"
    compile_kernel "${variant}"
    verify_build_outputs "${variant}"
    generate_dtbo "${variant}"
    generate_zip "${variant}" "${zip_suffix}"

    # Clean up dtbo artifacts to prevent stale files in subsequent builds
    msg "Cleaning up dtbo artifacts..."
    find "${OUT_DIR}" -name 'gs*.dtbo' -delete
    rm -f "${KERNEL_DIR}/dtbo.img"

    msg "${variant} build complete"
}

#==============================================================================
# Main entry point
#==============================================================================

main() {
    msg "========================================"
    [[ "${RELEASE}" == "1" ]] && msg "  RELEASE BUILD MODE"
    msg "  Raviole Kernel Build System"
    if [[ "${KSU}" == "1" ]]; then
        msg "  KernelSU Variant"
    else
        msg "  Standard Variant"
    fi
    msg "========================================"

    setup_environment

    # Build based on KSU setting
    if [[ "${KSU}" == "1" ]]; then
        build_variant "KernelSU" "1"
    else
        build_variant "Standard" "0"
    fi

    msg "========================================"
    msg "  Build Completed Successfully"
    [[ "${RELEASE}" != "1" ]] && msg "  Build #${KERNEL_BUILD_NUM}"
    msg "========================================"
}

main "$@"
