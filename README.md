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

- `sch/sch_fq_codel.ko` — the Linux kernel's Fair Queue CoDel packet
  scheduler, built as a loadable module for the device's 4.4.140 kernel,
  retains its original GPL-2.0-or-later license. See `sch/LICENSE` and
  `LICENSES/GPL-2.0-or-later.txt`.

- `iptables/xt_hl.ko` and `iptables/xt_HL.ko` — the Linux kernel's Netfilter
  TTL/hop-limit match and target modules, built for the same kernel, retain
  their original GPL-2.0-only license. See `iptables/LICENSE` and
  `LICENSES/GPL-2.0-only.txt`.

- `hotspot/firmware/coin_nodemcu.bin` — the compiled NodeMCU firmware. The
  sketch (`hotspot/nodemcucodeholder`) is AGPLv3, but the image also contains
  the ESP8266 Arduino core and its libraries (LGPL-2.1-or-later, BSD-3-Clause
  and others). See `hotspot/firmware/LICENSE`.

- Vendored web assets — Bootstrap, jQuery, toastr and xterm.js (MIT), the
  Nunito font (OFL-1.1) — and `www2/sh/cacert.pem` (Mozilla CA bundle,
  MPL-2.0). See `THIRD_PARTY_NOTICES.md`.

These components are separate works that are loaded or run alongside the
AGPLv3 code (the kernel modules are `insmod`-ed on demand by `lmehspt.sh`);
being shipped in this repository or in the release tarballs does not
relicense them. The kernel modules were built for the vendor's GPLv2 kernel
source release (see "GPLv2 dump status" below); the written source offer is
in `sch/LICENSE` and `iptables/LICENSE`.

## Forking, redistribution, and attribution

Every first-party source file (everything not listed above) carries an
SPDX header and
a short AGPLv3 reminder. If you fork this project, white-label it for
your own deployment, or feed it through an LLM to restyle it, the
AGPLv3 terms still apply to the result — see `PROVENANCE.md` for what
that means in practice and `AUTHORS` for the canonical attribution
record. Short version: keep the license and notices, say what you
changed, and if you run a modified version as a network service, make
your Corresponding Source available to your users (AGPLv3 §5, §13).

## LLMs used to make the project

- Claude (Sonnet & Opus series, mainly Sonnet was used due to not having claude code, or the paid plans.)
- Gemini (3.8 Flash)

# The purpose:
- Repurpose capable/second hand realtek gpon onus a general wifi router (and also can be used as a wifi hotspot system)

# Note
- Hotspot feature is free to use, compared to other router based wifi hotspot system firmwares that use openwrt.

# GPLv2 dump status:
- The vendor Prolink2u (Fida International (S) Pte Ltd.) responded with the GPLv2 dump.

****
# Donate: 
https://buymeacoffee.com/lmepisowifi
