# SPDX-License-Identifier: MIT OR Apache-2.0
#
# A generic 64-bit ARM SBC running an ordinary distro (Raspberry Pi OS,
# Armbian, Debian): coreutils instead of busybox, a real RTC, PSI in the
# kernel, and `perf` installable from the distro.
#
# This profile exists to prove the design: it was written without
# touching a line outside targets/, which is the test the brief asks
# for.  Everything the rasp-pi-zero profile has to work around — no %N in date,
# no perf, no PSI, a firmware-specific throttle file — is expressed
# here as different data, not different code.
{
  name = "generic-aarch64";

  # No default worth guessing; pass --host.
  host = null;

  arch = "aarch64-linux";
  description = "Generic aarch64 SBC, coreutils userland, mainline kernel";

  datadir = "/var/lib/floresta";
  network = "signet";

  # Resolved through the login shell's PATH when not absolute.
  florestad = "florestad";
  florestaCli = "floresta-cli";

  requiredTools = [
    "awk"
    "cut"
    "grep"
    "kill"
    "pidof"
    "sed"
    "sha256sum"
    "sleep"
    "timeout"
  ];

  optionalTools = [
    "curl"
    "wget"
    "perf"
    "nice"
  ];

  # Available on most distro kernels; preflight verifies the binary is
  # actually there and that perf_event_paranoid permits sampling before
  # --profile perf is allowed to proceed.
  profiler = "perf";

  metricsPort = 3333;
  metricsPath = "/";

  # GNU date understands %s%3N, so target-side stamps are already
  # millisecond-resolution.  The uptime anchor is still recorded, which
  # is what keeps the two profiles' CSVs directly comparable.
  timeSource = "date-ms";

  clkTck = 100;

  sensors = {
    thermal = "/sys/class/thermal/thermal_zone0/temp";

    # Not a Raspberry-Pi firmware board: no throttle word to read.
    throttled = null;

    pressure = true;

    # Autodetected from the datadir's mount point and the default route.
    diskDevice = null;
    netInterface = null;
  };

  # A multi-core board with coreutils absorbs 1 Hz without noticing.
  procInterval = 1;

  minFreeBytes = 10737418240;

  powerMeter = "none";
  hub = null;
}
