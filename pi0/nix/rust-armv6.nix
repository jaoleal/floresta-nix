# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Rust cross-compilation for the Raspberry Pi Zero v1.3 (ARM1176,
# ARMv6 + VFPv2): florestad/floresta-cli and the pi0-bench
# microbenchmark binary.
#
# Same approach as lib/android-outputs.nix — drive cargo with an
# explicit --target and a fenix toolchain that carries the target's
# rust-std, instead of nixpkgs' crossSystem machinery — but with two
# pi0-specific choices:
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
  florestaSrc,
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
  armRustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

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

  crossEnv = {
    CARGO_BUILD_TARGET = rustTarget;
    CMAKE_TOOLCHAIN_FILE = cmakeToolchain;
    "CARGO_TARGET_${targetEnvSuffix}_LINKER" = "${ccBin}cc";
    # Fully static: the binary must run on the Buildroot rootfs (and
    # anywhere else) without carrying a libc contract with it.
    "CARGO_TARGET_${targetEnvSuffix}_RUSTFLAGS" = "-C target-feature=+crt-static";
    # The cc crate (secp256k1-sys, ring, aws-lc-sys,
    # libbitcoinkernel-sys 0.3.0) picks the target compiler from these.
    "CC_${targetUnderscore}" = "${ccBin}cc";
    "CXX_${targetUnderscore}" = "${ccBin}c++";
    "AR_${targetUnderscore}" = "${ccBin}ar";
  };

  # florestad + floresta-cli from the pinned upstream master (see
  # default.nix) — deliberately NOT the Android fork: upstream now
  # consumes bitcoinkernel from crates.io, bindgen-free.
  floresta =
    (import ../../lib/floresta-build.nix {
      inherit pkgs;
      inherit (pkgs) lib;
      defaultSrc = florestaSrc;
      rustPlatform = armRustPlatform;
      pnameSuffix = "-armv6-musl";

      # The stock cargo hooks mishandle explicit cross targets; same
      # workaround as the Android builds.
      dontCargoBuild = true;
      customBuildPhase = ''
        runHook preBuild
        cargo build \
          $cargoBuildFlags \
          --target ${rustTarget} \
          --offline \
          --release
        runHook postBuild
      '';
      customInstallPhase = ''
        runHook preInstall
        install -D -m 0755 target/${rustTarget}/release/florestad $out/bin/florestad
        install -D -m 0755 target/${rustTarget}/release/floresta-cli $out/bin/floresta-cli
        runHook postInstall
      '';

      extraEnvVars = crossEnv;
      extraNativeBuildInputsGlobal = [ crossCc ];
    }).default;

  pi0-bench = armRustPlatform.buildRustPackage (
    {
      pname = "pi0-bench-armv6-musl";
      version = "0.1.0";
      src = pkgs.lib.cleanSource ../bench;
      cargoLock.lockFile = ../bench/Cargo.lock;

      nativeBuildInputs = [ crossCc ];

      dontCargoBuild = true;
      dontCargoInstall = true;
      buildPhase = ''
        runHook preBuild
        cargo build --target ${rustTarget} --offline --release
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -D -m 0755 target/${rustTarget}/release/pi0-bench $out/bin/pi0-bench
        runHook postInstall
      '';

      meta = {
        description = "CPU microbenchmarks for the Floresta Pi Zero bench lab";
        mainProgram = "pi0-bench";
      };
    }
    // crossEnv
  );
in
{
  inherit floresta pi0-bench rustTarget;
}
