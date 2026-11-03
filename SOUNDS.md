# Portal sound library

The admin page **Hotspot → Portal** has a **Library** button on each audio row. It
opens a pop-up window listing the sounds published in this repository: press **▶ Play** to hear one,
then **Use** to install it on the router. Uploading your own file still works exactly
as before.

The library has its **own manifest, `sounds.txt`** — separate from `manifest.txt`
(base OTA) and `modules.txt` (modules). Adding a sound is a normal commit; it needs
no release and no firmware or module update.

## Slots — kept separate

Every sound belongs to exactly one slot, and a slot's picker shows only its own sounds:

| Slot (`sounds/<slot>/`) | Admin row | Behaviour on the portal |
|---|---|---|
| `bg_music` | Background Music | loops when the portal opens |
| `insert_bg_music` | Insert Coin Music | loops only while the insert-coin window is open |
| `coin_sound` | Coin Count Sound | plays once each time a coin registers |

Background music and coin sounds are never offered in each other's picker.

## Adding a sound

1. Drop the file into `sounds/<slot>/`. File names: lowercase `a-z`, `0-9`, `_`, `-`;
   extension `.mp3`, `.ogg` or `.wav`.
2. *(Optional)* give it a display name in `sounds/names.txt`:
   `coin_sound/my_chime=My chime|Soft two-tone ding`. Without a line, the file name is
   used (`my_chime` → "My chime").
3. Run `sh sounds_manifest.sh` and commit `sounds/` together with the regenerated
   `sounds.txt`. (`sh sounds_manifest.sh --check` verifies it is up to date; release CI
   regenerates it too, so it cannot go stale at release time.)

**Never replace a sound's contents under the same file name.** The CDN caches files for
hours, so a router could fetch the old bytes and fail the checksum against the new
`sounds.txt`. Add a new file name instead.

Only add audio you have the right to redistribute — this repository is public and
AGPLv3 does not cover third-party media.

## `sounds.txt` format

Same `key=value` blocks as `modules.txt`, one blank line between sounds. It is generated;
this is what the router reads:

```
id=default_coin
slot=coin_sound
name=Default coin sound
file=coin_sound/default_coin.mp3
size=18852
sha256=<64 hex characters>
description=The chime the portal ships with
```

## How the router uses it (`hotspot/sound_ctl.sh`)

- **Catalog** — `sounds.txt` is fetched through the jsDelivr CDN (the same host and TLS
  settings the OTA uses) and cached in RAM for 10 minutes. **Refresh** forces a refetch;
  if the router is offline it shows the last copy it had.
- **Use** — the file is downloaded to RAM, its `sha256` is checked against `sounds.txt`,
  and only then is it written to `hotspot/audio/<slot>.<ext>` — the same place an upload
  lands, so the portal, `portal_config.sh` and the OTA `PRESERVE` list need no changes.
  The previous file for that slot is replaced; a mismatch, a failed download or a full
  disk leaves it untouched. The router keeps 3 MB free, as for uploads; one sound can be
  at most 8 MB.
- **Which sound is active** is not stored anywhere: the catalog marks the entry whose
  `sha256` equals the installed file's. Uploading or removing a file afterwards simply
  makes the library show "Use" again.
- The manifest holds **no URLs**. Download URLs are built from the repo/branch in
  `ota.env` plus a validated `<slot>/<name>.<ext>` path, so a bad entry can't point a
  router outside this repository.
- **Preview** plays straight from the CDN in the admin's browser, so that browser needs
  internet access (the router's own downloads don't depend on it).

Library files live in `sounds/` at the repo root, so they are not part of the base or
hotspot release tarballs.
