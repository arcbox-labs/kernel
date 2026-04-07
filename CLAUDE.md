# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`arcbox-kernel` provides optimized Linux kernel and initramfs builds for ArcBox VMs, targeting Apple Virtualization.framework (primary) and KVM (secondary).

## Build Commands

```bash
# Build kernel (ARM64, requires Docker)
./scripts/build-kernel.sh

# Build kernel for x86_64
ARCH=x86_64 ./scripts/build-kernel.sh

# Build kernel with specific version
KERNEL_VERSION=6.12.0 ./scripts/build-kernel.sh

# Build initramfs (requires arcbox-agent binary)
./scripts/build-initramfs.sh

# Build initramfs with kernel modules (for standard kernels)
KERNEL_MODULES_DIR=/path/to/lib/modules ./scripts/build-initramfs.sh

# Package release
./scripts/package-release.sh v0.1.0
```

## Prerequisites

- Docker (for kernel cross-compilation)
- `arcbox-agent` binary at `../arcbox/target/aarch64-unknown-linux-musl/release/arcbox-agent`

Build arcbox-agent:
```bash
cd ../arcbox
cargo build -p arcbox-agent --target aarch64-unknown-linux-musl --release
```

## Architecture

```
arcbox-kernel/
├── configs/
│   ├── arcbox-arm64.config     # ARM64 kernel config (Apple Silicon)
│   └── arcbox-x86_64.config    # x86_64 kernel config
├── scripts/
│   ├── build-kernel.sh         # Kernel build (Docker-based)
│   ├── build-initramfs.sh      # Initramfs build (Alpine + agent)
│   └── package-release.sh      # Release tarball packaging
├── output/                     # Build artifacts (gitignored)
│   ├── kernel-arm64
│   └── initramfs-arm64.cpio.gz
└── release/                    # Packaged releases (gitignored)
```

## Kernel Configuration

Key configs for macOS Virtualization.framework compatibility:

```
# Required for VirtioFS on macOS
CONFIG_VIRTIO_IOMMU=y

# Serial console: PL011 (VZ backend) + 8250/16550 (HV backend)
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y

# GPIO support (Virtualization.framework)
CONFIG_GPIOLIB=y
CONFIG_GPIO_PL061=y
CONFIG_GPIO_VIRTIO=y

# VirtIO devices
CONFIG_VIRTIO_FS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_FUSE_FS=y

# All drivers built-in (no modules)
CONFIG_MODULES=n
```

## Initramfs Contents

- Alpine Linux minirootfs (BusyBox)
- `arcbox-agent` - host-guest communication daemon
- Init script that mounts VirtioFS and starts agent on vsock port 1024

## Integration with ArcBox

Boot assets are downloaded to `~/.arcbox/boot/<version>/`:
```bash
# Check boot asset status
arcbox boot status

# Use custom kernel/initramfs
arcbox daemon --kernel /path/to/kernel --initramfs /path/to/initramfs.cpio.gz
```

## Performance Targets

| Metric | Target |
|--------|--------|
| Kernel size | < 10MB |
| Initramfs size | < 10MB |
| Boot time | < 1s |
