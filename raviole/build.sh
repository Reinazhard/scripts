#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Kernel build script for Google Tensor GS101 (Raviole: Pixel 6/6 Pro/6a)
#
#

set -euo pipefail

#------------------------------------------------------------------------------
# Logging utilities
#------------------------------------------------------------------------------

msg() {
    echo -e "\e[1;32m[INFO]\e[0m $*"
}

warn() {
    echo -e "\e[1;33m[WARN]\e[0m $*"
}

err() {
    echo -e "\e[1;31m[ERROR]\e[0m $*"
    exit 1
}

#------------------------------------------------------------------------------
# Build configuration
#------------------------------------------------------------------------------

KERNEL_DIR="${PWD}"
OUT_DIR="${KERNEL_DIR}/out"
BUILD_NUMBER_FILE="${KERNEL_DIR}/.build_number"

# Device configuration
ZIPNAME="86hm"
DEVICE="gs101"
DEFCONFIG="raviole_defconfig"

# Build environment
KBUILD_BUILD_USER="harumajati"
KBUILD_BUILD_HOST="marcejz"
export KBUILD_BUILD_USER KBUILD_BUILD_HOST

# Telegram configuration
CHATID="-1001403511595"

# Output paths
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/Image.lz4"
DTB_A0="${OUT_DIR}/google-devices/gs101/dts/gs101-a0.dtb"
DTB_B0="${OUT_DIR}/google-devices/gs101/dts/gs101-b0.dtb"

# AnyKernel3 paths
AK3_DIR="${KERNEL_DIR}/AnyKernel3"
AK3_IMAGE="${AK3_DIR}/Image.lz4"
AK3_DTB="${AK3_DIR}/dtb"

#------------------------------------------------------------------------------
# Build number management (local incremental)
#------------------------------------------------------------------------------

get_build_number() {
    if [[ -f "${BUILD_NUMBER_FILE}" ]]; then
        cat "${BUILD_NUMBER_FILE}"
    else
        echo "0"
    fi
}

increment_build_number() {
    local current
    current=$(get_build_number)
    echo $((current + 1)) > "${BUILD_NUMBER_FILE}"
    echo $((current + 1))
}

#------------------------------------------------------------------------------
# Environment setup
#------------------------------------------------------------------------------

setup_environment() {
    export ARCH=arm64
    export token="${TELEGRAM_TOKEN:-}"

    # Get kernel version
    KERVER=$(make kernelversion)
    export KERVER

    # Git information
    COMMIT_HEAD=$(git log --oneline -1)
    CI_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    export COMMIT_HEAD CI_BRANCH

    # Compiler information
    if command -v clang &> /dev/null; then
        KBUILD_COMPILER_STRING=$(clang --version | head -n 1 | sed -e 's/(http[^)]*)//g' -e 's/  */ /g' -e 's/[[:space:]]*$//')
    else
        err "clang not found in PATH"
    fi
    export KBUILD_COMPILER_STRING

    # Telegram API endpoints
    BOT_MSG_URL="https://api.telegram.org/bot${token}/sendMessage"
    BOT_BUILD_URL="https://api.telegram.org/bot${token}/sendDocument"
    export BOT_MSG_URL BOT_BUILD_URL

    # Build parallelism
    PROCS=$(nproc --all)
    export PROCS

    # Increment and export build number
    BUILD_NUMBER=$(increment_build_number)
    export BUILD_NUMBER KBUILD_BUILD_VERSION="${BUILD_NUMBER}"

    msg "Build #${BUILD_NUMBER} | Kernel ${KERVER} | Branch: ${CI_BRANCH}"
    msg "Compiler: ${KBUILD_COMPILER_STRING}"
    msg "Parallel jobs: ${PROCS}"
}

#------------------------------------------------------------------------------
# Telegram notification functions
#------------------------------------------------------------------------------

tg_post_msg() {
    local message="$1"
    local chat_id="$2"

    if [[ -z "${token}" ]]; then
        warn "Telegram token not set, skipping notification"
        return 0
    fi

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

    if [[ -z "${token}" ]]; then
        warn "Telegram token not set, skipping file upload"
        return 0
    fi

    msg "Uploading to Telegram (may take a while on slow connections)..."

    while [[ ${attempt} -le ${max_attempts} ]]; do
        msg "Upload attempt ${attempt}/${max_attempts}..."

        if curl --progress-bar --max-time 300 \
            -F document=@"${file}" \
            -F chat_id="${chat_id}" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="${caption} | <code>Build #${BUILD_NUMBER}</code>" \
            "${BOT_BUILD_URL}"; then
            msg "Upload successful!"
            return 0
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "Upload failed, retrying in ${wait_time}s..."
            sleep ${wait_time}
            wait_time=$((wait_time * 2))  # Exponential backoff
        fi

        attempt=$((attempt + 1))
    done

    err "Failed to upload after ${max_attempts} attempts"
}

#------------------------------------------------------------------------------
# Kernel build function
#------------------------------------------------------------------------------

build_kernel() {
    msg "Starting kernel build..."

    # Send build start notification
    tg_post_msg "<b>🔨 Build #${BUILD_NUMBER} Started</b>%0A\
<b>Kernel:</b> <code>${KERVER}</code>%0A\
<b>Device:</b> <code>${DEVICE}</code>%0A\
<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A\
<b>Compiler:</b> <code>${KBUILD_COMPILER_STRING}</code>%0A\
<b>Branch:</b> <code>${CI_BRANCH}</code>%0A\
<b>HEAD:</b> <code>${COMMIT_HEAD}</code>" "${CHATID}"

    # Generate kernel configuration
    msg "Generating configuration: ${DEFCONFIG}"
    make -j"${PROCS}" O="${OUT_DIR}" LLVM=1 LLVM_IAS=1 "${DEFCONFIG}"

    # Build kernel image and device trees
    msg "Building kernel image and device trees..."
    BUILD_START=$(date +"%s")

    if make -j"${PROCS}" O="${OUT_DIR}" LLVM=1 LLVM_IAS=1; then
        BUILD_END=$(date +"%s")
        DIFF=$((BUILD_END - BUILD_START))
        msg "Compilation completed in $((DIFF / 60))m $((DIFF % 60))s"
    else
        BUILD_END=$(date +"%s")
        DIFF=$((BUILD_END - BUILD_START))
        tg_post_msg "<b>❌ Build #${BUILD_NUMBER} failed after $((DIFF / 60))m $((DIFF % 60))s</b>" "${CHATID}"
        err "Kernel compilation failed"
    fi

    # Verify build outputs
    if [[ ! -f "${IMAGE_PATH}" ]]; then
        tg_post_msg "<b>❌ Build #${BUILD_NUMBER} failed: Image.lz4 not found</b>" "${CHATID}"
        err "Image.lz4 not found at ${IMAGE_PATH}"
    fi

    if [[ ! -f "${DTB_A0}" ]] || [[ ! -f "${DTB_B0}" ]]; then
        tg_post_msg "<b>❌ Build #${BUILD_NUMBER} failed: DTB files not found</b>" "${CHATID}"
        err "DTB files not found"
    fi

    msg "Kernel build successful"
    generate_zip
}

#------------------------------------------------------------------------------
# Flashable zip generation
#------------------------------------------------------------------------------

generate_zip() {
    msg "Generating flashable zip..."

    # Copy kernel image to AnyKernel3
    msg "Copying Image.lz4 to AnyKernel3..."
    cp -v "${IMAGE_PATH}" "${AK3_IMAGE}"

    # Concatenate DTB files
    msg "Concatenating DTB files..."
    cat "${DTB_A0}" "${DTB_B0}" > "${AK3_DTB}"

    # Create flashable zip
    cd "${AK3_DIR}" || err "Failed to enter AnyKernel3 directory"

    # Clean previous builds
    rm -f ./*.zip 2>/dev/null || true

    msg "Creating zip archive..."
    zip -r9 "unsigned.zip" . \
        -x '.git/*' \
        -x '.github/*' \
        -x 'README.md' \
        -x '*.zip' \
        -x 'zipsigner-3.0.jar'

    # Final zip name
    ZIP_FINAL="${ZIPNAME}-${DEVICE}-b${BUILD_NUMBER}.zip"

    # Download zipsigner if not present
    if [[ ! -f "zipsigner-3.0.jar" ]]; then
        msg "Downloading zipsigner..."
        curl -sLo zipsigner-3.0.jar \
            "https://raw.githubusercontent.com/raphielscape/scripts/master/zipsigner-3.0.jar"
    fi

    # Sign the zip
    msg "Signing zip as ${ZIP_FINAL}..."
    java -jar zipsigner-3.0.jar unsigned.zip "${ZIP_FINAL}"
    rm -f unsigned.zip

    # Upload to Telegram
    tg_post_build "${ZIP_FINAL}" "${CHATID}" \
        "✅ Build completed in $((DIFF / 60))m $((DIFF % 60))s"

    msg "Build complete: ${AK3_DIR}/${ZIP_FINAL}"
    cd "${KERNEL_DIR}"
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

main() {
    msg "========================================"
    msg "  Raviole (Pixel 6/6 Pro/6a) Kernel Build"
    msg "========================================"

    setup_environment
    build_kernel

    msg "========================================"
    msg "  Build #${BUILD_NUMBER} Finished Successfully"
    msg "========================================"
}

main "$@"
