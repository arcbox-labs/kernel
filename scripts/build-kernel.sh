#!/bin/bash
# Build Linux kernel for ArcBox
#
# Usage:
#   ./build-kernel.sh                    # Build for ARM64
#   ARCH=x86_64 ./build-kernel.sh        # Build for x86_64
#   KERNEL_VERSION=6.12.0 ./build-kernel.sh  # Use specific version

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
KERNEL_VERSION="${KERNEL_VERSION:-6.12.11}"
TARGET_ARCH="${ARCH:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
CONFIG_DIR="$PROJECT_DIR/configs"

# Determine config file
if [ "$TARGET_ARCH" = "arm64" ]; then
    CONFIG_FILE="$CONFIG_DIR/arcbox-arm64.config"
    CROSS_COMPILE="aarch64-linux-gnu-"
    KERNEL_IMAGE="Image"
elif [ "$TARGET_ARCH" = "x86_64" ]; then
    CONFIG_FILE="$CONFIG_DIR/arcbox-x86_64.config"
    CROSS_COMPILE=""
    KERNEL_IMAGE="bzImage"
else
    echo "Error: Unsupported architecture: $TARGET_ARCH"
    exit 1
fi

echo "========================================"
echo "  ArcBox Kernel Build"
echo "========================================"
echo ""
echo "  Kernel Version: $KERNEL_VERSION"
echo "  Target Arch:    $TARGET_ARCH"
echo "  Output Dir:     $OUTPUT_DIR"
echo ""

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# ============================================================================
# Common build logic (called from both Docker and native paths)
# ============================================================================
# Expects:
#   - CWD = extracted kernel source root (linux-$KERNEL_VERSION)
#   - $ARCBOX_SRC = path to arcbox-kernel repo
#   - $TARGET_ARCH, $KERNEL_IMAGE, $CROSS_COMPILE set
#   - $OUTPUT_PATH = where to copy the final kernel binary
do_build() {
    local ARCBOX_SRC="$1"
    local OUTPUT_PATH="$2"

    # Inject custom drivers and patches.
    sh "$ARCBOX_SRC/scripts/inject-drivers.sh" "$ARCBOX_SRC"

    # Copy config and update for this kernel version.
    cp "$ARCBOX_SRC/configs/arcbox-$TARGET_ARCH.config" .config
    make ARCH=$TARGET_ARCH ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} olddefconfig

    # Build.
    echo "Building kernel..."
    make ARCH=$TARGET_ARCH ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} -j"$(nproc)" $KERNEL_IMAGE

    # Copy output.
    cp "arch/$TARGET_ARCH/boot/$KERNEL_IMAGE" "$OUTPUT_PATH"
    echo ""
    echo "Build complete!"
    ls -lh "$OUTPUT_PATH"
}

# ============================================================================
# Check if running in Docker or need to use Docker
# ============================================================================
if [ -f /.dockerenv ] || [ "${USE_DOCKER:-}" = "0" ]; then
    echo "Building natively..."
    BUILD_IN_DOCKER=0
else
    echo "Building in Docker..."
    BUILD_IN_DOCKER=1
fi

if [ "$BUILD_IN_DOCKER" = "1" ]; then
    docker run --rm \
        -v "$PROJECT_DIR:/workspace" \
        -v "$OUTPUT_DIR:/output" \
        -w /build \
        --platform "linux/$TARGET_ARCH" \
        "${DOCKER_IMAGE:-alpine:latest}" \
        sh -c "
set -e
apk add --no-cache build-base bc bison flex openssl-dev elfutils-dev perl curl xz cpio linux-headers ncurses-dev
echo 'Downloading Linux kernel $KERNEL_VERSION...'
curl -L -o linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz
tar -xJf linux.tar.xz && rm linux.tar.xz
cd linux-$KERNEL_VERSION
sh /workspace/scripts/inject-drivers.sh /workspace
cp /workspace/configs/arcbox-$TARGET_ARCH.config .config
make ARCH=$TARGET_ARCH olddefconfig
echo 'Building kernel...'
make ARCH=$TARGET_ARCH -j\$(nproc) $KERNEL_IMAGE
cp arch/$TARGET_ARCH/boot/$KERNEL_IMAGE /output/kernel-$TARGET_ARCH
echo 'Build complete!'
ls -lh /output/kernel-$TARGET_ARCH
"
else
    BUILD_DIR="/tmp/arcbox-kernel-build-$$"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    echo "Downloading Linux kernel $KERNEL_VERSION..."
    curl -L -o "linux.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
    echo "Extracting..."
    tar -xJf "linux.tar.xz"
    rm "linux.tar.xz"
    cd "linux-$KERNEL_VERSION"

    do_build "$PROJECT_DIR" "$OUTPUT_DIR/kernel-$TARGET_ARCH"

    rm -rf "$BUILD_DIR"
fi

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""
echo "  Output: $OUTPUT_DIR/kernel-$TARGET_ARCH"
ls -lh "$OUTPUT_DIR/kernel-$TARGET_ARCH"
