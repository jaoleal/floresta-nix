# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Raspberry Pi Zero v1.3 — the lab's worst case, and the reason the
# harness assumes nothing.  Single ARMv6 core at 1 GHz, 456 MB of RAM,
# busybox userland, no RTC, no `perf`, no PSI, and a `date` that cannot
# print anything finer than a whole second.
#
# Every value here was measured on the board (see images/harness/README.md,
# "Discovery"), not guessed from the datasheet.
{
  name = "rasp-pi-zero";

  # The board hangs off the lab host's USB port and answers on the
  # gadget network created by images/rasp-pi-zero/assets/buildroot.  Override with --host.
  host = "root@10.7.0.2";

  arch = "armv6l-linux";
  description = "Raspberry Pi Zero v1.3, BCM2835, 1 core, 456 MB, busybox 1.37";

  # Where florestad keeps its chainstate.  /data is the f2fs partition
  # created on first boot; everything else on the board is read-only.
  datadir = "/data/florestadir";
  network = "signet";

  # Absolute path, so preflight never resolves a different binary than
  # the run uses.  /data/bin outranks /usr/bin on the board's PATH, so
  # `florestaos update-florestad` swaps the specimen without a reflash.
  florestad = "/usr/bin/florestad";
  florestaCli = "/usr/bin/floresta-cli";

  # Verified present on the board.  Preflight fails if one disappears.
  requiredTools = [
    "awk"
    "cut"
    "grep"
    "kill"
    "md5sum"
    "pidof"
    "sed"
    "sha256sum"
    "sleep"
    "timeout"
  ];

  # Nice to have; their absence only costs a column.
  optionalTools = [
    "wget"
    "nice"
  ];

  # `perf` is not in the busybox image (perf_event_paranoid exists, the
  # tool does not), so `--profile perf` fails preflight here by design
  # rather than producing an empty flamegraph.
  profiler = "none";

  # florestad hardcodes 0.0.0.0:3333 and serves the exposition on "/",
  # not "/metrics" — see crates/floresta-metrics/src/lib.rs.  Neither is
  # configurable by flag, so these are constants of the binary, not of
  # the board.
  metricsPort = 3333;
  metricsPath = "/";

  # busybox `date` has no %N: `date +%s%3N` yields whole seconds with a
  # literal "3N" stripped.  /proc/uptime, by contrast, is centisecond
  # resolution — so target samples are stamped from uptime and anchored
  # to the host clock once per run.  See §3.5 in the brief.
  timeSource = "uptime";

  # No getconf on the board.  100 is USER_HZ for every ARM kernel build
  # in this image; recorded in meta.json so a wrong guess is auditable.
  clkTck = 100;

  sensors = {
    thermal = "/sys/class/thermal/thermal_zone0/temp";

    # The Pi firmware's throttle/undervoltage word, which is what
    # `vcgencmd get_throttled` reads.  vcgencmd itself is Raspberry Pi
    # userland and is not in the image; this sysfs file is.
    throttled = "/sys/devices/platform/soc/soc:firmware/get_throttled";

    # CONFIG_PSI is off in this kernel: /proc/pressure does not exist.
    pressure = false;

    # Block device backing the datadir, and the USB gadget interface
    # every byte of chain data arrives through.  null means autodetect.
    diskDevice = "mmcblk0p3";
    netInterface = "usb0";
  };

  # Chainstate plus room for the run's artifacts.
  # One sample per this many seconds.  Measured on the board: the
  # collector costs ~30 ms of CPU per tick, so 1 s would be ~2.9% of the
  # single core -- right at the acceptance limit -- and 2 s is ~1.5%.
  # Block events come from the log at millisecond resolution regardless;
  # this rate only governs the resource series.
  procInterval = 2;

  minFreeBytes = 2147483648;

  powerMeter = "none";

  # No switchable hub on this bench yet.  Set to e.g.
  # { location = "3-6"; port = 1; } once one appears, and the harness
  # gains cold-boot energy measurement and power-cycling between runs.
  hub = null;
}
