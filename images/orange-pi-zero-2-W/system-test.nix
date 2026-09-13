# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Acceptance test for the Orange Pi Zero 2W image.
#
# Unlike ../rasp-pi-zero/system-test.nix — which asserts on a serial log
# because a Buildroot/busybox guest cannot host the NixOS test driver —
# this board runs NixOS, so the real driver works: a scripted machine
# with systemd introspection instead of grepping console output.
#
# It boots the LAB module only, not the board module.  That is
# deliberate, and it is the same reasoning as `os-<board>`: the lab is
# what this test is about (does florestad come up and answer?), while the
# board module is U-Boot, a device tree and an SD partition table —
# things QEMU's `-M virt` does not model and that only real hardware can
# prove.  Testing the lab alone also means this does not build the SD
# image, so it is minutes instead of an image build.
#
# Runs on aarch64-linux (it boots an aarch64 guest).
{
  pkgs,
  node,
  # The lab module out of ./system.nix, handed over by ./default.nix so
  # this file never has to know how the OS is assembled.
  labModule,
}:

pkgs.testers.runNixOSTest {
  name = "orange-pi-zero-2-W-lab";

  nodes.board = labModule;

  testScript = ''
    board.wait_for_unit("multi-user.target")

    # This is a bench INSTRUMENT: the node must NOT be running from boot.
    # ../harness launches florestad itself, and a second one from boot
    # would fight it for the datadir and for the hardcoded metrics port.
    board.fail("systemctl is-active --quiet floresta.service")

    # But the service is there, configured, and starts on request.
    board.succeed("systemctl start floresta.service")
    board.wait_for_unit("floresta.service")
    board.succeed("systemctl is-active --quiet floresta.service")

    # It must be the node we built, not something out of nixpkgs.
    board.succeed("${node}/bin/florestad --version | grep -q florestad")

    # zram is what keeps an IBD from dying on a 1 GB board.
    board.succeed("test -e /dev/zram0")
  '';
}
