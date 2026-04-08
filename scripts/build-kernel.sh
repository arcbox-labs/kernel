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

# Check if running in Docker or need to use Docker
if [ -f /.dockerenv ] || [ "${USE_DOCKER:-}" = "0" ]; then
    echo "Building natively..."
    BUILD_IN_DOCKER=0
else
    echo "Building in Docker..."
    BUILD_IN_DOCKER=1
fi

if [ "$BUILD_IN_DOCKER" = "1" ]; then
    # Build using Docker
    docker run --rm \
        -v "$PROJECT_DIR:/workspace" \
        -v "$OUTPUT_DIR:/output" \
        -w /build \
        --platform linux/$TARGET_ARCH \
        "${DOCKER_IMAGE:-alpine:latest}" \
        sh -c "
set -e

# Install build dependencies
apk add --no-cache \
    build-base \
    bc \
    bison \
    flex \
    openssl-dev \
    elfutils-dev \
    perl \
    curl \
    xz \
    cpio \
    linux-headers \
    ncurses-dev

# Download kernel source
echo 'Downloading Linux kernel $KERNEL_VERSION...'
curl -L -o linux-$KERNEL_VERSION.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz
echo 'Extracting...'
tar -xJf linux-$KERNEL_VERSION.tar.xz
rm linux-$KERNEL_VERSION.tar.xz
cd linux-$KERNEL_VERSION

# Apply ArcBox patches (custom drivers, etc.)
for patchfile in /workspace/patches/*.patch; do
    [ -f "\$patchfile" ] && echo "Applying patch: \$patchfile" && patch -p1 < "\$patchfile" || true
done

# Copy config
cp /workspace/configs/arcbox-$TARGET_ARCH.config .config

# Update config to match kernel version
make ARCH=$TARGET_ARCH olddefconfig

# Build kernel
echo 'Building kernel...'
make ARCH=$TARGET_ARCH -j\$(nproc) $KERNEL_IMAGE

# Copy output
cp arch/$TARGET_ARCH/boot/$KERNEL_IMAGE /output/kernel-$TARGET_ARCH

echo ''
echo 'Build complete!'
ls -lh /output/kernel-$TARGET_ARCH
"
else
    # Native build (for CI or when already in container)
    BUILD_DIR="/tmp/arcbox-kernel-build-$$"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Download kernel
    echo "Downloading Linux kernel $KERNEL_VERSION..."
    curl -L -o "linux-$KERNEL_VERSION.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
    echo "Extracting..."
    tar -xJf "linux-$KERNEL_VERSION.tar.xz"
    rm "linux-$KERNEL_VERSION.tar.xz"
    cd "linux-$KERNEL_VERSION"

    # Apply ArcBox patches
    for patchfile in "$PROJECT_DIR"/patches/*.patch; do
        [ -f "$patchfile" ] && echo "Applying patch: $patchfile" && patch -p1 < "$patchfile" || true
    done

    # Install ArcBox custom drivers into kernel tree
    for src in "$PROJECT_DIR"/drivers/*.c; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        cp "$src" "drivers/block/$name"
        obj_name="${name%.c}.o"
        config_name="CONFIG_$(echo "${name%.c}" | tr 'a-z' 'A-Z')"
        if ! grep -q "$obj_name" drivers/block/Makefile; then
            echo "obj-\$($config_name)	+= $obj_name" >> drivers/block/Makefile
            echo "Injected $obj_name into drivers/block/Makefile"
        fi
        if ! grep -q "$config_name" drivers/block/Kconfig; then
            cat >> drivers/block/Kconfig <<KCONFIG

config ${config_name#CONFIG_}
	bool "ArcBox ${name%.c} driver"
	depends on ARM64 && ARM_SMCCC
	default n
	help
	  ArcBox custom driver: $name
KCONFIG
            echo "Injected $config_name into drivers/block/Kconfig"
        fi
    done

    # Copy config
    cp "$CONFIG_FILE" .config

    # Update config
    make ARCH=$TARGET_ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

    # Build
    echo "Building kernel..."
    make ARCH=$TARGET_ARCH CROSS_COMPILE=$CROSS_COMPILE -j$(nproc) $KERNEL_IMAGE

    # Copy output
    cp "arch/$TARGET_ARCH/boot/$KERNEL_IMAGE" "$OUTPUT_DIR/kernel-$TARGET_ARCH"

    # Cleanup
    rm -rf "$BUILD_DIR"
fi

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""
echo "  Output: $OUTPUT_DIR/kernel-$TARGET_ARCH"
ls -lh "$OUTPUT_DIR/kernel-$TARGET_ARCH"
