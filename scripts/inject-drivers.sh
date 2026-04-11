#!/bin/sh
# Inject ArcBox custom drivers into the Linux kernel source tree.
# Run from the root of the extracted kernel source directory.
# Usage: /path/to/inject-drivers.sh /path/to/arcbox-kernel
set -e

ARCBOX_DIR="${1:-.}"

# Apply .patch files (unified diffs).
for patchfile in "$ARCBOX_DIR"/patches/*.patch; do
    [ -f "$patchfile" ] || continue
    echo "Applying patch: $patchfile"
    patch -p1 < "$patchfile" || true
done

# Run .sh patch scripts (for complex patches that need sed).
for script in "$ARCBOX_DIR"/patches/*.sh; do
    [ -f "$script" ] || continue
    echo "Running patch script: $script"
    sh "$script"
done

# Copy driver source files and inject Kconfig/Makefile entries
for src in "$ARCBOX_DIR"/drivers/*.c; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    cp "$src" "drivers/block/$name"
    obj_name="${name%.c}.o"
    config_name="CONFIG_$(echo "${name%.c}" | tr 'a-z' 'A-Z')"

    if ! grep -q "$obj_name" drivers/block/Makefile; then
        printf 'obj-$(%s)\t+= %s\n' "$config_name" "$obj_name" >> drivers/block/Makefile
        echo "Injected $obj_name into drivers/block/Makefile"
    fi

    if ! grep -q "$config_name" drivers/block/Kconfig; then
        cat >> drivers/block/Kconfig <<EOF

config ${config_name#CONFIG_}
	bool "ArcBox ${name%.c} driver"
	depends on ARM64
	default n
	help
	  ArcBox custom driver: $name
EOF
        echo "Injected $config_name into drivers/block/Kconfig"
    fi
done
