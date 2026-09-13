#!/bin/sh
# Runs after the rootfs overlay is applied, before the squashfs is cut.
set -eu

# Mount points must exist inside the squashfs — nothing can mkdir on a
# read-only root at runtime.
mkdir -p "${TARGET_DIR}/boot" "${TARGET_DIR}/data"

# Dropbear host keys must survive reboots or every SSH session greets
# the user with a scary key-changed warning.  /etc is a throwaway
# tmpfs overlay, so point the key directory at the persistent data
# partition (S05florestaboot creates /data/dropbear before dropbear
# starts).  The Buildroot package installed a real directory; replace
# it with a symlink.
rm -rf "${TARGET_DIR}/etc/dropbear"
ln -sf /data/dropbear "${TARGET_DIR}/etc/dropbear"

# The overlay ships its own inittab/fstab; make sure the scripts it
# ships are executable even if a checkout lost the x-bit.
chmod +x "${TARGET_DIR}/sbin/preinit" \
	"${TARGET_DIR}/usr/sbin/getty-wait" \
	"${TARGET_DIR}/usr/bin/sampler" \
	"${TARGET_DIR}/usr/bin/bench-micro" \
	"${TARGET_DIR}/usr/bin/floresta-bench-run" \
	"${TARGET_DIR}/usr/bin/florestaos" \
	"${TARGET_DIR}"/etc/init.d/S[0-9][0-9]floresta* \
	"${TARGET_DIR}/etc/init.d/S30usbgadget" \
	"${TARGET_DIR}/etc/init.d/S45clock"
