# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Packaging for the bench-node harness.
#
# The harness runs on the *lab host*, never on the target: an ARMv6
# board has no binary cache in nixpkgs, and cross-compiling a Python
# stack for it to run a shell loop would be absurd.  So everything here
# is host-side, and the only thing that reaches the board is POSIX sh
# piped over SSH.
#
# Target profiles are Nix (typed, commented, evaluated once) but the
# orchestrator reads JSON: converting at build time keeps `nix eval` out
# of the run loop, where its startup cost would land inside the
# measurement.
{ pkgs }:

let
  inherit (pkgs) lib;

  targetFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
    builtins.readDir ../targets
  );

  # Each targets/<name>.nix becomes <name>.json, so adding a board is
  # adding one file and nothing else.
  targetsJson = pkgs.runCommand "bench-node-targets" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (
        name: _:
        let
          stem = lib.removeSuffix ".nix" name;
          profile = import (../targets + "/${name}");
        in
        ''
          cp ${pkgs.writeText "${stem}.json" (builtins.toJSON profile)} $out/${stem}.json
        ''
      ) targetFiles
    )
  );

  # pyarrow is a large closure and is only needed by `export --format
  # parquet`; sqlite covers the same data with the standard library.
  # Including it on Linux only keeps the app buildable on a Mac lab host.
  python = pkgs.python3.withPackages (
    ps: lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ps.pyarrow ]
  );

  harnessSrc = pkgs.runCommand "bench-node-harness" { } ''
    mkdir -p $out
    cp -r ${../remote} $out/remote
    cp -r ${../power} $out/power
    cp -r ${../report} $out/report
    cp ${../run.sh} $out/run.sh
    chmod -R u+w $out
    chmod +x $out/run.sh $out/power/*.sh $out/remote/*.sh
    # Shebangs stay as `/usr/bin/env`: runtimeInputs puts the right bash
    # and python3 first on PATH, and patchShebangs here would bake in
    # whatever the build sandbox happened to have.
  '';

in
pkgs.writeShellApplication {
  name = "bench-node";

  runtimeInputs = [
    pkgs.openssh
    pkgs.jq
    pkgs.curl
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.coreutils
    pkgs.git
    python
  ]
  # Flamegraph rendering happens on the host; the target only ever
  # produces folded text.
  ++ lib.optional (pkgs ? inferno) pkgs.inferno;

  # Both are overridable so a new board profile can be tried from a
  # scratch directory without rebuilding the app first.
  text = ''
    export BENCH_HARNESS_DIR="''${BENCH_HARNESS_DIR:-${harnessSrc}}"
    export BENCH_TARGETS_DIR="''${BENCH_TARGETS_DIR:-${targetsJson}}"
    exec ${pkgs.bash}/bin/bash "$BENCH_HARNESS_DIR/run.sh" "$@"
  '';

  meta = {
    description = "Measure a Bitcoin node's time, energy and bottlenecks on a small board";
    mainProgram = "bench-node";
  };
}
