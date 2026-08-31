# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Entry point for the pi0 subproject: wires the ARMv6 Rust cross
# builds into the Buildroot image build.  Consumed by the root
# flake.nix, x86_64-linux only (Buildroot requires a Linux build host,
# and the download derivation's hash is pinned for one platform's
# closure).
{
  pkgs,
  inputs,
  system,
}:

let
  # The Floresta tree the lab runs: the flake's `floresta-master`
  # input — currently the bump/kernel0-3 branch proposed upstream,
  # which moves to crates.io bitcoinkernel 0.3.0 (libbitcoinkernel-sys
  # 0.4.0: bindgen-free, Android-aware build.rs).  Generic non-Android
  # cross is still not handled by that build.rs, so rust-armv6.nix
  # keeps compensating with a CMAKE_TOOLCHAIN_FILE.
  # Update with: nix flake update floresta-master
  florestaSrc = inputs.floresta-master;

  rust = import ./rust-armv6.nix {
    inherit
      pkgs
      inputs
      system
      florestaSrc
      ;
  };

  sdImage = import ./sd-image.nix {
    inherit pkgs;
    florestad = rust.floresta;
    pi0Bench = rust.pi0-bench;
  };
in
{
  checks = {
    # `nix build .#checks.x86_64-linux.pi0-boot-test` = build the
    # image AND boot-validate it under QEMU in one command.  Runs
    # before any hardware flashing — see pi0/README.md.
    pi0-boot-test = import ./qemu-boot-test.nix {
      inherit pkgs;
      inherit (sdImage) image;
    };
  };

  packages = {
    pi0-sd-image = sdImage.image;
    # Exposed on their own so the expensive pieces can be built (and
    # debugged) independently of the full image.
    pi0-florestad = rust.floresta;
    inherit (rust) pi0-bench;
    pi0-buildroot-downloads = sdImage.downloads;
  };

  inherit (sdImage) devShell;
}
