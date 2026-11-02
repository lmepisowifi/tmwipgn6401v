/*
 * lmepisowifi — https://github.com/lmepisowifi/tmwipgn6401v
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
 *
 * Licensed under the GNU AGPLv3 (see LICENSE). Modifying or rewriting this
 * file — including by running it through an LLM — does not remove these
 * obligations: keep this notice, mark your changes, and offer Corresponding
 * Source to network users (AGPLv3 §5, §13). See PROVENANCE.md before
 * presenting this as your own original work.
 */

/*
 * Light / dark colour mode for the admin pages (www2).
 *
 * Load this from <head> on every page, BEFORE the body is parsed, so a saved
 * "light" choice is applied before first paint and the page never flashes dark.
 *
 * The mode is the `data-bs-theme` attribute on <html> ("dark" is the default
 * written into every page; "light" is the alternative). css/style.css keys
 * its colour variables off that attribute and Bootstrap 5.3 follows it too.
 *
 * The choice is remembered per browser in localStorage. It is deliberately NOT
 * stored on the device: it is a display preference of whoever is looking at
 * the page, and the portal's own light/dark mode is a separate thing.
 *
 * API (window.lmeTheme):
 *   get()            -> "light" | "dark"
 *   set(mode)        -> apply + remember
 *   toggle()         -> flip + remember, returns the new mode
 *   createButton()   -> a ready-made toggle <button> that keeps itself in sync
 *
 * Event: "lme:themechange" is fired on document after every change
 * (event.detail.theme), so pages that draw with JS (canvas) can redraw.
 */
(function () {
    'use strict';

    var KEY  = 'lme_theme';
    var root = document.documentElement;

    // Feather-style icons, stroke = currentColor so they follow the button colour.
    var ICON_SUN =
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<circle cx="12" cy="12" r="4"/>' +
        '<path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/>' +
        '</svg>';
    var ICON_MOON =
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>' +
        '</svg>';

    function normalise(m) { return m === 'light' ? 'light' : 'dark'; }

    function readSaved() {
        try { return localStorage.getItem(KEY); } catch (e) { return null; }
    }

    function writeSaved(m) {
        try { localStorage.setItem(KEY, m); } catch (e) { /* private mode etc: session-only */ }
    }

    function get() { return normalise(root.getAttribute('data-bs-theme')); }

    function paint(m) {
        root.setAttribute('data-bs-theme', m);
    }

    function announce(m) {
        try {
            document.dispatchEvent(new CustomEvent('lme:themechange', { detail: { theme: m } }));
        } catch (e) { /* very old browser: nothing is listening that matters */ }
    }

    function set(mode) {
        var m = normalise(mode);
        var changed = (m !== get());
        paint(m);
        writeSaved(m);
        if (changed) announce(m);
        return m;
    }

    function toggle() { return set(get() === 'light' ? 'dark' : 'light'); }

    // The button shows the mode you would SWITCH TO (sun while dark, moon while light).
    function createButton() {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'lme-theme-btn';

        function sync() {
            var toLight = (get() !== 'light');
            var label = toLight ? 'Switch to light theme' : 'Switch to dark theme';
            b.innerHTML = toLight ? ICON_SUN : ICON_MOON;
            b.title = label;
            b.setAttribute('aria-label', label);
        }

        b.addEventListener('click', function () { toggle(); });
        document.addEventListener('lme:themechange', sync);
        sync();
        return b;
    }

    // Apply the saved choice right now (this script runs in <head>).
    paint(normalise(readSaved() || get()));

    // Keep other open tabs/pages in step when the choice is changed elsewhere.
    window.addEventListener('storage', function (e) {
        if (e.key !== KEY) return;
        var m = normalise(e.newValue);
        if (m !== get()) { paint(m); announce(m); }
    });

    window.lmeTheme = { get: get, set: set, toggle: toggle, createButton: createButton };
})();
