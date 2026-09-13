# SPDX-License-Identifier: MIT OR Apache-2.0
#
# How you cross-compile Rust *for this board*, and nothing else.
#
# Deliberately free of any knowledge about what gets built: it knows the
# target triple, the C/C++ compiler, the linker and the environment
# cargo needs — and hands them to whoever asks (./node.nix,
# ../microbench.nix).  Splitting this out is what lets a change to
# Floresta's source patches rebuild the node without touching the
# microbenchmark, and vice versa.
#
# Same approach as lib/android-outputs.nix — drive cargo with an
# explicit --target and a fenix toolchain that carries the target's
# rust-std, instead of nixpkgs' crossSystem machinery — but with two
# rasp-pi-zero-specific choices:
#
#  * Target arm-unknown-linux-musleabihf, statically linked
#    (+crt-static).  armv6l has no nixpkgs binary cache, and a static
#    musl binary is completely independent of whatever libc the
#    Buildroot rootfs ships: the image side and the Rust side can
#    evolve separately.
#  * The C/C++ toolchain is pkgsCross.muslpi (nixpkgs' name for
#    exactly this armv6l musl hard-float triple) — it compiles the C
#    parts and does the final link.  In the pinned tree the C/C++ in
#    the default florestad build is: secp256k1-sys, ring (rustls'
#    crypto provider), aws-lc-sys (pulled in by rcgen only — rustls
#    itself is on ring) — all built through the cc crate, which picks
#    the cross compiler from CC_<target> below — plus Bitcoin Core's
#    libbitcoinkernel (libbitcoinkernel-sys 0.4.0, crates.io, no
#    bindgen), whose build.rs only knows how to cross-compile for
#    Android; the CMAKE_TOOLCHAIN_FILE below covers this target.
{
  pkgs,
  inputs,
  system,
}:

let
  rustTarget = "arm-unknown-linux-musleabihf";
  targetUnderscore = builtins.replaceStrings [ "-" ] [ "_" ] rustTarget;
  targetEnvSuffix = pkgs.lib.toUpper targetUnderscore;

  # armv6l-unknown-linux-musleabihf cross gcc.  Built from source on
  # first use (~40 min) — the price of an uncached target, paid once
  # per nixpkgs pin.
  crossCc = pkgs.pkgsCross.muslpi.stdenv.cc;
  ccBin = "${crossCc}/bin/${crossCc.targetPrefix}";

  fenixPkgs = inputs.fenix.packages.${system};

  # rustc/cargo run on the build host; rust-std for the ARMv6 target
  # comes prebuilt from the Rust project via fenix (tier-2 target, so
  # std exists but nixpkgs would not have cached a compiler for it).
  rustToolchain = fenixPkgs.combine [
    fenixPkgs.stable.rustc
    fenixPkgs.stable.cargo
    fenixPkgs.stable.rust-src
    fenixPkgs.stable.rust-std
    fenixPkgs.targets.${rustTarget}.stable.rust-std
  ];

  # libbitcoinkernel-sys (0.4.0 as of the current pin) shells out to
  # `cmake` and only configures a cross toolchain for Android targets
  # — any other cross target compiles Bitcoin Core with the HOST
  # compiler and poisons the final link with x86_64 objects ("file
  # format not recognized").  CMake >= 3.21 honors
  # $CMAKE_TOOLCHAIN_FILE on every configure, so this small file fixes
  # the crate from the outside, no patching.  Once build.rs grows a
  # generic-cross branch upstream, this file can go.
  cmakeToolchain = pkgs.writeText "armv6-musl-toolchain.cmake" ''
    set(CMAKE_SYSTEM_NAME Linux)
    set(CMAKE_SYSTEM_PROCESSOR arm)
    set(CMAKE_C_COMPILER ${ccBin}cc)
    set(CMAKE_CXX_COMPILER ${ccBin}c++)
  '';

  # Linker wrapper that forces a fully static link at the gcc driver
  # level.  Same pattern as lib/android-outputs.nix's ndkLinker, and
  # for the same reason: flags injected here physically reach the
  # final link no matter what cargo does with RUSTFLAGS — and in this
  # workspace every RUSTFLAGS channel (per-target env, plain env,
  # CARGO_ENCODED_RUSTFLAGS) was observed being silently swallowed.
  # With -static, ld resolves stray dylib requests (libstdc++ from
  # C++-using build scripts) to their .a archives and emits no
  # PT_INTERP.
  # The extra twist that defeated every RUSTFLAGS attempt: rustc emits
  # `-Wl,-Bdynamic -lstdc++` for build scripts' dylib link requests,
  # and ld's -Bdynamic is a POSITIONAL toggle that re-enables shared
  # linking right past a leading -static.  Rewriting it to -Bstatic
  # here makes every library group resolve to its .a, unconditionally.
  staticLinker = pkgs.writeShellScript "armv6-static-cc" ''
    args=()
    for a in "$@"; do
      if [ "$a" = "-Wl,-Bdynamic" ]; then a="-Wl,-Bstatic"; fi
      args+=("$a")
    done
    exec ${ccBin}cc -static "''${args[@]}"
  '';
in
{
  inherit rustTarget crossCc;

  # Short, human name for this cross target.  Lives here so both
  # ./node.nix and ../microbench.nix label their derivations from ONE
  # source — the shared microbench must not hardcode "armv6-musl", it
  # will be built for aarch64 boards too.
  shortName = "armv6-musl";

  rustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  # Everything cargo and the cc crate need, as derivation env vars.
  # Consumers splice this into their derivation attrs verbatim.
  env = {
    CARGO_BUILD_TARGET = rustTarget;
    CMAKE_TOOLCHAIN_FILE = cmakeToolchain;
    "CARGO_TARGET_${targetEnvSuffix}_LINKER" = staticLinker;
    # Fully static: the binary must run on the Buildroot rootfs (and
    # anywhere else) without carrying a libc contract with it.
    "CARGO_TARGET_${targetEnvSuffix}_RUSTFLAGS" = "-C target-feature=+crt-static";
    # The cc crate (secp256k1-sys, ring, aws-lc-sys,
    # libbitcoinkernel-sys) picks the target compiler from these.
    "CC_${targetUnderscore}" = "${ccBin}cc";
    "CXX_${targetUnderscore}" = "${ccBin}c++";
    "AR_${targetUnderscore}" = "${ccBin}ar";
  };
}
