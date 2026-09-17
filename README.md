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

## Forking, redistribution, and attribution

Every source file (with the exceptions above) carries an SPDX header and
a short AGPLv3 reminder. If you fork this project, white-label it for
your own deployment, or feed it through an LLM to restyle it, the
AGPLv3 terms still apply to the result — see `PROVENANCE.md` for what
that means in practice and `AUTHORS` for the canonical attribution
record. Short version: keep the license and notices, say what you
changed, and if you run a modified version as a network service, make
your Corresponding Source available to your users (AGPLv3 §5, §13).

## LLM's used to make the project

- Claude (Sonnet & Opus series, mainly Sonnet was used due to not having claude code, or the paid plans.)
- Gemini (3.8 Flash)

# The purpose:
- Repurpose capable/second hand realtek gpon onus a general wifi router (and also can be used as a wifi hotspot system)

# Note
- Hotspot feature is free to use, compared to other router based wifi hotspot system firmwares that use openwrt.
****
Donate: 
https://buymeacoffee.com/lmepisowifi
