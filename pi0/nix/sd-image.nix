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
  dlHash ? "sha256-5Zj5FNzVL7zBJxA8KIjI6K1GSW10nA6yN0kSH3vtYko=",
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
    # Not required by a pristine tree, but cheap insurance: if
    # anything ever bumps a script's mtime, autotools reaches for
    # help2man to regenerate man pages instead of failing the build.
    help2man
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

  # Buildroot's fix-rpath (host-finalize) requires a patchelf that
  # carries Buildroot's own out-of-tree `--make-rpath-relative`
  # option, and the host-patchelf it builds for itself refuses to run
  # inside the Nix sandbox.  fix-rpath offers a $PATCHELF override, so
  # build the very same patched patchelf as a Nix derivation — always
  # executable, and outside HOST_DIR so fix-rpath never mutates it.
  brPatchelfPatch = pkgs.runCommand "buildroot-patchelf-rpath-relative.patch" { } ''
    tar xf ${buildrootSrc} -O \
      buildroot-${buildrootVersion}/package/patchelf/0001-Add-option-to-make-the-rpath-relative-under-a-specif.patch \
      > $out
  '';
  brPatchelf = pkgs.stdenv.mkDerivation {
    pname = "buildroot-patchelf";
    version = "0.13";
    # Same tarball + hash Buildroot pins in package/patchelf/.
    src = pkgs.fetchurl {
      url = "https://github.com/NixOS/patchelf/releases/download/0.13/patchelf-0.13.tar.bz2";
      hash = "sha256-TH7UvPwaEU1ihuSg08GpDbFHpMOt2hgU7g7uD57pF+0=";
    };
    patches = [ brPatchelfPatch ];
  };

  # Buildroot instrumentation hook (called as: <start|end> <step>
  # <package> with $BUILD_DIR exported): after each package's patch
  # step, rewrite absolute shebangs that do not exist inside the Nix
  # sandbox (only /bin/sh does) to their store equivalents — e.g.
  # OpenSSL's Configure starts with `#!/usr/bin/env perl`.  Scope is
  # deliberately narrow: executable files only (non-executable scripts
  # are run through an explicit interpreter and never consult their
  # shebang), and nothing that lands on the target rootfs — no package
  # in this config installs env-shebang scripts to the target, and the
  # florestaos overlay is all #!/bin/sh.
  shebangHook = pkgs.writeShellScript "br-sandbox-shebang-hook" ''
    [ "$1" = end ] || exit 0
    [ "$2" = patch ] || exit 0
    ref=$(mktemp)
    for d in "$BUILD_DIR/$3"-*; do
      [ -d "$d" ] || continue
      find "$d" -type f -perm -100 -print0 2>/dev/null |
        while IFS= read -r -d "" f; do
          # Only rewrite files whose shebang actually offends — and
          # keep their mtime: sed -i recreates the file, and a fresh
          # timestamp makes autotools think shipped artifacts (man
          # pages, parsers) are stale and regenerate them with tools
          # we do not carry.
          case "$(head -c 32 "$f" 2>/dev/null)" in
          '#!/usr/bin/env'* | '#! /usr/bin/env'*) ;;
          '#!/usr/bin/perl'* | '#! /usr/bin/perl'*) ;;
          '#!/usr/bin/python3'* | '#! /usr/bin/python3'*) ;;
          '#!/bin/bash'* | '#! /bin/bash'*) ;;
          *) continue ;;
          esac
          touch -r "$f" "$ref"
          sed -i \
            -e '1s|^#! */usr/bin/env|#!${pkgs.coreutils}/bin/env|' \
            -e '1s|^#! */usr/bin/perl|#!${pkgs.perl}/bin/perl|' \
            -e '1s|^#! */usr/bin/python3|#!${pkgs.python3}/bin/python3|' \
            -e '1s|^#! */bin/bash|#!${pkgs.bash}/bin/bash|' \
            "$f"
          touch -r "$ref" "$f"
        done
    done
    rm -f "$ref"
    exit 0
  '';

  # Shared preamble: unpack Buildroot, defang the /usr/bin/file check
  # (the Nix sandbox has no /usr, `file` is in PATH), fix shebangs,
  # and load our defconfig from the external tree.
  prepare = ''
    export HOME="$TMPDIR"
    export BR2_JLEVEL="$NIX_BUILD_CORES"
    # See shebangHook above; a no-op during `make source`.
    export BR2_INSTRUMENTATION_SCRIPTS=${shebangHook}
    # See brPatchelf above; consumed by support/scripts/fix-rpath.
    export PATCHELF=${brPatchelf}/bin/patchelf

    tar xf ${buildrootSrc}
    cd buildroot-${buildrootVersion}

    substituteInPlace support/dependencies/dependencies.sh \
      --replace-fail 'check_prog_host "/usr/bin/file"' 'check_prog_host "file"'
    # The sandbox provides /bin/sh and nothing else in /bin — Buildroot
    # hardcodes /bin/true (autoreconf's AUTOPOINT, GTKDOCIZE, the
    # no-strip case) and /bin/false (pkg-cmake's CXX-less guard).  The
    # bare names resolve via PATH to coreutils.
    sed -i 's|/bin/true|true|g; s|/bin/false|false|g' \
      package/pkg-autotools.mk \
      package/pkg-cmake.mk \
      package/autoconf/autoconf.mk \
      package/Makefile.in
    # Rewrite ONLY the shebangs the sandbox cannot execute (it has
    # /bin/sh and nothing else).  A blanket patchShebangs would — and
    # once did — also rewrite the #!/bin/sh of scripts Buildroot
    # installs INTO THE TARGET rootfs (initscripts' rcS, busybox's
    # S01syslogd, dropbear's S50...) to build-machine store paths that
    # do not exist on the Pi, silently bricking userspace init.
    # #!/bin/sh scripts run fine in the sandbox untouched, and no
    # target-installed script in this package set uses the four
    # interpreters rewritten here.
    find . -type f -perm -100 -print0 |
      while IFS= read -r -d "" f; do
        case "$(head -c 32 "$f" 2>/dev/null)" in
        '#!/usr/bin/env'* | '#! /usr/bin/env'*) ;;
        '#!/usr/bin/perl'* | '#! /usr/bin/perl'*) ;;
        '#!/usr/bin/python3'* | '#! /usr/bin/python3'*) ;;
        '#!/bin/bash'* | '#! /bin/bash'*) ;;
        *) continue ;;
        esac
        sed -i \
          -e '1s|^#! */usr/bin/env|#!${pkgs.coreutils}/bin/env|' \
          -e '1s|^#! */usr/bin/perl|#!${pkgs.perl}/bin/perl|' \
          -e '1s|^#! */usr/bin/python3|#!${pkgs.python3}/bin/python3|' \
          -e '1s|^#! */bin/bash|#!${pkgs.bash}/bin/bash|' \
          "$f"
      done

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

    passthru = {
      inherit downloads rustOverlay brPatchelf;
    };

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
