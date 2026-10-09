# wlanapply

Restart **one radio, or one SSID**, of the vendor WLAN pipeline instead of everything.

`wlan_apply restart` is `config_WLAN(ACT_RESTART, CONFIG_SSID_ALL)`: it stops and starts
both radios and every SSID. `config_WLAN()` already takes a band and an SSID index, and the
vendor UI uses that per SSID, but the stock CLI never exposes it. `wlanapply` calls it from
its own process, resolving everything from `libmib.so` with `dlopen`/`dlsym` (like `wanapply`),
so it needs no vendor headers and works on any build of the SoC.

```
wlanapply check                                  # load libmib, resolve config_WLAN; changes nothing
wlanapply restart <2g|5g> <idx|all|root> [-n]
wlanapply stop    <2g|5g> <idx|all|root> [-n]
wlanapply start   <2g|5g> <idx|all|root> [-n]
```

`idx` 1..4 = `wlanN-vap0..3`, 5 = `wlanN-vxd`. `all`, `root` and `0` mean the whole band: the
VAPs hang off the root interface, so (as the vendor does in `checkWlanRootChange`) a root or
radio-level change restarts that band's SSIDs, never a root-only restart that would leave the
VAPs behind. `-n` validates and prints the `config_WLAN()` call without making it.

Exit: 0 ok, 2 usage, 3 libmib/symbol, 8 `config_WLAN` returned an error, 75 another run holds the lock.

## What a restart touches
`stopwlan(band, idx)`: kill that interface's `auth`/`wscd` (only 802.1X uses `auth`), `ifconfig <if> down`,
`brctl delif`. `startWLan(band, idx)`: `setupWLan(idx)` pushes that MIB record into the driver, then
`ifconfig up` + `brctl addif`. The shared `iwcontrol` event relay is bounced briefly. The other band,
and other SSIDs on the same band, keep running. It reads the MIB like `wlan_apply` does, so run
`mib set` + `mib commit` first.

## Build
```
TC=/path/to/msdk-4.8.5-mips-EB-4.4-g2.23-m32ut-190619-cmcc ./wlanapply_build.sh
cp wlanapply ../../www2/tool/wlanapply
```
Result is a MIPS32r2 big-endian ELF needing only `libdl` + `libc`.

## Used by
`wlanbasic.cgi`, `wlanadvanced.cgi` ("Apply live"): `iwpriv set_mib` for what the driver can take at runtime,
`wlanapply` for everything else, and the stock `wlan_apply restart` only if this helper is missing or fails.
