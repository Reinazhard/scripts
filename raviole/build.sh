#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
# Supports Standard and KernelSU build variants
#

set -euo pipefail

#==============================================================================
# Logging
#==============================================================================

msg()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

format_duration() {
    local seconds="$1"
    echo "$((seconds / 60))m $((seconds % 60))s"
}

#==============================================================================
# Configuration
#==============================================================================

# Paths
readonly KERNEL_DIR="${PWD}"
readonly IS_RELEASE="${RELEASE:-0}"

if [[ "${IS_RELEASE}" == "1" ]]; then
    readonly OUT_DIR="${KERNEL_DIR}/out-release"
    readonly CHATID="-1001493260868"
else
    readonly OUT_DIR="${KERNEL_DIR}/out"
    readonly CHATID="-1001403511595"
fi

readonly BUILD_NUMBER_FILE="${KERNEL_DIR}/.build_number"
readonly CONFIG_FILE="${OUT_DIR}/.config"

# Device
readonly ZIPNAME="86hm"
readonly DEVICE="gs101"
readonly DEFCONFIG="raviole_defconfig"

# Build artifacts
readonly IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/Image.lz4"
readonly DTB_A0="${OUT_DIR}/google-devices/gs101/dts/gs101-a0.dtb"
readonly DTB_B0="${OUT_DIR}/google-devices/gs101/dts/gs101-b0.dtb"

# AnyKernel3
readonly AK3_DIR="${KERNEL_DIR}/AnyKernel3"
readonly AK3_IMAGE="${AK3_DIR}/Image.lz4"
readonly AK3_DTB="${AK3_DIR}/dtb"

# Build identity
export KBUILD_BUILD_USER="harumajati"
export KBUILD_BUILD_HOST="marcejz"

# Common make flags (expanded after PROCS is set in setup_environment)
MAKE_OPTS=()

# Build timing (shared across build stages)
BUILD_DURATION=0

#==============================================================================
# Build number
#==============================================================================

get_build_number() {
    if [[ -f "${BUILD_NUMBER_FILE}" ]]; then
        cat "${BUILD_NUMBER_FILE}"
    else
        echo "0"
    fi
}

increment_build_number() {
    # Release builds always use build number 1
    if [[ "${IS_RELEASE}" == "1" ]]; then
        echo "1"
        return
    fi

    local current next
    current=$(get_build_number)
    next=$((current + 1))
    echo "${next}" > "${BUILD_NUMBER_FILE}"
    echo "${next}"
}

#==============================================================================
# Environment & toolchain setup
#==============================================================================

setup_environment() {
    export ARCH=arm64
    export token="${TELEGRAM_TOKEN:-}"

    # Deterministic build timestamp for release builds
    if [[ "${IS_RELEASE}" == "1" ]]; then
        export KBUILD_BUILD_TIMESTAMP="Mon Oct 13 22:28:16 UTC 2025"
    fi

    # Toolchain
    command -v clang &> /dev/null || err "clang not found in PATH"

    KBUILD_COMPILER_STRING=$(clang --version | head -n 1 \
        | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING

    # Parallelism
    PROCS=$(nproc --all)
    export PROCS

    # Common make flags, now that PROCS is available
    MAKE_OPTS=(-j"${PROCS}" O="${OUT_DIR}" LLVM=1 LLVM_IAS=1)

    # Kernel version
    KERVER=$(make kernelversion)
    export KERVER

    # Git metadata
    COMMIT_HEAD=$(git log -n 1 --oneline)
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    export COMMIT_HEAD CI_BRANCH

    # Telegram endpoints
    BOT_MSG_URL="https://api.telegram.org/bot${token}/sendMessage"
    BOT_BUILD_URL="https://api.telegram.org/bot${token}/sendDocument"
    export BOT_MSG_URL BOT_BUILD_URL

    # Build number
    BUILD_NUMBER=$(increment_build_number)
    export BUILD_NUMBER

    # Summary
    if [[ "${IS_RELEASE}" == "1" ]]; then
        msg "RELEASE Build #${BUILD_NUMBER} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    else
        msg "Build #${BUILD_NUMBER} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    fi
    msg "Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
}

#==============================================================================
# Telegram notifications
#==============================================================================

tg_post_msg() {
    local message="$1"
    local chat_id="$2"

    [[ -z "${token}" ]] && return 0

    curl -s -X POST "${BOT_MSG_URL}" \
        -d chat_id="${chat_id}" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="${message}" > /dev/null
}

tg_post_build() {
    local file="$1"
    local chat_id="$2"
    local caption="$3"
    local max_attempts=5
    local attempt=1
    local wait_time=5

    [[ -z "${token}" ]] && return 0

    msg "Uploading to Telegram..."

    while [[ ${attempt} -le ${max_attempts} ]]; do
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

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "Upload failed, retrying in ${wait_time}s..."
            sleep ${wait_time}
            wait_time=$((wait_time * 2))
        fi

        attempt=$((attempt + 1))
    done

    err "Failed to upload after ${max_attempts} attempts"
}

tg_notify_failure() {
    local variant="$1"
    local reason="$2"

    tg_post_msg "<b>❌ ${variant} Build #${BUILD_NUMBER} failed: ${reason}</b>" "${CHATID}"
}

#==============================================================================
# LOCALVERSION
#
# Release builds:  base only, plus "-ksu" for KernelSU variant.
# Non-release:     base plus "-b<N>", plus "-ksu" for KernelSU variant.
# BUILD_NUMBER never leaks into LOCALVERSION during release builds.
#==============================================================================

get_config_localversion() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo ""
        return
    fi

    grep -E '^CONFIG_LOCALVERSION=' "${CONFIG_FILE}" | cut -d'"' -f2
}

set_config_localversion() {
    local value="$1"

    msg "Setting LOCALVERSION: ${value}"
    scripts/config --file "${CONFIG_FILE}" --set-str LOCALVERSION "${value}"
}

compute_localversion() {
    local variant="$1"
    local base
    base=$(get_config_localversion)

    local suffix=""

    # KernelSU tag always comes first after the base
    if [[ "${variant}" == "KernelSU" ]]; then
        suffix="-ksu"
    fi

    # Build number tag only for non-release builds
    if [[ "${IS_RELEASE}" != "1" ]]; then
        suffix="${suffix}-b${BUILD_NUMBER}"
    fi

    echo "${base}${suffix}"
}

#==============================================================================
# Kernel build helpers
#==============================================================================

# Wrapper around make with the common flags
make_kernel() {
    make "${MAKE_OPTS[@]}" "$@"
}

configure_kernel() {
    local variant="$1"

    msg "Configuring ${variant} kernel..."

    # Generate base defconfig
    make_kernel "${DEFCONFIG}" > /dev/null

    # KernelSU-specific config options
    if [[ "${variant}" == "KernelSU" ]]; then
        msg "Enabling KernelSU features..."
        scripts/config --file "${CONFIG_FILE}" \
            -e KSU \
            -e KSU_THRONE_TRACKER_ALWAYS_THREADED
    fi

    # Apply computed LOCALVERSION
    set_config_localversion "$(compute_localversion "${variant}")"

    # Finalize config
    make_kernel olddefconfig > /dev/null
}

compile_kernel() {
    local variant="$1"
    local start end

    msg "Compiling ${variant} kernel..."
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

    if [[ ! -f "${IMAGE_PATH}" ]]; then
        tg_notify_failure "${variant}" "Image.lz4 not found"
        err "Image.lz4 not found at ${IMAGE_PATH}"
    fi

    if [[ ! -f "${DTB_A0}" ]] || [[ ! -f "${DTB_B0}" ]]; then
        tg_notify_failure "${variant}" "DTB files not found"
        err "DTB files not found"
    fi

    msg "${variant} build outputs verified"
}

#==============================================================================
# Packaging
#==============================================================================

generate_zip() {
    local variant="$1"
    local zip_suffix="$2"
    local zip_final="${ZIPNAME}-${DEVICE}-${zip_suffix}-b${BUILD_NUMBER}.zip"

    msg "Packaging ${variant} flashable zip..."

    cp "${IMAGE_PATH}" "${AK3_IMAGE}"
    cat "${DTB_A0}" "${DTB_B0}" > "${AK3_DTB}"

    cd "${AK3_DIR}" || err "Failed to enter AnyKernel3 directory"

    rm -f unsigned.zip

    zip -r9 -q "unsigned.zip" . \
        -x '*.git*/*' \
        -x '*.github*/*' \
        -x '*README.md*' \
        -x '*.zip*' \
        -x '*zipsigner-3.0.jar*'

    # Fetch zipsigner on first use
    if [[ ! -f "zipsigner-3.0.jar" ]]; then
        msg "Downloading zipsigner..."
        curl -sLo zipsigner-3.0.jar \
            "https://raw.githubusercontent.com/raphielscape/scripts/master/zipsigner-3.0.jar"
    fi

    msg "Signing ${zip_final}..."
    java -jar zipsigner-3.0.jar unsigned.zip "${zip_final}"
    rm -f unsigned.zip

    local caption="✅ ${variant} completed in $(format_duration ${BUILD_DURATION}) | <code>Build #${BUILD_NUMBER}</code>"
    tg_post_build "${zip_final}" "${CHATID}" "${caption}"

    msg "Flashable zip: ${AK3_DIR}/${zip_final}"
    cd "${KERNEL_DIR}"
}

#==============================================================================
# Variant orchestration
#==============================================================================

build_variant() {
    local variant="$1"
    local zip_suffix="$2"

    msg "========================================"
    msg "  ${variant} Variant Build"
    msg "========================================"

    # Build start notification
    local build_title="${variant} Build #${BUILD_NUMBER}"
    if [[ "${IS_RELEASE}" == "1" ]]; then
        build_title="${variant} Release Build"
    fi

    tg_post_msg "<b>${build_title}</b>%0A\
<b>Variant:</b> <code>${variant}</code>%0A\
<b>Kernel:</b> <code>${KERVER}</code>%0A\
<b>Device:</b> <code>${DEVICE}</code>%0A\
<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A\
<b>Compiler:</b> <code>${KBUILD_COMPILER_STRING}</code>%0A\
<b>Branch:</b> <code>${CI_BRANCH}</code>%0A\
<b>HEAD:</b> <code>${COMMIT_HEAD}</code>" "${CHATID}"

    configure_kernel "${variant}"
    compile_kernel "${variant}"
    verify_build_outputs "${variant}"
    generate_zip "${variant}" "${zip_suffix}"

    msg "${variant} build complete"
}

zip_suffix_for() {
    local tag="$1"

    if [[ "${IS_RELEASE}" == "1" ]]; then
        echo "${tag}RELEASE"
    else
        echo "${tag}TEST"
    fi
}

build_standard() {
    build_variant "Standard" "$(zip_suffix_for "")"
}

build_ksu() {
    build_variant "KernelSU" "$(zip_suffix_for "ksu-")"
}

#==============================================================================
# Main
#==============================================================================

main() {
    msg "========================================"
    if [[ "${IS_RELEASE}" == "1" ]]; then
        msg "  RELEASE BUILD MODE"
    fi
    msg "  Raviole Kernel Build System"
    msg "  Standard + KernelSU Variants"
    msg "========================================"

    setup_environment

    build_standard
    echo ""
    build_ksu

    msg "========================================"
    msg "  All Builds Completed Successfully"
    msg "  Build #${BUILD_NUMBER}"
    msg "========================================"
}

main "$@"
