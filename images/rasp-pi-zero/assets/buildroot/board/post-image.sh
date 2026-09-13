#!/bin/sh
# Assemble the SD card image.  Modeled on Buildroot's own
# board/raspberrypi/post-image.sh: collect everything that belongs on
# the FAT partition, substitute the list into genimage.cfg.in, run
# genimage.
#
# POSIX sh on purpose: the Nix build sandbox provides /bin/sh and
# nothing else — a bash shebang would die with "bad interpreter".
set -eu

BOARD_DIR="$(dirname "$0")"
GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# Lab files that live on the FAT so any OS can touch them.
install -m 0644 "${BOARD_DIR}/florestaos.conf" "${BINARIES_DIR}/florestaos.conf"
install -m 0644 "${BOARD_DIR}/fat-readme.txt" "${BINARIES_DIR}/FLORESTAOS-README.txt"

# One `"name",` per FAT entry.  The \t and \n stay literal here; sed
# expands them when substituting into the template.  genimage copies
# each entry into the FAT *root* under its basename (the path part
# only locates the source under --inputpath).
BOOT_FILES=""
for i in "${BINARIES_DIR}"/*.dtb "${BINARIES_DIR}"/rpi-firmware/* \
	"${BINARIES_DIR}/zImage" "${BINARIES_DIR}/florestaos.conf" \
	"${BINARIES_DIR}/FLORESTAOS-README.txt"; do
	BOOT_FILES="${BOOT_FILES}\\t\\t\\t\"${i#"${BINARIES_DIR}"/}\",\\n"
done

# Anchored: only the standalone placeholder line is replaced, never a
# stray mention inside a comment.
sed "s|^#BOOT_FILES#\$|${BOOT_FILES}|" "${BOARD_DIR}/genimage.cfg.in" \
	>"${GENIMAGE_CFG}"

# genimage copies the given rootpath into the image tree; the rootfs is
# already a prebuilt squashfs, so hand it an empty directory.
ROOTPATH_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT

rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}" \
	--tmppath "${GENIMAGE_TMP}" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"
