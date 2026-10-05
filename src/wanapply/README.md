# wanapply

Live-apply helper for the WAN profile page (`www2/wan-profile.html`).
`mib set` + `mib commit` only edit configd's copy of `ATM_VC_TBL`; the stock web
UI then calls `deleteConnection()` / `restartWAN()` inside boa to create or tear
down `nas0_N`, the smux rules, dhcp/ppp and NAT. Both are exported by
`libmib.so`, so this small program calls them from its own process, the same
way the vendor `cli` does.

- `wanapply check` — resolve libmib symbols and the `ATM_VC_TBL` chain; changes nothing
- `wanapply stop <idx> [--expect-ifindex N]` — tear down using the *current* record (run before editing it)
- `wanapply start <idx> [--expect-ifindex N] [--no-firewall]` — `restartWAN(CONFIGONE, record)`, then `/bin/firewall.sh`
- `wanapply refresh` / `wanapply all` — `restartWAN(CONFIGONE, NULL)` / `restartWAN(CONFIGALL, NULL)`

It never touches the layout of `MIB_CE_ATM_VC_T`: the record is read into an
opaque buffer sized from the chain table and passed straight back, and every
libmib symbol is `dlsym()`ed, so one binary serves any build of this SoC.

Build with the Realtek msdk toolchain (glibc 2.23, MIPS32 big-endian):

    TC=/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc ./build.sh
    cp wanapply ../../www2/sh/wanapply

Needs `libdl.so.2` and `libc.so.6` on the device. `restartWAN()` flushes
iptables/ebtables/nat, so `wan-profile.cgi` re-asserts the rules the rest of
lmepisowifi owns afterwards (`reassert_rules()`).
