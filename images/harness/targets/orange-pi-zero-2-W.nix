# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Orange Pi Zero 2W (Allwinner H618) running the NixOS image this repo
# builds — see images/orange-pi-zero-2-W/.
#
# Derived from ./generic-aarch64.nix, which stays the profile for "some
# aarch64 board running some distro".  The differences here are all
# consequences of knowing exactly which OS is on the card:
#
#  * the datadir is where services.floresta puts it;
#  * florestad and floresta-cli are NOT on root's PATH as bare names —
#    NixOS has no /usr/bin, so the orchestrator is given absolute store
#    paths by the run wrapper;
#  * `perf` is NOT installed: the image is a minimal closure on purpose,
#    so --profile perf needs it added to the image first.
#
# NOT YET MEASURED.  The values below that are marked as such are
# inherited assumptions, not observations — the board has no OS on its
# card yet.  Fix them against real hardware before trusting a run; the
# rasp-pi-zero profile was written the other way round (measured first)
# and that is the standard to hold this one to.
{
  name = "orange-pi-zero-2-W";

  # The board has no ethernet port, so this is whatever address it got
  # on WiFi.  No default worth guessing; pass --host.
  host = null;

  arch = "aarch64-linux";
  description = "Orange Pi Zero 2W (H618, 4x A53) running the floresta-nix NixOS image";

  # Matches services.floresta.dataDir in images/orange-pi-zero-2-W/system.nix.
  datadir = "/var/lib/floresta";
  network = "signet";

  # Resolved through the login shell's PATH.  On NixOS these are only on
  # PATH if the image puts them in environment.systemPackages; the image
  # currently installs them through the service unit instead, so pass
  # absolute paths with --florestad / --floresta-cli until that changes.
  florestad = "florestad";
  florestaCli = "floresta-cli";

  # A NixOS minimal closure still has full coreutils, unlike the Pi
  # Zero's busybox.
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
    "nice"
  ];

  # Deliberately absent from the image: perf would pull a second kernel
  # source closure onto a small card.  Add it to the image, then set this
  # to "perf".
  profiler = null;

  metricsPort = 3333;
  metricsPath = "/";

  # GNU coreutils date: millisecond stamps on the target side.
  timeSource = "date-ms";

  clkTck = 100;

  sensors = {
    # NOT MEASURED: the H618 exposes thermal zones through
    # sun8i-thermal, but which zone index is the CPU is unverified.
    thermal = "/sys/class/thermal/thermal_zone0/temp";

    # Not a Raspberry Pi: no firmware throttle word to read.
    throttled = null;

    # PSI is on in the NixOS kernel.
    pressure = true;

    # Autodetected from the datadir's mount point and the default route.
    diskDevice = null;
    netInterface = null;
  };

  # Four A53s with coreutils absorb 1 Hz without noticing.
  procInterval = 1;

  minFreeBytes = 10737418240;

  # NOT MEASURED: no meter wired to this board yet.  The Pi Zero lab
  # uses a UM25C inline on USB; this board draws through USB-C, so the
  # same meter should work once it is in the path.
  powerMeter = "none";
  hub = null;
}
