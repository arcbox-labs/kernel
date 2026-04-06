# arcbox-kernel

Optimized Linux kernel and initramfs for ArcBox VM runtime.

## Overview

This repository contains:
- Minimal Linux kernel configuration optimized for Virtualization.framework
- Build scripts for kernel and initramfs
- GitHub Actions CI for automated releases

## Features

| Feature | Description |
|---------|-------------|
| **Fast Boot** | < 1s cold boot with minimal config |
| **Small Size** | Kernel ~7MB, initramfs ~5MB |
| **VirtIO Support** | Full VirtIO device support |
| **VirtioFS** | Host-guest file sharing |
| **vsock** | Fast host-guest communication |

## Supported Architectures

- `arm64` (Apple Silicon) - Primary target
- `x86_64` (Intel) - Secondary target

## Quick Start

### Download Pre-built Assets

```bash
# Download from GitHub Releases
curl -LO https://github.com/arcboxd/arcbox-kernel/releases/download/v0.1.0/arcbox-kernel-arm64-v0.1.0.tar.gz
tar -xzf arcbox-kernel-arm64-v0.1.0.tar.gz
```

### Build Locally

```bash
# Build kernel (requires Docker)
./scripts/build-kernel.sh

# Build initramfs (requires arcbox-agent binary)
./scripts/build-initramfs.sh
```

## Directory Structure

```
arcbox-kernel/
├── configs/
│   ├── arcbox-arm64.config     # ARM64 kernel config
│   └── arcbox-x86_64.config    # x86_64 kernel config
├── scripts/
│   ├── build-kernel.sh         # Kernel build script
│   ├── build-initramfs.sh      # Initramfs build script
│   └── package-release.sh      # Release packaging script
├── rootfs/
│   └── init                    # Init script template
└── .github/workflows/
    └── build.yml               # CI workflow
```

## Kernel Configuration

The kernel is configured for minimal size and fast boot:

### Enabled Features

```
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_FS=y
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_FUSE_FS=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_SNAPSHOT=y
CONFIG_DM_THIN_PROVISIONING=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_NET=y
CONFIG_INET=y
CONFIG_UNIX=y
```

### Disabled Features

```
CONFIG_MODULES=n          # All drivers built-in
CONFIG_DEBUG_INFO=n       # Smaller binary
CONFIG_PRINTK=y           # Minimal logging
CONFIG_USB=n              # Not needed in VM
CONFIG_SOUND=n            # Not needed in VM
CONFIG_WIRELESS=n         # Not needed in VM
```

## Initramfs Contents

The initramfs contains:

- **BusyBox** - Minimal userspace utilities
- **arcbox-agent** - Host-guest communication agent
- **Kernel modules** - vsock, fuse, virtiofs (if not built-in)
- **Init script** - Mounts filesystems and starts agent

## Building

### Prerequisites

- Docker (for cross-compilation)
- `aarch64-unknown-linux-musl` Rust target (for arcbox-agent)

### Build Kernel

```bash
# Build for ARM64 (default)
./scripts/build-kernel.sh

# Build for x86_64
ARCH=x86_64 ./scripts/build-kernel.sh

# Use specific kernel version
KERNEL_VERSION=6.12.0 ./scripts/build-kernel.sh
```

### Build Initramfs

```bash
# Requires arcbox-agent binary at:
# ../arcbox/target/aarch64-unknown-linux-musl/release/arcbox-agent

# Build without kernel modules (for kernels with CONFIG_MODULES=n)
./scripts/build-initramfs.sh

# Build with kernel modules (for standard kernels that need modules)
KERNEL_MODULES_DIR=/path/to/lib/modules ./scripts/build-initramfs.sh
```

**Two modes:**

1. **Built-in mode** (recommended): Use a kernel with `CONFIG_MODULES=n` where
   vsock, virtiofs, and fuse are built-in. This produces a smaller initramfs (~5MB).

2. **Module mode**: Use a standard kernel that requires loading modules.
   Provide `KERNEL_MODULES_DIR` pointing to the modules directory
   (e.g., `/lib/modules/6.12.51-0-lts`). Produces larger initramfs (~25MB+).

### Package Release

```bash
./scripts/package-release.sh v0.1.0
```

## Integration with ArcBox

ArcBox automatically downloads and uses these assets:

```bash
# Assets are cached at ~/.arcbox/boot/
arcbox boot status

# Force re-download
arcbox boot prefetch --force
```

Or use custom paths:

```bash
arcbox daemon --kernel /path/to/kernel --initramfs /path/to/initramfs.cpio.gz
```

## Performance Targets

| Metric | Target | Actual |
|--------|--------|--------|
| Kernel size | < 10MB | ~7MB |
| Initramfs size | < 10MB | ~5MB |
| Boot time | < 1s | ~0.5s |
| Memory footprint | < 50MB | ~30MB |

## Release Process

1. Update version in `scripts/package-release.sh`
2. Create git tag: `git tag v0.1.0`
3. Push tag: `git push origin v0.1.0`
4. GitHub Actions automatically builds and publishes

## License

MIT OR Apache-2.0 (same as ArcBox)

## Related Projects

- [arcbox](https://github.com/arcboxd/arcbox) - Main runtime
- [puipui-linux](https://github.com/nicovank/puipui-linux) - Inspiration for minimal kernel

---

*Built for ArcBox - High-performance container and VM runtime*
