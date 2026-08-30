# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Nix-native boot smoke test: boots the built SD image under QEMU
# (-M raspi0, pure TCG — no KVM needed, sandbox-safe) and asserts the
# boot reached userspace by reading the serial console log.
#
# NOT the nixosTest harness on purpose: that driver assumes a NixOS
# guest (systemd + injected backdoor) and cannot drive a
# Buildroot/busybox image.  Console-log assertions are the honest
# interface this guest actually has.
#
# Two boots by design, mirroring real first-boot behaviour: boot #1
# repartitions and calls reboot — which on QEMU's raspi0 halts instead
# (the restart path needs the bcm2835 PM watchdog, blacklisted below
# because QEMU does not model that block).  Boot #2 reuses the same
# (now repartitioned) SD image and must reach a login prompt, with
# mkfs.f2fs, /data, dropbear keys and zram all exercised for real.
#
# What it cannot prove (hardware-only): the ROM/firmware SD boot chain
# and the dwc2 USB gadget in peripheral mode.
{ pkgs, image }:

pkgs.runCommand "floresta-pi0-boot-test"
  {
    nativeBuildInputs = with pkgs; [
      qemu
      mtools
      util-linux
    ];
  }
  ''
    cp ${image}/floresta-pi0-sdcard.img sd.img
    chmod +w sd.img

    # QEMU wants power-of-two SD sizes.  512M (sparse) leaves the
    # first-boot data partition ~320M — comfortably above f2fs's
    # minimum, so the mkfs/mount path runs for real.
    qemu-img resize -q -f raw sd.img 512M
    start=$(sfdisk -d sd.img | grep "img1" | sed 's/.*start= *\([0-9]*\).*/\1/')
    mcopy -i "sd.img@@$((start * 512))" ::zImage zImage
    mcopy -i "sd.img@@$((start * 512))" ::bcm2708-rpi-zero.dtb board.dtb

    # bcm2835_pm is blacklisted because QEMU does not model the PM
    # block; its probe faults and takes the deferred-probe worker
    # (and with it the SD host) down.  Harmless on real hardware.
    run_qemu() {
      qemu-system-arm -M raspi0 \
        -kernel zImage -dtb board.dtb \
        -append "root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait init=/sbin/preinit console=ttyAMA0,115200 initcall_blacklist=bcm2835_pm_driver_init" \
        -sd sd.img -serial "file:$1" -monitor none -display none &
      qemu_pid=$!
    }

    # wait_for <logfile> <regex> — poll generously; TCG on a loaded
    # builder is slow.  Returns nonzero on timeout or qemu death.
    wait_for() {
      for _ in $(seq 600); do
        grep -qE "$2" "$1" 2>/dev/null && return 0
        kill -0 $qemu_pid 2>/dev/null || return 1
        sleep 1
      done
      return 1
    }

    echo ">>> boot 1: first-boot repartition (ends in a halt on QEMU)"
    run_qemu boot1.log
    # Either the guest halts after its reboot call (expected on QEMU),
    # or a future QEMU learns to reset and sails straight to login.
    wait_for boot1.log "System halted|login:" || true
    kill $qemu_pid 2>/dev/null || true
    echo "=== boot1.log tail ==="
    tail -n 20 boot1.log || true

    if grep -q "can't run '/etc/init.d/rcS'" boot1.log; then
      echo "FAIL: rcS never ran (interpreter/shebang regression?)"
      exit 1
    fi
    grep -q "florestaos: first boot: creating data partition" boot1.log || {
      echo "FAIL: first-boot partitioning never happened"
      exit 1
    }

    if ! grep -q "login:" boot1.log; then
      echo ">>> boot 2: same image, must reach a login prompt"
      run_qemu boot2.log
      wait_for boot2.log "login:" || {
        kill $qemu_pid 2>/dev/null || true
        echo "=== boot2.log tail ==="
        tail -n 40 boot2.log || true
        echo "FAIL: no login prompt on the second boot"
        exit 1
      }
      kill $qemu_pid 2>/dev/null || true
      echo "=== boot2.log tail ==="
      tail -n 20 boot2.log || true
      grep -q "florestaos:" boot2.log || {
        echo "FAIL: florestaos init scripts left no trace on boot 2"
        exit 1
      }
    fi

    mkdir -p $out
    cp boot1.log $out/
    [ -f boot2.log ] && cp boot2.log $out/
    echo PASS >$out/result
  ''
