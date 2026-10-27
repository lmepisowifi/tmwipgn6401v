# Third-party components

This project's own code is AGPL-3.0-or-later (see `LICENSE`). The components
below are **not** covered by that license: each keeps its original license,
and shipping it here or in a release tarball does not relicense it. License
texts are in `LICENSES/`.

| Component | Path | SPDX license | Copyright / upstream |
|---|---|---|---|
| BusyBox httpd | `httpd.c` | GPL-2.0-or-later | Glenn Engel, Vladimir Oleynik, BusyBox contributors |
| Tailscale daemon + CLI | `tailscale/tailscaled-small`, `tailscale/tailscale-small` | BSD-3-Clause | Tailscale Inc & contributors, https://github.com/tailscale/tailscale |
| Fair Queue CoDel scheduler (kernel module) | `sch/sch_fq_codel.ko` | GPL-2.0-or-later | Eric Dumazet; CoDel code by Kathleen Nichols, Van Jacobson, Michael D. Taht (Linux kernel) |
| CAKE scheduler (kernel module, backport to the vendor's 4.4.140 kernel) | `sch/sch_cake.ko` | BSD-3-Clause OR GPL-2.0-only (used under GPL-2.0) | Jonathan Morton and the CAKE contributors (Linux net/sched/sch_cake.c) |
| iproute2 `tc` (userspace, with CAKE support) | `sch/tc` | GPL-2.0-only (iproute2 as a whole; per-file headers vary) | Alexey Kuznetsov, Stephen Hemminger and iproute2 contributors, https://git.kernel.org/pub/scm/network/iproute2/iproute2.git |
| Xtables TTL/HL match + target (kernel modules) | `iptables/xt_hl.ko`, `iptables/xt_HL.ko` | GPL-2.0-only | Harald Welte, Maciej Soltysiak (Linux kernel) |
| ESP8266 Arduino core and libraries inside the NodeMCU image | `hotspot/firmware/coin_nodemcu.bin` | LGPL-2.1-or-later (core), BSD-3-Clause (LittleFS, lwIP), Espressif terms (NONOS SDK libs) | https://github.com/esp8266/Arduino |
| Bootstrap 5.3.0 | `www2/css/bootstrap.min.css`, `www2/js/bootstrap.bundle.min.js`, `hotspot/css/bootstrap.min.css` | MIT | The Bootstrap Authors |
| jQuery 3.7.1 | `www2/js/jquery-3.7.1.min.js`, `hotspot/js/jquery.min.js` | MIT | OpenJS Foundation and contributors |
| toastr 2.1.3 | `www2/js/toastr.min.js`, `www2/css/toastr.min.css`, `hotspot/js/toastr.min.js`, `hotspot/css/toastr.min.css` | MIT | John Papa, Hans Fjällemark, Tim Ferrell |
| xterm.js + fit and web-links addons | `www2/js/xterm*.js`, `www2/css/xterm.css` | MIT | The xterm.js authors; Christopher Jeffrey (term.js) |
| Nunito Variable 3.602 (font) | `www2/graphics/Nunito.woff*`, `hotspot/graphics/Nunito.woff*` | OFL-1.1 | The Nunito Project Authors |
| Mozilla CA certificate store extract | `www2/sh/cacert.pem` | MPL-2.0 | Mozilla |

## Notes

**Kernel modules.** `sch_fq_codel.ko`, `sch_cake.ko`, `xt_hl.ko` and `xt_HL.ko`
are built for the vendor's Linux 4.4.140 kernel (MIPS32r2, big-endian) and are
loaded on demand by `lmehspt.sh` with `insmod`. They are separate works shipped
alongside the AGPLv3 scripts, not combined with them. Because GPL-2.0-only and
AGPL-3.0 can't be merged into a single work, keep it that way: no AGPLv3 code
should be compiled into, or linked against, these modules. Their written
source offers are in `sch/LICENSE` and `iptables/LICENSE`.

**`sch/tc`.** A standalone iproute2 executable (same architecture), run by
`lmehspt.sh` only when the firmware's own `tc` cannot create a CAKE qdisc. It
is never linked with or loaded into anything else. Its source offer is in
`sch/LICENSE`.

**Per-directory notices.** Compiled artifacts can't carry a header, so each
shipped directory carries its own notice (`sch/LICENSE`, `iptables/LICENSE`,
`tailscale/LICENSE`, `hotspot/firmware/LICENSE`, `www2/THIRD_PARTY_NOTICES.txt`,
`hotspot/THIRD_PARTY_NOTICES.txt`). Those directories are what the release
tarballs and OTA updater ship, so the notices travel with the binaries.

**Tailscale.** The binaries statically link Go dependencies that carry their
own notices; see the Tailscale source at the version they were built from.
