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
  masterSrc,
}:

let
  rust = import ./rust-armv6.nix {
    inherit
      pkgs
      inputs
      system
      masterSrc
      ;
  };

  sdImage = import ./sd-image.nix {
    inherit pkgs;
    florestad = rust.floresta;
    pi0Bench = rust.pi0-bench;
  };
in
{
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
