Floresta Pi Zero bench lab
==========================

This card was flashed from the floresta-nix `pi0-sd-image` output.

* florestaos.conf   -- edit from any OS, then boot the Pi with it.
* results/          -- CSV samples and boot logs land here; copy them
                       off by plugging the card into any computer.
* config.txt        -- Raspberry Pi firmware config (leave alone unless
                       you know why).

The Pi appears as a USB network device on the machine powering it.
Default addresses: Pi 10.7.0.2, host side 10.7.0.1.
  ssh root@10.7.0.2      (password: floresta)

To re-flash without removing this card, run on the Pi:
  florestaos reflash     (destroys everything on the card!)
then on the host: nix run .#flash-pi0

Full documentation: pi0/README.md in the floresta-nix repository.
