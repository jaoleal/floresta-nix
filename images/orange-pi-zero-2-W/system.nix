# SPDX-License-Identifier: MIT OR Apache-2.0
#
# THE OS: a NixOS sd-image for the Orange Pi Zero 2W (Allwinner H618).
#
# Written as TWO modules on purpose, because they have different futures:
#
#   lab    — what this image is FOR: the florestad service, the bench
#            user, SSH, zram.  Board-agnostic.  This is the part that
#            moves to ../florestaos once a second aarch64 board exists;
#            ./system-test.nix already exercises it on its own.
#   board  — what this SILICON needs: U-Boot for the H618, its device
#            tree, the serial console, the SD image layout.  Stays here
#            forever.
#
# Why NixOS at all, when ../rasp-pi-zero hand-rolls Buildroot: aarch64
# has a nixpkgs binary cache.  Almost this entire closure is downloaded,
# not compiled — the opposite of the armv6l situation.
#
# The boot chain, which is the part that is genuinely board-specific:
# the H618 BROM reads an eGON header at 8 KiB into the SD card, so
# U-Boot's SPL is dd'd there (before the first partition, which the
# sd-image module leaves room for via firmwarePartitionOffset).  SPL
# loads TF-A's BL31 and U-Boot proper, U-Boot reads
# /boot/extlinux/extlinux.conf off the ext4 root, and boots the kernel
# with the FDT line that hardware.deviceTree.name produces.  No UEFI,
# no vendor firmware blob, no FAT boot partition — the FIRMWARE
# partition the module always creates stays empty here; it exists only
# for the Raspberry Pi family.
{
  pkgs,
  inputs,
  # The node to install, from ./node.nix.
  node,
  # The image filename, defined once in ./default.nix.
  imageFile,
  # Optional WiFi credentials.  The Zero 2W has NO ethernet port, so
  # without these the board comes up reachable only over the serial
  # console.  NOTE: a psk here lands in the world-readable Nix store —
  # fine for a bench instrument on a lab network, not for anything else.
  wifi ? null,
  # Extra SSH keys for root.  Preferred over the lab password below.
  authorizedKeys ? [ ],
  # Whether florestad starts itself at boot.
  #
  # FALSE by default, and that is the important default: ../harness
  # launches florestad ITSELF (see harness/remote/run-florestad.sh,
  # which detaches it with its own datadir and log).  A node already
  # running from boot would fight it for the datadir and for the
  # metrics port, which floresta hardcodes to 3333 — two florestads
  # means measurements that mean nothing.  So the service ships
  # configured and ready, but stopped: `systemctl start floresta` when
  # you want a node, the harness when you want numbers.
  #
  # Set true to turn this image into an appliance instead of an
  # instrument.
  autostart ? false,
}:

let
  inherit (pkgs) lib;

  # U-Boot for the H618.  nixpkgs ships ubootOrangePiZero2 (H616) and
  # ubootOrangePiZero3 (H618) but not the Zero 2W, so build the same
  # recipe against the defconfig mainline U-Boot does carry
  # (configs/orangepi_zero2w_defconfig, present in 2025.10).  BL31 comes
  # from the H616 TF-A: per linux-sunxi.org the H618 is a minor revision
  # of the H616 with a larger L2, and nixpkgs' own ubootOrangePiZero3
  # makes exactly this choice.
  uboot = pkgs.buildUBoot {
    defconfig = "orangepi_zero2w_defconfig";
    extraMeta.platforms = [ "aarch64-linux" ];
    BL31 = "${pkgs.armTrustedFirmwareAllwinnerH616}/bl31.bin";
    filesToInstall = [ "u-boot-sunxi-with-spl.bin" ];
  };

  # ---------------------------------------------------------------- lab
  # Board-agnostic: this is the ../florestaos candidate.
  #
  # mkDefault is used liberally here: the NixOS test driver in
  # ./system-test.nix layers its own VM profile on top of this module, and
  # a literal would collide with it at equal priority.
  lab = {
    imports = [ ../../lib/floresta-service.nix ];

    services = {
      floresta = {
        enable = true;
        package = node;
        network = "signet";
        dataDir = "/var/lib/floresta";
      };

      # The harness reaches the board over SSH and nothing else; see
      # ../harness/README.md.
      openssh = {
        enable = true;
        settings.PermitRootLogin = "yes";
      };

      # Measurements are worthless if the clock drifts.
      timesyncd.enable = lib.mkDefault true;
    };

    systemd.services.floresta.wantedBy = lib.mkIf (!autostart) (lib.mkForce [ ]);

    # Key auth only.  The known-password concession belongs to the
    # physical image, not here — see `board` below.  Keeping it out means
    # ../florestaos can adopt this module without inheriting a password.
    users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

    # 1-4 GB of LPDDR4 and an IBD that wants more: compressed swap buys
    # headroom without touching the card, whose write endurance is the
    # scarce resource in this lab.
    zramSwap = {
      enable = true;
      algorithm = "zstd";
    };

    # An instrument does not need manpages, and the SD card is small.
    documentation = {
      enable = lib.mkDefault false;
      nixos.enable = lib.mkDefault false;
    };

    system.stateVersion = "25.05";
  };

  # -------------------------------------------------------------- board
  # Allwinner H618 silicon and the SD image layout.
  board =
    { config, modulesPath, ... }:
    {
      imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

      nixpkgs.hostPlatform = "aarch64-linux";

      boot = {
        loader.grub.enable = false;
        loader.generic-extlinux-compatible.enable = true;

        # ttyS0 is the H618 UART0 on the 13-pin header; tty0 keeps HDMI
        # useful.  The board has no ethernet, so the serial console is
        # the only guaranteed way in on a first boot.
        kernelParams = [
          "console=ttyS0,115200n8"
          "console=tty0"
        ];
        consoleLogLevel = lib.mkDefault 7;
      };

      hardware = {
        # Makes the extlinux builder emit the `FDT` line U-Boot needs.
        # Without it U-Boot falls back to FDTDIR and can pick wrong.
        deviceTree.name = "allwinner/sun50i-h618-orangepi-zero2w.dtb";
        # The WiFi is the only network interface this board has.
        enableRedistributableFirmware = true;
      };

      networking.wireless = lib.mkIf (wifi != null) {
        enable = true;
        networks.${wifi.ssid}.psk = wifi.psk;
      };

      # Same deliberate choice as the Pi Zero image: this is a bench
      # INSTRUMENT on a lab network, not a node anyone should expose.  A
      # known password is what makes a freshly flashed card usable when
      # you have no serial cable and no ethernet port.  Pass
      # `authorizedKeys` and use those instead if you would rather not.
      users.users.root.initialPassword = lib.mkDefault "floresta";

      image.baseName = lib.removeSuffix ".img" imageFile;

      sdImage = {
        # sunxi puts no files on the FAT partition — U-Boot lives in the
        # gap before it and reads /boot off ext4.  The module creates the
        # partition regardless, so keep it minimal and empty.
        populateFirmwareCommands = "";
        firmwareSize = 16;

        populateRootCommands = ''
          mkdir -p ./files/boot
          ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
            -c ${config.system.build.toplevel} -d ./files/boot
        '';

        # The eGON header the BROM looks for, at 8 KiB.  bs=1024 seek=8
        # rather than bs=8k seek=1 to match how sunxi documents it.
        postBuildCommands = ''
          dd if=${uboot}/u-boot-sunxi-with-spl.bin of=$img \
            bs=1024 seek=8 conv=notrunc
        '';

        # Our flashers dd the file directly; a .zst would have to be
        # decompressed first.
        compressImage = false;
      };
    };

  nixos = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      lab
      board
    ];
  };

  sdImage = nixos.config.system.build.sdImage;
in
{
  # Exposed so ../florestaos can take `lab` verbatim when the time comes,
  # and so ./system-test.nix can boot it without the SD image.
  modules = { inherit lab board; };

  inherit uboot nixos;
  inherit (nixos.config.system.build) toplevel;

  # The sd-image module leaves the image at $out/sd-image/<name>.img.
  # Re-expose it at $out/<imageFile> so this board honours the same
  # contract as every other one: the shared flasher and QEMU runner read
  # `meta.image.file` from the root of the output.
  image = pkgs.runCommand "floresta-orange-pi-zero-2-W-sd-image" { } ''
    mkdir -p $out
    ln -s ${sdImage}/${nixos.config.image.filePath} $out/${imageFile}
    (cd $out && sha256sum ${imageFile} > SHA256SUMS)
  '';
}
