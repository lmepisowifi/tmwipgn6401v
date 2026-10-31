<!--
  lmepisowifi — https://github.com/lmepisowifi/tmwipgn6401v
  SPDX-License-Identifier: AGPL-3.0-or-later
  Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
-->
# Portal themes

A **theme** is a ready-made look for the customer captive portal (`hotspot/index.html`).
The operator picks one in **www2 > Hotspot > Portal > Theme**, with a live preview of the real
portal before anything goes live. A theme only restyles the page: the markup, the coin /
voucher / login logic and the operator's own title, logo, carousel images, audio and footer
text are the same in every theme.

Shipped themes:

| id               | Look                                                                                  |
|------------------|---------------------------------------------------------------------------------------|
| `default`        | The built-in lmepisowifi look (no stylesheet; selecting it removes the choice).       |
| `banner-classic` | Title bar over a full-width banner, striped time bar, a "Session Info" card, big blue Insert Coin and green voucher buttons. Light and dark. |

> **Renamed.** Releases up to 1.5.70 shipped this theme under a different id (`pisofi`). A device
> that had it selected keeps the look: the old id is mapped to `banner-classic` automatically.
> Custom CSS that targets the old id, `html[data-lme-theme="pisofi"]`, has to be changed to
> `html[data-lme-theme="banner-classic"]`.

## How it works

```
hotspot/themes/<id>/theme.info   name, blurb, swatch colours (shown in the admin picker)
hotspot/themes/<id>/theme.css    the stylesheet (not needed for "default")
hotspot_data/portal_theme        one line: the chosen id   (survives OTA; absent = default)
hotspot/cgi-bin/portal_theme.sh  serves the chosen theme.css  (also ?id=<id>, used by the preview)
```

* `index.html` loads the theme as its **own `<link>`**, after the stock `<style>` and before the
  operator's Custom CSS. A theme therefore cannot break the stock stylesheet, and Custom CSS can
  still tweak a theme (see "Custom CSS on top of a theme" below).
* The choice is **not** stored in `portal.env`: `portal_set` and the logo upload rewrite that file
  from scratch, which would silently reset it.
* `hotspot/` is replaced by every OTA / module install, `hotspot_data/` is not. Themes that ship
  with a release are refreshed by the update; **a theme you copy onto a device by hand is lost
  on the next OTA** unless it is also in the repository (send a pull request, or re-copy it).
* The page tags `<html data-lme-theme="<id>">` (the saved theme, or `default`), so Custom CSS can
  target one theme: `html[data-lme-theme="banner-classic"] .btn { ... }`. `<html data-theme="dark|light">`
  is the portal's own colour mode.

### Safety net

The portal checks itself on customers' phones, exactly as it does for Custom CSS. If, on two checks
in a row, the voucher box, Insert Coin, Resume, the voucher Submit button, a pop-up window or its
buttons are hidden, shrunk, pushed off-screen, covered, see-through or unreadable, the stylesheet is
switched off for that visit (Custom CSS first, if there is any, then the theme) and the stock look
is shown. The admin **Check all screens** button and **Use this theme** run the same check over
Login, Connected, Rates and Coin before a theme goes live.

### Trying a theme without changing anything

Open the portal address with `?theme=<id>` (any installed theme) or `?notheme=1` (stock look).
Nothing is saved. A visit where the safety net switched a theme off stays on the stock look, even
with `?theme=`, until that browser tab is closed.

## Adding a theme

1. Create `hotspot/themes/<id>/`. The id is 1–32 characters of `a-z 0-9 _ -`.
2. Add `theme.info` (plain `key=value` lines, `#` starts a comment):

   | key           | meaning                                                                       |
   |---------------|-------------------------------------------------------------------------------|
   | `name`        | shown on the picker card (40 characters)                                       |
   | `description` | one or two sentences (240 characters)                                          |
   | `author`      | optional                                                                      |
   | `license`     | optional, e.g. `AGPL-3.0-or-later`                                             |
   | `swatch`      | up to four `#rgb` / `#rrggbb` colours, comma separated, for the card preview   |

3. Add `theme.css`. A folder with `theme.info` but no `theme.css` (or the other way round) is not
   offered in the admin picker, so a half-copied theme never shows up broken.
4. Open the admin page, click the new card, step through **Login / Connected / Rates / Coin** in
   both **Dark** and **Light**, then press **Check all screens**.

No build step, no registration: the picker lists whatever is in `hotspot/themes/`.

## Writing `theme.css`

The stock portal is styled with CSS variables plus a good number of `!important` rules, and it has
two colour modes. The rules below are what makes a theme behave.

* **Beat the stock `!important` with specificity.** Prefix selectors with `html body`
  (`html body .btn { ... !important }`) so they out-rank the stock rules; a plain `.btn` loses.
* **Set colour variables for both modes.** The stock sheet defines them in `:root` (dark) and in
  `:root[data-theme="light"]`, and the second selector outranks a plain `:root`. Put variables that
  are the same in both modes under `:root, :root[data-theme="dark"], :root[data-theme="light"]`,
  then the rest under each mode on its own. Variable names are listed in the admin
  *Custom CSS > Tips* box (`--bg-body`, `--bg-surface`, `--btn-primary-*`, `--btn-coin-*`,
  `--btn-rates-*`, `--btn-danger-*`, `--coin-sym-color`, ...).
* **Never hide, shrink or cover a control a customer needs.** No `display:none` on the voucher
  box, Insert Coin, Resume, Submit or the pop-up buttons; no `position:fixed` / `sticky` bars
  (they can sit on top of a button once the page is scrolled: an absolutely positioned header is
  fine). The safety net will switch the theme off if you do, and your customers will see the
  stock look.
* **Degrade gracefully.** If a fancy layout (grid overlays, `:has()`, `content:url()` icons) is
  not supported by an old phone browser, the result should still be the stock flow, not a broken
  one.
* **Keep the AGPL "Source" link in the footer visible** (AGPLv3 §13: users interacting with the
  portal over the network must be offered the source).
* **Local files only.** `url(/img/promo1.png)`, `url(/img/portal_logo.png)` or inline `data:` URIs.
  No `@import`, no web fonts, nothing on the internet: customers are not online yet, so an
  external file would stall the portal. Use a system font stack.
* **Keep it small.** The theme is fetched on every portal load (it is deliberately not cached: it
  is served from one URL whatever theme is selected, so a stale copy must never be possible). The
  Banner Classic theme is ~18 KB; staying well under ~30 KB keeps the first paint quick on a weak
  hotspot link.
* **Test both modes, narrow and wide**: 320 px phones matter, and long portal titles must not
  push buttons off-screen.

Useful hooks (all present in `hotspot/index.html`): `.portal-wrap`, `.portal-card`,
`.portal-header` (`.portal-title`, `.portal-brand`, `.portal-signal`, `.theme-toggle-btn`,
`.speaker-toggle-btn`), `.promo-wrap` / `.promo-slide-wrapper` / `.promo-arrow` / `.promo-dot`,
`.view-title`, `.view-subtitle`, `#v-login`, `#v-status`, `.progress-wrap` / `.progress-fill`
(its fill colour is an inline `background:` shorthand, so a stripe needs
`background-image: ... !important`), `.session-info` / `.session-row` (`.sk` label, `.sv` value),
`#btn-coin-login`, `#btn-resume`, `#btn-pause`, `.btn-rates`, `.input-group`, `.form-control`,
`.rates-modal-overlay`, `.coin-modal-overlay` (both get `.open` while visible), `.coin-bar-fill`,
`.portal-footer`.

### Custom CSS on top of a theme

Custom CSS loads after the theme, so colour variables set there win as usual. A rule such as
`.btn { border-radius: 24px !important }` can lose against a theme that styles buttons with
`html body .btn { ... !important }`; give your rule the same `html body` prefix.

## Licensing and provenance

Themes are first-party source files like any other: keep the SPDX header and the AGPLv3 notice
(see `PROVENANCE.md`). If a theme takes inspiration from the *look* of another system, write it
from scratch — **do not copy another system's CSS, JavaScript, images, fonts or logos** into this
repository, and **do not use its name or branding** in a theme's id, name, description or comments
(names and logos are trademarks, and a theme must not suggest it comes from, or is endorsed by,
someone else). The shipped `banner-classic` theme is written from scratch, uses the common
Bootstrap 4 colour palette, ships no third-party CSS, JavaScript, fonts or artwork, and is not
affiliated with or endorsed by any other captive-portal system.
