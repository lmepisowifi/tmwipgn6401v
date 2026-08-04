
# The modded web interface for the PGN6401V (RTL9607C)
****
## Licensing

This project is licensed under AGPLv3 (see `LICENSE`), except:

- `httpd.c` — derived from BusyBox, retains its original
  GPLv2-or-later license. See the file header and
  `LICENSES/GPL-2.0-or-later.txt`.

- `tailscale/tailscaled-small` and `tailscale/tailscale-small` — the Tailscale
  daemon + CLI, built from Tailscale
  (https://github.com/tailscale/tailscale), retain their original
  BSD-3-Clause license. See `tailscale/LICENSE` and
  `LICENSES/BSD-3-Clause.txt`. These ship only inside the optional
  `tailscale` www2 module, not the base image.
