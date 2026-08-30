# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Buildroot, driven non-interactively by Nix, producing the flashable
# SD card image for the Pi Zero bench lab.
#
# Buildroot wants the network mid-build; Nix (rightly) forbids that.
# The classic split solves it:
#
#   downloads  — a fixed-output derivation that runs `make source`
#                *with* network access and captures BR2_DL_DIR.  Its
#                output hash (dlHash below) pins the entire Buildroot
#                source closure: toolchain sources, kernel, firmware,
#                every package tarball.
#   image      — a normal (sandboxed, offline) derivation that runs
#                the real build against that download directory.
#
# The Rust binaries are NOT built by Buildroot: they come from
# rust-armv6.nix and enter the rootfs as an extra overlay directory,
# so Buildroot needs no Rust toolchain at all (its prebuilt host-rust
# binaries would not even run inside the Nix sandbox).
{
  pkgs,
  florestad,
  pi0Bench,
  # Output hash of the download closure.  TOFU workflow: after any
  # change to the defconfig's package set, set this to
  # pkgs.lib.fakeHash, build once, and copy the real hash from the
  # mismatch error.  Nix caches fixed-output derivations BY HASH, so
  # an unbumped stale hash silently serves the OLD downloads — always
  # bump on defconfig changes.  (The derivation name carries a
  # fingerprint of the defconfig to turn that mistake into a loud
  # hash-mismatch error instead.)
  dlHash ? pkgs.lib.fakeHash,
}:

let
  inherit (pkgs) lib;

  buildrootVersion = "2025.02.17";
  buildrootSrc = pkgs.fetchurl {
    url = "https://buildroot.org/downloads/buildroot-${buildrootVersion}.tar.xz";
    hash = "sha256-E2GHBFY60LkopFZKqnPi25fhLo3w7VrodHRKg5ZKAjo=";
  };

  # The BR2_EXTERNAL tree, committed in this repo.
  external = lib.cleanSource ../buildroot;

  defconfigFingerprint = builtins.substring 0 8 (
    builtins.hashFile "sha256" ../buildroot/configs/floresta_pi0_defconfig
  );

  # Second rootfs overlay, appended to the committed one: the
  # Nix-cross-compiled static binaries.
  rustOverlay = pkgs.runCommand "floresta-pi0-rust-overlay" { } ''
    install -D -m 0755 ${florestad}/bin/florestad $out/usr/bin/florestad
    install -D -m 0755 ${florestad}/bin/floresta-cli $out/usr/bin/floresta-cli
    install -D -m 0755 ${pi0Bench}/bin/pi0-bench $out/usr/bin/pi0-bench
  '';

  # Host tools Buildroot expects to find.  It builds most of its own
  # host dependencies (openssl, genimage, mtools...); this list is the
  # bootstrap layer its dependency check and package builds assume.
  buildrootDeps = with pkgs; [
    bc
    bison
    bzip2
    cpio
    file
    flex
    gawk
    ncurses
    perl
    python3
    rsync
    texinfo
    unzip
    util-linux
    wget
    which
  ];

  # Shared preamble: unpack Buildroot, defang the /usr/bin/file check
  # (the Nix sandbox has no /usr, `file` is in PATH), fix shebangs,
  # and load our defconfig from the external tree.
  prepare = ''
    export HOME="$TMPDIR"
    export BR2_JLEVEL="$NIX_BUILD_CORES"

    tar xf ${buildrootSrc}
    cd buildroot-${buildrootVersion}

    substituteInPlace support/dependencies/dependencies.sh \
      --replace-fail 'check_prog_host "/usr/bin/file"' 'check_prog_host "file"'
    patchShebangs --build .

    make BR2_EXTERNAL=${external} floresta_pi0_defconfig
  '';

  downloads = pkgs.stdenv.mkDerivation {
    name = "floresta-pi0-buildroot-downloads-${buildrootVersion}-${defconfigFingerprint}";

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = dlHash;

    nativeBuildInputs = buildrootDeps ++ [ pkgs.cacert ];
    # Fixed-output derivations may reach the network; wget needs the
    # CA bundle to do it over TLS.
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    # No fixup: the output is a tree of verified tarballs and must not
    # be rewritten in any way, or the recursive hash drifts.
    dontFixup = true;
    hardeningDisable = [ "all" ];

    buildCommand = ''
      ${prepare}
      export BR2_DL_DIR="$out"
      make source
    '';
  };

  image = pkgs.stdenv.mkDerivation {
    pname = "floresta-pi0-sd-image";
    version = buildrootVersion;

    nativeBuildInputs = buildrootDeps;
    hardeningDisable = [ "all" ];
    dontFixup = true;

    # Buildroot compiles its whole cross toolchain from source here
    # (armv6l has no cache to lean on) plus the kernel: hours, not
    # minutes.  Correctness over speed — by design.
    requiredSystemFeatures = [ "big-parallel" ];

    buildCommand = ''
      ${prepare}

      # The downloads live in the store read-only; Buildroot wants to
      # flock things in its DL dir, so hand it a writable copy.
      cp -r ${downloads} "$TMPDIR/dl"
      chmod -R u+w "$TMPDIR/dl"
      export BR2_DL_DIR="$TMPDIR/dl"

      # Append the Nix-built Rust overlay to the committed one, then
      # let kconfig re-normalize the config.
      sed -i 's|^\(BR2_ROOTFS_OVERLAY=".*\)"|\1 ${rustOverlay}"|' .config
      make olddefconfig

      make

      install -D -m 0444 output/images/sdcard.img \
        "$out/floresta-pi0-sdcard.img"
      (cd "$out" && sha256sum floresta-pi0-sdcard.img > SHA256SUMS)
    '';

    passthru = { inherit downloads rustOverlay; };

    meta = {
      description = "Flashable SD card image: Floresta bench lab for the Raspberry Pi Zero v1.3";
      platforms = [ "x86_64-linux" ];
    };
  };

  devShell = pkgs.mkShell {
    packages = buildrootDeps ++ [ pkgs.ncurses ];
    # Everything needed to drive the same Buildroot tree by hand —
    # `make menuconfig`, incremental rebuilds, poking at a failed
    # package — outside the Nix sandbox but with identical inputs.
    shellHook = ''
      export FLORESTA_PI0_BUILDROOT_TARBALL=${buildrootSrc}
      export FLORESTA_PI0_EXTERNAL=${external}
      echo "Floresta pi0 shell — Buildroot ${buildrootVersion}"
      echo "  tar xf \$FLORESTA_PI0_BUILDROOT_TARBALL && cd buildroot-${buildrootVersion}"
      echo "  make BR2_EXTERNAL=\$FLORESTA_PI0_EXTERNAL floresta_pi0_defconfig"
      echo "  make menuconfig   # or: make source / make"
      echo "(see pi0/README.md for the full workflow)"
    '';
  };
in
{
  inherit downloads image devShell;
}
