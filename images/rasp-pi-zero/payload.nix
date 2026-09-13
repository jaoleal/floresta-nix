# SPDX-License-Identifier: MIT OR Apache-2.0
#
# THE SEAM between the node and the OS.
#
# A rootfs overlay carrying the Nix-cross-compiled binaries, and the
# ONLY place where anything from ./node.nix or ../microbench.nix touches
# ./system.nix.  Buildroot appends it to the committed overlay, so it
# needs no Rust toolchain of its own (its prebuilt host-rust would not
# even run inside the Nix sandbox).
#
# Because the seam is one derivation with one store path, ./system.nix
# takes a single input instead of one per binary — and can be asked for
# an image with NO payload at all (`nix build .#os-rasp-pi-zero`), which
# is how you iterate on init scripts without waiting for an ARMv6 cross
# build.
{
  pkgs,
  node,
  microbench,
}:

pkgs.runCommand "floresta-rasp-pi-zero-payload" { } ''
  install -D -m 0755 ${node}/bin/florestad $out/usr/bin/florestad
  install -D -m 0755 ${node}/bin/floresta-cli $out/usr/bin/floresta-cli
  install -D -m 0755 ${microbench}/bin/floresta-microbench $out/usr/bin/floresta-microbench
''
