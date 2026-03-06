#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
# Supports Standard and KernelSU build variants

set -euo pipefail

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
readonly ZIPNAME="86hm"
readonly DEVICE="gs101"
readonly DEFCONFIG="raviole_defconfig"

# Build identity
export KBUILD_BUILD_USER="harumajati"
export KBUILD_BUILD_HOST="marcejz"

# AnyKernel3 paths
readonly AK3_DIR="${KERNEL_DIR}/AnyKernel3"
readonly AK3_IMAGE="${AK3_DIR}/Image.lz4"
readonly AK3_DTB="${AK3_DIR}/dtb"

# Release mode: 0 = test, 1 = release
RELEASE="${RELEASE:-0}"
[[ "${RELEASE}" != "0" && "${RELEASE}" != "1" ]] && err "RELEASE must be 0 or 1, got: ${RELEASE}"

# Clean control: 0 = skip mrproper, 1 = run mrproper (default: run for all builds)
NO_CLEAN="${NO_CLEAN:-0}"
[[ "${NO_CLEAN}" != "0" && "${NO_CLEAN}" != "1" ]] && err "NO_CLEAN must be 0 or 1, got: ${NO_CLEAN}"

# Set output directory and Telegram chat based on release mode
if [[ "${RELEASE}" == "1" ]]; then
    OUT_DIR="${KERNEL_DIR}/out-release"
    CHATID="-1001493260868"
    export KBUILD_BUILD_TIMESTAMP="Mon Oct 13 22:28:16 UTC 2025"
else
    OUT_DIR="${KERNEL_DIR}/out"
    CHATID="-1001403511595"
fi

readonly OUT_DIR CHATID

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
# Environment setup
#==============================================================================

setup_environment() {
    msg "Setting up build environment..."

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

    # Build artifact paths
    readonly CONFIG_FILE="${OUT_DIR}/.config"
    readonly IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/Image.lz4"
    readonly DTB_A0="${OUT_DIR}/google-devices/gs101/dts/gs101-a0.dtb"
    readonly DTB_B0="${OUT_DIR}/google-devices/gs101/dts/gs101-b0.dtb"

    # Status message
    local build_label="Build #${KERNEL_BUILD_NUM}"
    [[ "${RELEASE}" == "1" ]] && build_label="RELEASE Build"
    msg "${build_label} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
    [[ "${NO_CLEAN}" == "1" ]] && msg "Clean: Disabled (NO_CLEAN=1)" || msg "Clean: Enabled (mrproper will run)"
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
        LLVM=1 \
        LLVM_IAS=1 \
        LOCALVERSION="${LOCALVERSION}" \
        KBUILD_BUILD_VERSION="${KERNEL_BUILD_NUM}" \
        "$@"
}

clean_build_environment() {
    [[ "${NO_CLEAN}" == "1" ]] && msg "Skipping mrproper (NO_CLEAN=1)" && return 0
    msg "Performing mrproper (full clean)..."
    make O="${OUT_DIR}" mrproper 2>&1 | grep -v "is up to date" || true
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

    [[ -f "${DTB_A0}" && -f "${DTB_B0}" ]] || {
        tg_notify_failure "${variant}" "DTB files not found"
        err "DTB files not found"
    }

    msg "${variant} build outputs verified"
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

    cat "${DTB_A0}" "${DTB_B0}" > "${AK3_DTB}" || {
        tg_notify_failure "${variant}" "failed to concatenate DTBs"
        err "Failed to create DTB file"
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
    generate_zip "${variant}" "${zip_suffix}"

    msg "${variant} build complete"
}

#==============================================================================
# Main entry point
#==============================================================================

main() {
    msg "========================================"
    [[ "${RELEASE}" == "1" ]] && msg "  RELEASE BUILD MODE"
    msg "  Raviole Kernel Build System"
    msg "  Standard + KernelSU Variants"
    msg "========================================"

    setup_environment

    # Build Standard variant
    build_variant "Standard" "0"
    echo ""

    # Build KernelSU variant
    build_variant "KernelSU" "1"

    msg "========================================"
    msg "  All Builds Completed Successfully"
    [[ "${RELEASE}" != "1" ]] && msg "  Build #${KERNEL_BUILD_NUM}"
    msg "========================================"
}

main "$@"
