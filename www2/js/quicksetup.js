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
 * quicksetup.js — the "Quick Setup" wizard (opened from the navbar by nav.js)
 *
 *   Router            Internet source -> WAN connection -> LAN + DHCP -> WiFi -> Review
 *   Bridge / AP       Internet source -> Bridge WAN      -> LAN (static / DHCP client) -> WiFi -> Review
 *   WiFi extender     LAN (static / DHCP client) -> WiFi -> Upstream network -> Review
 *
 * Every answer is kept in memory (S). NOTHING is sent to the device until the
 * user presses "Apply" on the review page, and then it is one POST to
 * /cgi-bin/quicksetup.cgi?action=apply. The backend validates it all again and
 * runs the change as a detached job (LAN/WiFi changes drop this very
 * connection), which this file then follows via ?action=status.
 */
(function () {
    'use strict';
    if (window.lmeQuickSetup) return;

    var QS = '/cgi-bin/quicksetup.cgi';

    // ── state ────────────────────────────────────────────────────────────────
    var S = null;          // wizard state, rebuilt on every open()
    var modal = null;      // bootstrap.Modal
    var el = {};           // cached DOM nodes
    var pollTimer = null, probeTimer = null, applying = false;

    var STEP_LABEL = {
        mode: 'Setup type', upstream: 'Internet source', wan: 'WAN connection', lan: 'LAN',
        wifi: 'WiFi', uplink: 'Upstream WiFi', review: 'Review'
    };
    var FLOWS = {
        router:   ['mode', 'upstream', 'wan', 'lan', 'wifi', 'review'],
        ap:       ['mode', 'upstream', 'wan', 'lan', 'wifi', 'review'],
        extender: ['mode', 'lan', 'wifi', 'uplink', 'review']
    };
    var MASKS = ['255.0.0.0', '255.255.0.0', '255.255.254.0', '255.255.255.0', '255.255.255.128',
                 '255.255.255.192', '255.255.255.224', '255.255.255.240'];
    var LEASES = [[1800, '30 minutes'], [3600, '1 hour'], [43200, '12 hours'], [86400, '1 day'], [604800, '1 week']];
    var SECS = [['wpa2', 'WPA2-PSK (recommended)'], ['wpa2wpa3', 'WPA2/WPA3 mixed'], ['wpa3', 'WPA3 only'], ['open', 'Open (no password)']];
    var UP_SECS = [['wpa2', 'WPA2-PSK'], ['wpa2wpa3', 'WPA2/WPA3'], ['wpa3', 'WPA3'], ['wpa', 'WPA'], ['wpa12', 'WPA/WPA2'], ['open', 'Open (no password)']];
    // MIB encrypt / cipher codes (same mapping as sitesurvey.html's mapEnc)
    var ENC = {
        open: { enc: 0, uc: 0, u2c: 2 }, wpa: { enc: 2, uc: 3, u2c: 2 }, wpa12: { enc: 6, uc: 3, u2c: 2 },
        wpa2: { enc: 4, uc: 0, u2c: 2 }, wpa2wpa3: { enc: 20, uc: 0, u2c: 2 }, wpa3: { enc: 16, uc: 0, u2c: 2 }
    };
    // itfGroup bits (see wan-profile.html): LAN1-4, wlan0 (5 GHz) + 4 VAPs, wlan1 (2.4 GHz) + 4 VAPs
    var BIND_GROUPS = [
        { title: 'LAN ports', items: [[0, 'LAN 1'], [1, 'LAN 2'], [2, 'LAN 3'], [3, 'LAN 4']] },
        { title: '5 GHz WiFi', items: [[4, 'Main'], [5, 'Guest 1'], [6, 'Guest 2'], [7, 'Guest 3'], [8, 'Guest 4']] },
        { title: '2.4 GHz WiFi', items: [[9, 'Main'], [10, 'Guest 1'], [11, 'Guest 2'], [12, 'Guest 3'], [13, 'Guest 4']] }
    ];
    var BIND_ALL = 16383;

    // ── small helpers ────────────────────────────────────────────────────────
    function esc(s) {
        return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/"/g, '&quot;')
            .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/'/g, '&#39;');
    }
    function $(id) { return document.getElementById(id); }
    function getp(path) {
        var o = S, p = path.split('.');
        for (var i = 0; i < p.length; i++) { if (o == null) return undefined; o = o[p[i]]; }
        return o;
    }
    function setp(path, v) {
        var o = S, p = path.split('.');
        for (var i = 0; i < p.length - 1; i++) o = o[p[i]];
        o[p[p.length - 1]] = v;
    }
    function bytes(s) { return unescape(encodeURIComponent(String(s))).length; }
    function ipNum(s) {
        var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(s || '').trim());
        if (!m) return -1;
        for (var i = 1; i <= 4; i++) if (+m[i] > 255) return -1;
        return ((+m[1] * 256 + +m[2]) * 256 + +m[3]) * 256 + +m[4];
    }
    function numIp(n) { return [Math.floor(n / 16777216) % 256, Math.floor(n / 65536) % 256, Math.floor(n / 256) % 256, n % 256].join('.'); }
    function isIp(s) { return ipNum(s) >= 0; }
    function maskSize(m) {
        var n = ipNum(m); if (n <= 0) return -1;
        var size = 4294967296 - n, p = 1;
        while (p < size) p *= 2;
        return p === size ? size : -1;
    }
    function subnetOf(ip, mask) {
        var x = ipNum(ip), sz = maskSize(mask);
        if (x < 0 || sz < 0) return null;
        var net = x - (x % sz);
        return { net: net, bc: net + sz - 1, size: sz };
    }
    function api(path, opts) {
        return fetch(path, Object.assign({ cache: 'no-store', credentials: 'same-origin' }, opts || {}))
            .then(function (r) {
                return r.text().then(function (t) {
                    var j = null;
                    try { j = JSON.parse(t); } catch (e) {}
                    if (j === null) {
                        // an HTML login page instead of JSON = the session ended
                        if (/login/i.test(t) || r.redirected) { window.location.href = '/login.html'; }
                        throw new Error('Unexpected reply from the device (HTTP ' + r.status + ').');
                    }
                    return j;
                });
            });
    }

    // ── styles + modal shell (built once) ────────────────────────────────────
    function ensureShell() {
        if ($('qsModal')) return;
        var st = document.createElement('style');
        st.textContent =
            '#qsModal .qs-sub{font-size:11px;color:var(--text-secondary)}' +
            '#qsModal .qs-dots{display:flex;gap:6px;margin:0 0 14px}' +
            '#qsModal .qs-dot{height:4px;flex:1;border-radius:2px;background:var(--border-color)}' +
            '#qsModal .qs-dot.on{background:var(--accent-color)}' +
            '#qsModal .qs-card{display:block;border:1px solid var(--border-color);border-radius:8px;padding:12px 14px;margin-bottom:10px;cursor:pointer;background:var(--bg-surface);transition:border-color .12s,background .12s}' +
            '#qsModal .qs-card:hover{background:var(--bg-surface-hover)}' +
            '#qsModal .qs-card.sel{border-color:var(--accent-color);background:var(--bg-surface-hover)}' +
            '#qsModal .qs-card.dis{opacity:.5;cursor:not-allowed}' +
            '#qsModal .qs-card input[type=radio]{margin-right:10px}' +
            '#qsModal .qs-card .qs-t{font-weight:600;font-size:14px}' +
            '#qsModal .qs-card .qs-d{font-size:12px;color:var(--text-secondary);margin:4px 0 0 26px}' +
            '#qsModal .qs-hint{font-size:11.5px;color:var(--text-secondary);margin-top:4px}' +
            '#qsModal label.qs-l{font-size:12px;color:var(--text-secondary);margin-bottom:3px;display:block}' +
            '#qsModal .qs-box{border:1px solid var(--border-color);border-radius:8px;padding:12px 14px;margin-bottom:12px;background:var(--bg-surface)}' +
            '#qsModal .qs-box h6{font-size:13px;margin:0 0 10px;font-weight:600}' +
            '#qsModal .qs-warn{border:1px solid var(--lme-warn-border,#6b5a1f);background:rgba(255,193,7,.08);color:var(--lme-warn,#e6cf7a);border-radius:8px;padding:10px 12px;font-size:12.5px;margin-bottom:12px}' +
            '#qsModal .qs-info{border:1px solid var(--lme-info-border,#2c4a63);background:rgba(13,202,240,.07);color:var(--lme-info,#9ccfe6);border-radius:8px;padding:10px 12px;font-size:12.5px;margin-bottom:12px}' +
            '#qsModal .qs-err{border:1px solid var(--lme-danger-border,#6b2a2a);background:rgba(220,53,69,.1);color:var(--lme-danger,#f0a0a8);border-radius:8px;padding:10px 12px;font-size:12.5px;margin-bottom:12px}' +
            '#qsModal .qs-sum{width:100%;font-size:13px}' +
            '#qsModal .qs-sum td{padding:5px 0;vertical-align:top;border-bottom:1px solid var(--border-color)}' +
            '#qsModal .qs-sum td:first-child{color:var(--text-secondary);width:36%;padding-right:10px}' +
            '#qsModal .qs-ap{display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border:1px solid var(--border-color);border-radius:6px;margin-bottom:6px;cursor:pointer;font-size:13px}' +
            '#qsModal .qs-ap:hover{background:var(--bg-surface-hover)}' +
            '#qsModal .qs-ap.sel{border-color:var(--accent-color);background:var(--bg-surface-hover)}' +
            '#qsModal .qs-ap small{color:var(--text-secondary)}' +
            '#qsModal .qs-bind{display:flex;flex-wrap:wrap;gap:6px 16px}' +
            '#qsModal .qs-spin{display:inline-block;width:18px;height:18px;border:2px solid var(--border-color);border-top-color:var(--accent-color);border-radius:50%;animation:qsr .8s linear infinite;vertical-align:-4px;margin-right:8px}' +
            '@keyframes qsr{to{transform:rotate(360deg)}}';
        document.head.appendChild(st);

        var wrap = document.createElement('div');
        wrap.innerHTML =
            '<div class="modal fade" id="qsModal" tabindex="-1" aria-hidden="true" data-bs-backdrop="static" data-bs-keyboard="false">' +
            '<div class="modal-dialog modal-lg modal-dialog-scrollable modal-dialog-centered">' +
            '<div class="modal-content" style="border:1px solid var(--border-color);">' +
            '<div class="modal-header py-2 px-3"><div><div class="fw-semibold" id="qsTitle" style="font-size:15px;">Quick Setup</div>' +
            '<div class="qs-sub" id="qsSub"></div></div>' +
            '<button type="button" class="btn-close btn-close-white ms-auto" id="qsClose" aria-label="Close" style="font-size:12px;"></button></div>' +
            '<div class="modal-body px-3 pt-3" id="qsBody"></div>' +
            '<div class="modal-footer py-2 px-3" style="border-top:1px solid var(--border-color);">' +
            '<button type="button" class="btn btn-outline-secondary btn-sm" id="qsBack">Back</button>' +
            '<button type="button" class="btn btn-primary btn-sm" id="qsNext">Next</button>' +
            '</div></div></div></div>';
        document.body.appendChild(wrap.firstChild);

        el.root = $('qsModal'); el.body = $('qsBody'); el.title = $('qsTitle'); el.sub = $('qsSub');
        el.back = $('qsBack'); el.next = $('qsNext'); el.close = $('qsClose');
        modal = new bootstrap.Modal(el.root);

        el.back.addEventListener('click', goBack);
        el.next.addEventListener('click', goNext);
        el.close.addEventListener('click', requestClose);
        el.body.addEventListener('input', onField);
        el.body.addEventListener('change', onField);
        el.body.addEventListener('click', onClick);
        el.root.addEventListener('hidden.bs.modal', function () { stopTimers(); });
    }

    function stopTimers() {
        if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
        if (probeTimer) { clearTimeout(probeTimer); probeTimer = null; }
    }

    // ── state construction ───────────────────────────────────────────────────
    function secFromEnc(enc) {
        enc = +enc;
        return enc === 0 ? 'open' : enc === 20 ? 'wpa2wpa3' : enc === 16 ? 'wpa3' : 'wpa2';
    }
    // Pick a default DHCP range for the current LAN subnet — but leave the
    // existing range alone while it still fits (don't clobber a custom pool just
    // because the router's own address was nudged within the same subnet).
    function autoPool() {
        var sn = subnetOf(S.lan.ip, S.lan.mask);
        if (!sn) return;
        var s0 = ipNum(S.dhcp.start), e0 = ipNum(S.dhcp.end);
        if (s0 > sn.net && e0 < sn.bc && s0 <= e0) return;
        var start, end;
        if (sn.size >= 256) { start = sn.net + 100; end = sn.net + 200; }
        else { start = sn.net + Math.max(2, Math.floor(sn.size / 4)); end = sn.net + sn.size - 2; }
        S.dhcp.start = numIp(start); S.dhcp.end = numIp(end);
    }
    // push state back into inputs that are on screen (typing doesn't re-render)
    function refreshInputs(keys) {
        keys.forEach(function (k) {
            var e = el.body.querySelector('[data-k="' + k + '"]');
            if (e && e.type !== 'radio' && e.type !== 'checkbox') e.value = getp(k);
        });
    }

    function buildState(ctx, sys, wanList) {
        var lan = ctx.lan || {};
        var profiles = (wanList && wanList.profiles) || [];
        var ponMode = (sys && sys.pon_mode != null) ? +sys.pon_mode : 1;
        var ponAuto = (sys && sys.pon_auto != null) ? +sys.pon_auto : 1;
        var wanPort = (sys && sys.wan_phy_port != null) ? +sys.wan_phy_port : 5;

        var st = {
            mode: null, step: 'mode', ctx: ctx, profiles: profiles,
            cur: { ponMode: ponMode, ponAuto: ponAuto, wanPort: wanPort },
            up: { type: ponMode === 0 ? 'rj45' : 'pon', pon: ponAuto === 1 ? 'auto' : String(ponMode || 1), port: (ponMode === 0 && wanPort >= 0 && wanPort <= 3) ? wanPort : 0 },
            wan: { action: 'replace', type: 'dhcp', user: '', pass: '', ip: '', mask: '255.255.255.0', gw: '', dns1: '', dns2: '', vlan: false, vid: '', vprio: '0', bind: BIND_ALL },
            lan: { ip: lan.ip || '192.168.1.1', mask: lan.mask || '255.255.255.0', mode: (+lan.dhcp_mode === 3) ? 'client' : 'static', gw: '', dns1: '', dns2: '' },
            dhcp: { on: true, start: lan.pool_start || '', end: lan.pool_end || '', lease: +lan.lease || 86400, dnsOpt: +lan.dns_opt === 1 ? 1 : 0, dns1: lan.dns1 || '', dns2: lan.dns2 || '' },
            wifi: { same: false, b24: null, b5: null },
            uplink: { band: '5', manual: false, ssid: '', sec: 'wpa2', pass: '', enc: null, aps: [], scanning: false, scanned: false, msg: '', pick: -1 },
            apply: { phase: 'idle' }, err: ''
        };
        if (+lan.dhcp_mode === 2 || +lan.dhcp_mode === 0) st.dhcp.on = (+lan.dhcp_mode === 2);
        if (!st.dhcp.start || !st.dhcp.end) { S = st; autoPool(); st = S; }
        var w = ctx.wlan || {};
        function band(b) {
            var x = w[b] || {};
            return { on: +x.disabled === 0, ssid: x.ssid || '', sec: secFromEnc(x.encrypt), pass: x.psk || '' };
        }
        st.wifi.b24 = band('24'); st.wifi.b5 = band('5');
        st.wifi.same = !!(ctx.merge && ctx.merge.main_pair) ||
            (st.wifi.b24.ssid !== '' && st.wifi.b24.ssid === st.wifi.b5.ssid && st.wifi.b24.pass === st.wifi.b5.pass && st.wifi.b24.sec === st.wifi.b5.sec);
        // a 5 GHz uplink is the default; fall back to 2.4 if 5 isn't usable
        st.uplink.band = (w['5'] && +w['5'].disabled === 0) ? '5' : '24';
        return st;
    }

    // existing profiles that make sense for the chosen mode
    function usableProfiles() {
        var want = S.mode === 'ap' ? [0] : [1, 2];
        return (S.profiles || []).filter(function (p) { return +p.enable !== 0 && want.indexOf(+p.cmode) >= 0; });
    }
    function profileText(p) {
        var t = +p.cmode === 0 ? 'Bridge' : +p.cmode === 2 ? 'PPPoE' : (+p.addrtype === 0 ? 'Static IP' : 'DHCP');
        return (p.name || ('Profile ' + p.index)) + ' — ' + t + (+p.vlan === 1 ? ', VLAN ' + p.vid : '');
    }

    function currentUpstreamChanged() {
        if (S.mode === 'extender') return false;
        var c = S.cur, u = S.up;
        if (u.type === 'rj45') return !(c.ponMode === 0 && c.ponAuto === 0 && c.wanPort === +u.port);
        if (u.pon === 'auto') return !(c.ponAuto === 1 && c.ponMode !== 0);
        return !(c.ponAuto === 0 && c.ponMode === +u.pon);
    }

    // ── open / close ─────────────────────────────────────────────────────────
    function open() {
        ensureShell();
        stopTimers(); applying = false;
        el.title.textContent = 'Quick Setup';
        el.sub.textContent = '';
        el.body.innerHTML = '<div class="text-center py-5"><span class="qs-spin"></span>Reading the current settings…</div>';
        el.back.style.display = 'none'; el.next.style.display = 'none'; el.close.style.display = '';
        modal.show();
        Promise.all([
            api(QS + '?action=context'),
            api('/cgi-bin/lme.cgi?action=system_status').catch(function () { return {}; }),
            api('/cgi-bin/wan-profile.cgi?action=list').catch(function () { return { profiles: [] }; })
        ]).then(function (r) {
            if (!r[0] || r[0].ok !== true) throw new Error('The device did not return its current settings.');
            S = buildState(r[0], r[1], r[2]);
            if (r[0].busy) {
                S.err = 'A quick setup is still being applied on the device. Wait for it to finish, then reopen this.';
            }
            render();
        }).catch(function (e) {
            el.body.innerHTML = '<div class="qs-err">' + esc(e.message || e) + '</div>' +
                '<button class="btn btn-outline-secondary btn-sm" id="qsRetry">Try again</button>';
            $('qsRetry').addEventListener('click', open);
        });
    }

    function requestClose() {
        if (applying) return;
        var started = S && S.mode && S.step !== 'done' && S.apply.phase === 'idle';
        if (started && !window.confirm('Close Quick Setup? Nothing has been changed yet, and your answers will be lost.')) return;
        stopTimers();
        modal.hide();
    }

    // ── navigation ───────────────────────────────────────────────────────────
    function flow() { return S.mode ? FLOWS[S.mode] : ['mode']; }
    function stepIndex() { return flow().indexOf(S.step); }

    function goBack() {
        var i = stepIndex();
        if (i > 0) { S.step = flow()[i - 1]; S.err = ''; render(); }
    }
    function goNext() {
        if (S.step === 'review') return doApply();
        var msg = validate(S.step);
        if (msg) { S.err = msg; render(true); return; }
        S.err = '';
        var i = stepIndex();
        S.step = flow()[i + 1];
        render();
        if (S.step === 'uplink' && !S.uplink.scanned && !S.uplink.scanning) scan();
    }

    // ── validation (the backend validates again) ─────────────────────────────
    function validate(step) {
        var m = S.mode, i;
        if (step === 'mode') return m ? '' : 'Choose how you want to use this device.';
        if (step === 'upstream') return '';
        if (step === 'wan') {
            if (S.wan.action === 'keep') return '';
            var w = S.wan;
            if (S.wan.vlan && !(/^\d+$/.test(w.vid) && +w.vid >= 1 && +w.vid <= 4094)) return 'Enter a VLAN ID between 1 and 4094, or turn VLAN off.';
            if (m === 'ap') return '';
            if (w.type === 'pppoe' && !w.user.trim()) return 'Enter the PPPoE username your ISP gave you.';
            if (w.type === 'static') {
                if (!isIp(w.ip)) return 'Enter a valid WAN IP address.';
                if (maskSize(w.mask) < 0) return 'Enter a valid WAN subnet mask.';
                if (!isIp(w.gw)) return 'Enter a valid gateway address.';
                if ((w.dns1 && !isIp(w.dns1)) || (w.dns2 && !isIp(w.dns2))) return 'A DNS server address is not valid.';
            }
            return '';
        }
        if (step === 'lan') return validateLan();
        if (step === 'wifi') return validateWifi();
        if (step === 'uplink') {
            var u = S.uplink;
            if (!u.ssid) return u.manual ? 'Enter the name of the WiFi network to connect to.' : 'Pick the WiFi network to connect to (or choose "Enter it manually").';
            if (bytes(u.ssid) > 32) return 'The network name is too long (32 characters max).';
            var e = ENC[u.sec] || ENC.wpa2;
            if (e.enc !== 0 && (bytes(u.pass) < 8 || bytes(u.pass) > 63)) return 'The upstream WiFi password must be 8-63 characters.';
            if (u.wep) return 'WEP networks can\'t be joined from here. Use Site Survey > Connect manually instead.';
            return '';
        }
        return '';
    }
    function validateLan() {
        var l = S.lan, d = S.dhcp;
        if (S.mode !== 'router' && l.mode === 'client') return '';
        if (!isIp(l.ip)) return 'Enter a valid LAN IP address.';
        var sn = subnetOf(l.ip, l.mask);
        if (!sn) return 'Enter a valid subnet mask.';
        if (sn.size < 4 || sn.size > 16777216) return 'The subnet mask must be between 255.0.0.0 and 255.255.255.252.';
        var x = ipNum(l.ip);
        if (x === sn.net || x === sn.bc) return 'That address is the network or broadcast address of its subnet.';
        var a1 = Math.floor(x / 16777216);
        if (a1 === 0 || a1 === 127 || a1 >= 224) return 'That address can\'t be used for a LAN. Use a private range such as 192.168.x.x or 10.x.x.x.';
        if (S.mode === 'router') {
            if (S.wan.action === 'replace' && S.wan.type === 'static' && isIp(S.wan.ip)) {
                var ws = subnetOf(S.wan.ip, S.wan.mask);
                if (ws && !(ws.bc < sn.net || ws.net > sn.bc)) return 'Your WAN address range overlaps this LAN subnet. Pick a different LAN address.';
            }
            if (d.on) {
                var s = ipNum(d.start), e = ipNum(d.end);
                if (s < 0 || e < 0) return 'Enter a valid DHCP start and end address.';
                if (s <= sn.net || e >= sn.bc) return 'The DHCP range must be inside the LAN subnet.';
                if (s > e) return 'The DHCP range start must come before its end.';
                if (x >= s && x <= e) return 'The DHCP range can\'t include this router\'s own address.';
                if (d.dnsOpt === 1) {
                    if (!isIp(d.dns1)) return 'Enter at least one DNS server, or choose "Use this router".';
                    if (d.dns2 && !isIp(d.dns2)) return 'The second DNS server is not valid.';
                }
            }
        } else {
            if (l.gw) {
                var g = ipNum(l.gw);
                if (g < 0) return 'The gateway address is not valid.';
                if (g <= sn.net || g >= sn.bc) return 'The gateway must be inside the same subnet as the LAN address.';
                if (g === x) return 'The gateway can\'t be this device\'s own address.';
            }
            if ((l.dns1 && !isIp(l.dns1)) || (l.dns2 && !isIp(l.dns2))) return 'A DNS server address is not valid.';
        }
        return '';
    }
    function bandLabel(b) { return b === '5' ? '5 GHz' : '2.4 GHz'; }
    function bandUsable(b) {
        var vxd = b === '5' ? 'wlan0-vxd' : 'wlan1-vxd';
        if ((S.ctx.repurposed || []).indexOf(vxd) >= 0) return false;
        if (S.ctx.locked && S.ctx.locked[b]) return !!(S.ctx.wlan && S.ctx.wlan[b] && +S.ctx.wlan[b].disabled === 0);
        return !!S.wifi['b' + b].on;
    }
    function validateWifi() {
        var locked = S.ctx.locked || {};
        var bands = ['24', '5'];
        for (var i = 0; i < bands.length; i++) {
            var b = bands[i], c = S.wifi['b' + b];
            if (locked[b] || !c.on) continue;
            var n = bytes(c.ssid);
            if (n < 1 || n > 32) return 'The ' + bandLabel(b) + ' WiFi name must be 1-32 characters.';
            if (c.sec !== 'open' && (bytes(c.pass) < 8 || bytes(c.pass) > 63)) return 'The ' + bandLabel(b) + ' WiFi password must be 8-63 characters.';
        }
        if (S.mode === 'extender') {
            // the uplink needs one band whose own WiFi is on and whose repeater
            // interface isn't used as a WAN; switch to the other band if the
            // chosen one can't be used any more
            if (!bandUsable(S.uplink.band)) {
                var other = S.uplink.band === '5' ? '24' : '5';
                if (!bandUsable(other)) return 'No band is available to connect upstream. Turn on the WiFi of at least one band (a band whose repeater interface is used as a WAN on the DHCP Client page can\'t be used).';
                S.uplink.band = other; S.uplink.aps = []; S.uplink.scanned = false; S.uplink.pick = -1; S.uplink.ssid = ''; S.uplink.msg = '';
            }
        }
        return '';
    }

    // ── rendering ────────────────────────────────────────────────────────────
    function opt(v, t, cur) { return '<option value="' + esc(v) + '"' + (String(cur) === String(v) ? ' selected' : '') + '>' + esc(t) + '</option>'; }
    function input(label, key, o) {
        o = o || {};
        var v = getp(key);
        return '<div class="' + (o.cls || 'mb-2') + '">' +
            (label ? '<label class="qs-l">' + esc(label) + '</label>' : '') +
            '<input class="form-control form-control-sm" data-k="' + key + '"' + (o.type ? ' type="' + o.type + '"' : ' type="text"') +
            ' value="' + esc(v) + '" placeholder="' + esc(o.ph || '') + '" autocomplete="off" spellcheck="false"' +
            (o.dis ? ' disabled' : '') + (o.max ? ' maxlength="' + o.max + '"' : '') + '>' +
            (o.hint ? '<div class="qs-hint">' + o.hint + '</div>' : '') + '</div>';
    }
    function select(label, key, options, o) {
        o = o || {};
        var v = getp(key);
        return '<div class="' + (o.cls || 'mb-2') + '">' +
            (label ? '<label class="qs-l">' + esc(label) + '</label>' : '') +
            '<select class="form-select form-select-sm" data-k="' + key + '" data-r="1"' + (o.dis ? ' disabled' : '') + '>' +
            options.map(function (x) { return opt(x[0], x[1], v); }).join('') + '</select>' +
            (o.hint ? '<div class="qs-hint">' + o.hint + '</div>' : '') + '</div>';
    }
    function radioCard(key, val, title, desc, o) {
        o = o || {};
        var cur = getp(key), sel = String(cur) === String(val);
        return '<label class="qs-card' + (sel ? ' sel' : '') + (o.dis ? ' dis' : '') + '">' +
            '<div class="qs-t"><input type="radio" data-k="' + key + '" data-v="' + esc(val) + '" data-r="1" name="' + esc(key) + '"' +
            (sel ? ' checked' : '') + (o.dis ? ' disabled' : '') + '>' + esc(title) + '</div>' +
            (desc ? '<div class="qs-d">' + desc + '</div>' : '') +
            (sel && o.extra ? '<div style="margin:10px 0 0 26px;">' + o.extra + '</div>' : '') + '</label>';
    }
    function check(label, key, o) {
        o = o || {};
        return '<div class="form-check form-switch ' + (o.cls || 'mb-2') + '">' +
            '<input class="form-check-input" type="checkbox" data-k="' + key + '" data-b="1" data-r="1" id="qs_' + key.replace(/\./g, '_') + '"' +
            (getp(key) ? ' checked' : '') + (o.dis ? ' disabled' : '') + '>' +
            '<label class="form-check-label" for="qs_' + key.replace(/\./g, '_') + '" style="font-size:13px;">' + esc(label) + '</label></div>';
    }

    function render(keepScroll) {
        var scrollTop = el.body.scrollTop;
        var steps = flow(), idx = stepIndex();
        if (S.step === 'applying' || S.step === 'done') {
            el.title.textContent = 'Applying Quick Setup'; el.sub.textContent = '';
        } else {
            el.title.textContent = 'Quick Setup';
            el.sub.textContent = S.mode ? ('Step ' + (idx + 1) + ' of ' + steps.length + ' · ' + STEP_LABEL[S.step]) : 'Step 1 · ' + STEP_LABEL.mode;
        }
        var h = '';
        if (S.step !== 'applying' && S.step !== 'done') {
            h += '<div class="qs-dots">' + steps.map(function (s, i) { return '<div class="qs-dot' + (i <= idx ? ' on' : '') + '"></div>'; }).join('') + '</div>';
        }
        if (S.err) h += '<div class="qs-err" id="qsErr">' + esc(S.err) + '</div>';
        h += R[S.step]();
        el.body.innerHTML = h;

        var last = S.step === 'review';
        el.back.style.display = (idx > 0 && S.step !== 'applying' && S.step !== 'done') ? '' : 'none';
        el.next.style.display = (S.step === 'applying' || S.step === 'done') ? 'none' : '';
        el.next.textContent = last ? 'Apply' : 'Next';
        el.next.disabled = !!(S.ctx && S.ctx.busy);
        el.close.style.display = (S.step === 'applying') ? 'none' : '';
        if (keepScroll) el.body.scrollTop = scrollTop;
        else el.body.scrollTop = 0;
        if (S.err) { var e = $('qsErr'); if (e && e.scrollIntoView) e.scrollIntoView({ block: 'nearest' }); }
    }

    var R = {};

    R.mode = function () {
        var m = S.mode;
        return '<p style="font-size:13px;color:var(--text-secondary);">How do you want to use this device? ' +
            '<strong style="color:var(--text-primary);">Nothing is changed until you press Apply on the last page.</strong></p>' +
            radioCard('mode', 'router', 'Router',
                'Share your internet connection. This device connects to your ISP (through fiber or an Ethernet port) and runs your home network: it gives out IP addresses and shares the connection.') +
            radioCard('mode', 'ap', 'Bridge WAN / Access Point',
                'Pass your ISP connection through to the devices on this one, or use it as a WiFi access point behind another router. Another router handles the internet connection and gives out IP addresses.') +
            radioCard('mode', 'extender', 'WiFi Bridge / Extender',
                'Connect to an existing WiFi network and share it through this device\'s own WiFi and LAN ports. No fiber or WAN connection is used.');
    };

    R.upstream = function () {
        var u = S.up, ponSel = u.type === 'pon', rjSel = u.type === 'rj45';
        var ponExtra = select('Fiber mode', 'up.pon', [['auto', 'Auto-detect (recommended)'], ['1', 'GPON'], ['2', 'EPON'], ['3', 'Fiber Ethernet']], { cls: 'mb-0' });
        var rjExtra = select('Which LAN port is plugged into your ISP?', 'up.port', [[0, 'LAN 1'], [1, 'LAN 2'], [2, 'LAN 3'], [3, 'LAN 4']], { cls: 'mb-0' }) +
            '<div class="qs-hint">That port becomes the WAN port and stops working as a LAN port.</div>';
        return '<p style="font-size:13px;color:var(--text-secondary);">Where does your internet come from?</p>' +
            radioCard('up.type', 'pon', 'Fiber (PON)', 'The fiber cable from your ISP is plugged into this device\'s PON port.', { extra: ponExtra }) +
            radioCard('up.type', 'rj45', 'RJ45 Ethernet port', 'A network cable from your ISP\'s modem or media converter is plugged into one of the LAN ports.', { extra: rjExtra }) +
            (currentUpstreamChanged() ? '<div class="qs-warn">This is different from the current setting, so <strong>the device will reboot</strong> when you apply.</div>' : '');
    };

    R.wan = function () {
        var m = S.mode, w = S.wan, usable = usableProfiles(), h = '';
        if (usable.length) {
            h += '<p style="font-size:13px;color:var(--text-secondary);">This device already has a ' + (m === 'ap' ? 'bridge' : 'WAN') + ' connection.</p>' +
                radioCard('wan.action', 'keep', 'Keep the current connection',
                    usable.map(function (p) { return esc(profileText(p)); }).join('<br>')) +
                radioCard('wan.action', 'replace', 'Set up a new connection',
                    'Replaces <strong>all</strong> existing WAN profiles with the one you configure next.');
        } else {
            S.wan.action = 'replace';
            h += '<p style="font-size:13px;color:var(--text-secondary);">' +
                (m === 'ap' ? 'This device has no bridge WAN connection yet. Set one up below.' :
                    'This device has no internet (WAN) connection set up yet. Choose how your ISP connects you.') + '</p>';
        }
        if (w.action === 'replace') {
            if (m === 'ap') {
                h += '<div class="qs-info">Bridge mode passes traffic between your ISP and the selected interfaces without routing or NAT. Your other router does that part.</div>';
            } else {
                var pppoe = '<div class="row g-2"><div class="col-sm-6">' + input('PPPoE username', 'wan.user', { cls: 'mb-0' }) + '</div><div class="col-sm-6">' +
                    input('PPPoE password', 'wan.pass', { cls: 'mb-0', type: 'password' }) + '</div></div>';
                var stat = '<div class="row g-2"><div class="col-sm-6">' + input('IP address', 'wan.ip', { cls: 'mb-0' }) + '</div><div class="col-sm-6">' +
                    input('Subnet mask', 'wan.mask', { cls: 'mb-0' }) + '</div><div class="col-sm-6">' + input('Gateway', 'wan.gw', { cls: 'mb-0' }) +
                    '</div><div class="col-sm-6">' + input('DNS server (optional)', 'wan.dns1', { cls: 'mb-0' }) + '</div></div>';
                h += radioCard('wan.type', 'dhcp', 'Automatic (DHCP)', 'The most common type. Your ISP gives this device an address automatically. Nothing else to enter.') +
                    radioCard('wan.type', 'pppoe', 'PPPoE', 'Your ISP gave you a username and password.', { extra: pppoe }) +
                    radioCard('wan.type', 'static', 'Static IP', 'Your ISP gave you a fixed address, mask and gateway.', { extra: stat });
            }
            h += '<div class="qs-box">' + check('My ISP needs a VLAN ID (advanced — most people don\'t)', 'wan.vlan', { cls: 'mb-1' });
            if (w.vlan) h += '<div class="row g-2 mt-1"><div class="col-sm-4">' + input('VLAN ID (1-4094)', 'wan.vid', { cls: 'mb-0', ph: 'e.g. 10' }) + '</div></div>';
            h += '</div>';
            if (m === 'ap') {
                var rjBit = (S.up.type === 'rj45') ? (1 << S.up.port) : 0;
                h += '<div class="qs-box"><h6>Interfaces connected to the bridge</h6>' +
                    '<div class="qs-hint mb-2" style="margin-top:-4px;">Everything is selected by default. Untick an interface to keep it on this device\'s own LAN instead.</div>';
                BIND_GROUPS.forEach(function (g) {
                    h += '<div class="mb-2"><div class="qs-l">' + esc(g.title) + '</div><div class="qs-bind">';
                    g.items.forEach(function (it) {
                        var bit = it[0], used = (rjBit & (1 << bit)) !== 0, on = !used && (w.bind & (1 << bit)) !== 0;
                        h += '<label class="form-check-label" style="font-size:13px;' + (used ? 'opacity:.5;' : '') + '"><input class="form-check-input me-1" type="checkbox" data-bind="' + bit + '"' +
                            (on ? ' checked' : '') + (used ? ' disabled' : '') + '>' + esc(it[1]) + (used ? ' (WAN uplink)' : '') + '</label>';
                    });
                    h += '</div></div>';
                });
                h += '<a href="#" data-act="bind-all" style="font-size:12px;">Select all</a> &nbsp;·&nbsp; <a href="#" data-act="bind-none" style="font-size:12px;">Select none</a></div>';
            }
            if (usable.length || (S.profiles && S.profiles.length)) {
                h += '<div class="qs-warn">All ' + S.profiles.length + ' existing WAN profile' + (S.profiles.length === 1 ? '' : 's') +
                    ' will be deleted, including any ISP management (TR-069) profile.</div>';
            }
        }
        return h;
    };

    R.lan = function () {
        var m = S.mode, l = S.lan, d = S.dhcp, h = '';
        var masks = MASKS.slice(); if (masks.indexOf(l.mask) < 0 && isIp(l.mask)) masks.push(l.mask);
        var maskSel = select('Subnet mask', 'lan.mask', masks.map(function (x) { return [x, x]; }), { cls: 'mb-0' });
        if (m === 'router') {
            h += '<p style="font-size:13px;color:var(--text-secondary);">Your home network. These devices will get their addresses from here.</p>' +
                '<div class="qs-box"><h6>This router\'s address</h6><div class="row g-2"><div class="col-sm-6">' +
                input('LAN IP address', 'lan.ip', { cls: 'mb-0', hint: 'Usually 192.168.1.1' }) + '</div><div class="col-sm-6">' + maskSel + '</div></div></div>' +
                '<div class="qs-box"><h6>DHCP server</h6>' +
                check('Give out IP addresses automatically (recommended)', 'dhcp.on', { cls: 'mb-1' });
            if (d.on) {
                var leases = LEASES.slice(); if (!leases.some(function (x) { return x[0] === +d.lease; })) leases.push([+d.lease, d.lease + ' seconds']);
                h += '<div class="row g-2 mt-1"><div class="col-sm-4">' + input('First address', 'dhcp.start', { cls: 'mb-0' }) + '</div><div class="col-sm-4">' +
                    input('Last address', 'dhcp.end', { cls: 'mb-0' }) + '</div><div class="col-sm-4">' +
                    select('Lease time', 'dhcp.lease', leases, { cls: 'mb-0' }) + '</div></div>' +
                    '<div class="mt-3"><div class="qs-l">DNS servers handed to devices</div>' +
                    '<div class="d-flex gap-3 flex-wrap">' +
                    '<label style="font-size:13px;"><input type="radio" data-k="dhcp.dnsOpt" data-v="0" data-r="1" name="dnsopt"' + (d.dnsOpt === 0 ? ' checked' : '') + '> Use this router (recommended)</label>' +
                    '<label style="font-size:13px;"><input type="radio" data-k="dhcp.dnsOpt" data-v="1" data-r="1" name="dnsopt"' + (d.dnsOpt === 1 ? ' checked' : '') + '> Custom</label></div>';
                if (d.dnsOpt === 1) h += '<div class="row g-2 mt-1"><div class="col-sm-6">' + input('DNS 1', 'dhcp.dns1', { cls: 'mb-0', ph: 'e.g. 1.1.1.1' }) +
                    '</div><div class="col-sm-6">' + input('DNS 2 (optional)', 'dhcp.dns2', { cls: 'mb-0', ph: 'e.g. 8.8.8.8' }) + '</div></div>';
                h += '</div>';
            } else {
                h += '<div class="qs-hint">With the DHCP server off, devices need fixed IP addresses in this subnet.</div>';
            }
            h += '</div>';
            if (S.ctx.client_ip && isIp(l.ip) && S.ctx.lan && l.ip !== S.ctx.lan.ip) {
                h += '<div class="qs-warn">Changing the LAN address means you\'ll reconnect to the new address (<strong>' + esc(l.ip) + '</strong>) after applying.</div>';
            }
        } else {
            h += '<p style="font-size:13px;color:var(--text-secondary);">How should this device get its own address on your network? ' +
                'The DHCP server on this device is turned off in this mode, so your main router hands out addresses.</p>';
            var cl = S.ctx.lan || {}; var guess = (function () {
                var sn = subnetOf(cl.ip || l.ip, cl.mask || l.mask);
                return sn ? numIp(sn.net + 1) : '192.168.1.1';
            })();
            var stat = '<div class="row g-2"><div class="col-sm-6">' + input('IP address', 'lan.ip', { cls: 'mb-0', hint: 'An unused address in your main router\'s network, e.g. ' + esc(numIp(ipNum(guess) + 1)) }) +
                '</div><div class="col-sm-6">' + maskSel + '</div><div class="col-sm-6">' +
                input('Gateway (your main router)', 'lan.gw', { cls: 'mb-0', ph: guess, hint: 'Needed for updates and time sync' }) + '</div><div class="col-sm-6">' +
                input('DNS server (optional)', 'lan.dns1', { cls: 'mb-0', ph: guess }) + '</div></div>';
            h += radioCard('lan.mode', 'static', 'Static IP', 'You choose the address. Easy to find again later.', { extra: stat }) +
                radioCard('lan.mode', 'client', 'DHCP client', 'Your main router picks the address. You\'ll have to look up this device\'s new address in your main router\'s list of connected devices.');
            if (l.mode === 'static' && isIp(l.ip) && S.ctx.lan && l.ip !== S.ctx.lan.ip) {
                h += '<div class="qs-warn">You\'ll reconnect to <strong>' + esc(l.ip) + '</strong> after applying.</div>';
            }
        }
        return h;
    };

    function wifiCard(b) {
        var c = S.wifi['b' + b], locked = !!(S.ctx.locked && S.ctx.locked[b]);
        var mirrored = S.wifi.same && b === '5';
        var dis = locked || mirrored;
        var h = '<div class="qs-box"><div class="d-flex justify-content-between align-items-center mb-2"><h6 class="mb-0">' + bandLabel(b) + ' WiFi</h6>' +
            '<div class="form-check form-switch mb-0"><input class="form-check-input" type="checkbox" data-k="wifi.b' + b + '.on" data-b="1" data-r="1"' +
            (c.on ? ' checked' : '') + (locked ? ' disabled' : '') + '></div></div>';
        if (locked) {
            return h + '<div class="qs-hint">Left as it is: a coin-slot NodeMCU is synced to this WiFi, and only the WiFi pages can update the NodeMCU along with it.</div></div>';
        }
        if (!c.on) return h + '<div class="qs-hint">This band will be turned off.</div></div>';
        h += '<div class="row g-2"><div class="col-sm-6">' + input('Network name (SSID)', 'wifi.b' + b + '.ssid', { cls: 'mb-0', dis: mirrored, max: 32 }) + '</div><div class="col-sm-6">' +
            select('Security', 'wifi.b' + b + '.sec', SECS, { cls: 'mb-0', dis: mirrored }) + '</div>';
        if (c.sec !== 'open') {
            h += '<div class="col-12"><label class="qs-l">Password (8-63 characters)</label><div class="input-group input-group-sm">' +
                '<input class="form-control" data-k="wifi.b' + b + '.pass" id="qsPw' + b + '" type="password" value="' + esc(c.pass) + '" autocomplete="new-password" spellcheck="false"' + (mirrored ? ' disabled' : '') + '>' +
                '<button class="btn btn-outline-secondary" type="button" data-act="showpw" data-id="qsPw' + b + '">Show</button></div></div>';
        }
        return h + '</div></div>';
    }

    R.wifi = function () {
        var locked = S.ctx.locked || {}, mergeMain = !!(S.ctx.merge && S.ctx.merge.main_pair);
        var canSame = !locked['24'] && !locked['5'];
        var h = '<p style="font-size:13px;color:var(--text-secondary);">' +
            (S.mode === 'extender' ? 'The WiFi this device will broadcast for your own phones and laptops.' : 'The WiFi networks this device broadcasts.') + '</p>';
        if (canSame) {
            h += '<div class="qs-box" style="padding-bottom:6px;">' + check('Use the same name and password on both bands', 'wifi.same', { cls: 'mb-1', dis: mergeMain }) +
                (mergeMain ? '<div class="qs-hint mb-1">Required: the merged-SSID feature is on.</div>' : '') + '</div>';
        }
        return h + wifiCard('24') + wifiCard('5');
    };

    R.uplink = function () {
        var u = S.uplink, w = S.ctx.wlan || {}, locked = S.ctx.locked || {}, rep = S.ctx.repurposed || [];
        function bandOpt(b) {
            var vxd = b === '5' ? 'wlan0-vxd' : 'wlan1-vxd';
            var inUse = rep.indexOf(vxd) >= 0;
            var off = !inUse && !bandUsable(b);
            var why = inUse ? 'Used as a WAN (DHCP Client page)' : off ? 'This band\'s WiFi is turned off' : '';
            return '<label class="form-check-label me-3" style="font-size:13px;' + (why ? 'opacity:.5;' : '') + '"><input class="form-check-input me-1" type="radio" data-k="uplink.band" data-v="' + b +
                '" data-r="1" name="upband"' + (u.band === b ? ' checked' : '') + (why ? ' disabled' : '') + '>' + bandLabel(b) + (why ? ' <small>(' + esc(why) + ')</small>' : '') + '</label>';
        }
        var h = '<p style="font-size:13px;color:var(--text-secondary);">Which WiFi network should this device connect to?</p>' +
            '<div class="qs-box"><div class="qs-l">Connect using</div><div>' + bandOpt('24') + bandOpt('5') + '</div>' +
            '<div class="qs-hint">The other band keeps working normally for your own devices.</div></div>';
        if (!u.manual) {
            h += '<div class="d-flex justify-content-between align-items-center mb-2"><div class="qs-l mb-0">Networks nearby</div>' +
                '<button class="btn btn-outline-secondary btn-sm" data-act="scan"' + (u.scanning ? ' disabled' : '') + '>' + (u.scanning ? 'Scanning…' : 'Scan again') + '</button></div>';
            if (u.scanning) {
                h += '<div class="qs-hint py-3"><span class="qs-spin"></span>Scanning… this can take up to 20 seconds. WiFi may pause briefly.</div>';
            } else if (u.aps.length) {
                u.aps.forEach(function (ap, i) {
                    var hidden = !ap.ssid;
                    h += '<div class="qs-ap' + (u.pick === i ? ' sel' : '') + '"' + (hidden ? ' style="opacity:.5;cursor:default;"' : ' data-act="pick" data-i="' + i + '"') + '>' +
                        '<span>' + (hidden ? '<em>hidden network</em>' : esc(ap.ssid)) + ' <small>· ch ' + esc(ap.channel) + '</small></span>' +
                        '<span><small>' + esc(ap.label) + ' · ' + esc(ap.dbm) + ' dBm</small></span></div>';
                });
            } else {
                h += '<div class="qs-hint py-2">' + esc(u.msg || (u.scanned ? 'No networks found.' : 'Press Scan to look for networks.')) + '</div>';
            }
            h += '<div class="mt-2"><a href="#" data-act="manual-on" style="font-size:12px;">Not listed? Enter it manually</a></div>';
        } else {
            h += '<div class="qs-box"><h6>Enter the network yourself</h6><div class="row g-2"><div class="col-sm-6">' + input('Network name (SSID)', 'uplink.ssid', { cls: 'mb-0', max: 32 }) +
                '</div><div class="col-sm-6">' + select('Security', 'uplink.sec', UP_SECS, { cls: 'mb-0' }) + '</div></div></div>' +
                '<a href="#" data-act="manual-off" style="font-size:12px;">← Back to the list of networks</a>';
        }
        if (u.ssid && !u.manual) {
            h += '<div class="qs-box mt-3"><div class="qs-l">Connecting to</div><div class="fw-semibold mb-2" style="font-size:14px;">' + esc(u.ssid) + '</div>';
        } else if (u.manual) {
            h += '<div class="qs-box mt-3">';
        } else { h += '<div style="display:none">'; }
        if (u.ssid || u.manual) {
            var e = ENC[u.sec] || ENC.wpa2;
            if (u.wep) h += '<div class="qs-err">That network uses WEP, which can\'t be joined from here. Use Site Survey › Connect manually.</div>';
            else if (e.enc !== 0) h += '<label class="qs-l">Password of that network</label><div class="input-group input-group-sm">' +
                '<input class="form-control" data-k="uplink.pass" id="qsPwU" type="password" value="' + esc(u.pass) + '" autocomplete="new-password" spellcheck="false">' +
                '<button class="btn btn-outline-secondary" type="button" data-act="showpw" data-id="qsPwU">Show</button></div>';
            else h += '<div class="qs-hint">This is an open network — no password needed.</div>';
        }
        return h + '</div>';
    };

    function wifiSummary(b) {
        var c = S.wifi['b' + b], locked = S.ctx.locked && S.ctx.locked[b];
        if (locked) return 'Unchanged (coin slot is synced to it)';
        if (!c.on) return 'Off';
        return esc(c.ssid) + ' · ' + esc((SECS.filter(function (s) { return s[0] === c.sec; })[0] || [0, c.sec])[1]);
    }

    R.review = function () {
        var m = S.mode, rows = [], warn = [];
        function row(k, v) { rows.push('<tr><td>' + esc(k) + '</td><td>' + v + '</td></tr>'); }
        row('Setup type', m === 'router' ? 'Router' : m === 'ap' ? 'Bridge WAN / Access Point' : 'WiFi Bridge / Extender');
        if (m !== 'extender') {
            var u = S.up;
            row('Internet source', u.type === 'rj45' ? 'RJ45 port LAN ' + (+u.port + 1) : 'Fiber — ' + (u.pon === 'auto' ? 'auto-detect' : ({ 1: 'GPON', 2: 'EPON', 3: 'Fiber Ethernet' })[u.pon]));
            var w = S.wan;
            if (w.action === 'keep') row('WAN connection', 'Keep the current one');
            else {
                var t = m === 'ap' ? 'Bridge' : w.type === 'pppoe' ? 'PPPoE (' + esc(w.user) + ')' : w.type === 'static' ? 'Static IP ' + esc(w.ip) : 'Automatic (DHCP)';
                row('WAN connection', t + (w.vlan ? ', VLAN ' + esc(w.vid) : '') + '<br><small style="color:var(--text-secondary)">replaces all existing WAN profiles</small>');
                if (m === 'ap') {
                    var names = [];
                    BIND_GROUPS.forEach(function (g) { g.items.forEach(function (it) { if (w.bind & (1 << it[0])) names.push(g.title.replace(' WiFi', '') + ' ' + it[1]); }); });
                    row('Bridged interfaces', (w.bind === BIND_ALL ? 'All interfaces' : names.length ? esc(names.join(', ')) : 'None'));
                }
            }
        }
        var l = S.lan;
        if (m === 'router') {
            row('LAN', esc(l.ip) + ' / ' + esc(l.mask));
            row('DHCP server', S.dhcp.on ? esc(S.dhcp.start) + ' – ' + esc(S.dhcp.end) + ', lease ' + esc((LEASES.filter(function (x) { return x[0] === +S.dhcp.lease; })[0] || [0, S.dhcp.lease + ' s'])[1]) : 'Off');
        } else {
            row('LAN address', l.mode === 'client' ? 'DHCP client (assigned by your main router)' : esc(l.ip) + ' / ' + esc(l.mask) + (l.gw ? '<br><small style="color:var(--text-secondary)">gateway ' + esc(l.gw) + '</small>' : ''));
            row('DHCP server', 'Off');
        }
        row('2.4 GHz WiFi', wifiSummary('24'));
        row('5 GHz WiFi', wifiSummary('5'));
        if (m === 'extender') row('Connects to', esc(S.uplink.ssid) + ' (' + bandLabel(S.uplink.band) + ')');

        if (m !== 'extender' && S.wan.action === 'replace') warn.push('All existing WAN profiles will be deleted and replaced.');
        if (m !== 'extender' && currentUpstreamChanged()) warn.push('The internet source changed, so the device will <strong>reboot</strong> after saving.');
        if (m === 'router' ? (S.ctx.lan && l.ip !== S.ctx.lan.ip) : (l.mode === 'static' && S.ctx.lan && l.ip !== S.ctx.lan.ip))
            warn.push('This device\'s address will change to <strong>' + esc(l.ip) + '</strong>. You\'ll need to reconnect to it there.');
        if (m !== 'router' && l.mode === 'client')
            warn.push('This device will get its address from your main router. Look for it in that router\'s list of connected devices to open this page again.');
        warn.push('Your WiFi and network connection will drop for a short while while this applies, including this page\'s connection.');

        return '<p style="font-size:13px;color:var(--text-secondary);">Review your choices. Pressing <strong style="color:var(--text-primary);">Apply</strong> saves everything at once.</p>' +
            '<table class="qs-sum">' + rows.join('') + '</table>' +
            '<div class="qs-warn mt-3">' + warn.map(function (x) { return '• ' + x; }).join('<br>') +
            '<br><span style="opacity:.8;">A backup of the current configuration is kept on the device.</span></div>';
    };

    R.applying = function () {
        var a = S.apply;
        return '<div class="text-center py-4"><div style="font-size:15px;" class="mb-2"><span class="qs-spin"></span>' + esc(a.msg || 'Applying…') + '</div>' +
            (a.total ? '<div class="qs-hint">Step ' + esc(a.step) + ' of ' + esc(a.total) + '</div>' : '') +
            (a.lost ? '<div class="qs-info mt-3 text-start">The connection to the device dropped. That is expected when the WiFi or the address changes. ' +
                'The change keeps going on the device by itself.' +
                (a.probeUrl ? '<br>Waiting for it to come back at <strong>' + esc(a.probeUrl) + '</strong>…' : '<br>Reconnect to the device\'s WiFi or cable, then open its (new) address.') + '</div>' : '') +
            '</div>';
    };

    R.done = function () {
        var a = S.apply, h = '';
        if (a.phase === 'failed') {
            h += '<div class="qs-err"><strong>Setup stopped.</strong><br>' + esc(a.msg || 'Something went wrong.') + '</div>' +
                '<div class="qs-hint">The previous configuration is backed up on the device (config.xml.quicksetup.bak) and can be restored from System › MIB Configuration. ' +
                'Nothing after the failing step was applied.</div>';
        } else {
            h += '<div class="text-center py-3"><div style="font-size:34px;line-height:1;">✓</div><div class="fw-semibold mt-2" style="font-size:16px;">' +
                (a.rebooting ? 'Saved — the device is rebooting' : 'Quick Setup applied') + '</div></div>';
            if (a.rebooting) h += '<div class="qs-info">The device restarts to switch its internet source. This takes about two minutes.' +
                (a.probeUrl ? ' This page will open <strong>' + esc(a.probeUrl) + '</strong> when it is back.' : '') + '</div>';
            if (a.reboot_needed && !a.rebooting) h += '<div class="qs-warn">A reboot is still needed for the new WAN connection to start. ' +
                '<button class="btn btn-sm btn-outline-warning ms-2" data-act="reboot">Reboot now</button></div>';
            (a.notes || []).forEach(function (n) { h += '<div class="qs-info">' + esc(n) + '</div>'; });
            if (a.newIp && !a.rebooting) h += '<div class="qs-info">This device is now at <a href="' + esc(a.url) + '">' + esc(a.url) + '</a>.</div>';
            else if (S.mode !== 'router' && S.lan.mode === 'client' && !a.rebooting) h += '<div class="qs-info">Find this device in your main router\'s client list to open this page again.</div>';
        }
        h += '<div class="d-flex gap-2 justify-content-end mt-3">';
        if (a.phase === 'failed') h += '<button class="btn btn-outline-secondary btn-sm" data-act="restart">Start over</button>';
        if (a.url && a.phase !== 'failed') h += '<a class="btn btn-primary btn-sm" href="' + esc(a.url) + '">Open ' + esc(a.url) + '</a>';
        h += '<button class="btn btn-' + (a.url && a.phase !== 'failed' ? 'outline-secondary' : 'primary') + ' btn-sm" data-act="finish">Close</button></div>';
        return h;
    };

    // ── events ───────────────────────────────────────────────────────────────
    function syncWifi() {
        if (S.wifi.same) { var a = S.wifi.b24, b = S.wifi.b5; b.ssid = a.ssid; b.sec = a.sec; b.pass = a.pass; }
    }
    function onField(ev) {
        var t = ev.target;
        if (t.getAttribute('data-bind') != null) {
            var bit = +t.getAttribute('data-bind');
            S.wan.bind = t.checked ? (S.wan.bind | (1 << bit)) : (S.wan.bind & ~(1 << bit));
            return;
        }
        var k = t.getAttribute('data-k');
        if (!k) return;
        // inputs commit on every keystroke; radios/selects/checkboxes on change
        if (ev.type === 'input' && (t.type === 'radio' || t.type === 'checkbox' || t.tagName === 'SELECT')) return;
        if (ev.type === 'change' && t.type !== 'radio' && t.type !== 'checkbox' && t.tagName !== 'SELECT') return;
        var v;
        if (t.type === 'radio') { if (!t.checked) return; v = t.getAttribute('data-v'); if (/^-?\d+$/.test(v) && k !== 'uplink.band') v = +v; }
        else if (t.type === 'checkbox') v = t.checked;
        else v = t.value;
        if (t.tagName === 'SELECT' && /^(up\.port|dhcp\.lease)$/.test(k)) v = +v;
        if (t.tagName === 'SELECT' && k === 'up.pon' && v !== 'auto') v = String(v);
        setp(k, v);

        if (k === 'wifi.same' && v) { syncWifi(); }
        if (/^wifi\.b24\./.test(k)) { syncWifi(); refreshInputs(['wifi.b5.ssid', 'wifi.b5.pass', 'wifi.b5.sec']); }
        if ((k === 'lan.ip' || k === 'lan.mask') && S.mode === 'router') { autoPool(); refreshInputs(['dhcp.start', 'dhcp.end']); }
        if (k === 'uplink.sec' || k === 'uplink.ssid') { S.uplink.wep = false; }
        if (k === 'uplink.band') { S.uplink.aps = []; S.uplink.scanned = false; S.uplink.pick = -1; S.uplink.ssid = ''; S.uplink.msg = ''; }
        if (t.getAttribute('data-r') === '1') {
            render(true);
            if (k === 'uplink.band') scan();
        }
    }

    function onClick(ev) {
        var t = ev.target.closest ? ev.target.closest('[data-act]') : null;
        if (!t) return;
        var act = t.getAttribute('data-act');
        if (act !== 'pick' || true) ev.preventDefault();
        if (act === 'bind-all') { S.wan.bind = BIND_ALL; render(true); }
        else if (act === 'bind-none') { S.wan.bind = 0; render(true); }
        else if (act === 'showpw') {
            var inp = $(t.getAttribute('data-id'));
            if (inp) { var show = inp.type === 'password'; inp.type = show ? 'text' : 'password'; t.textContent = show ? 'Hide' : 'Show'; }
        }
        else if (act === 'scan') scan();
        else if (act === 'pick') {
            var i = +t.getAttribute('data-i'), ap = S.uplink.aps[i];
            if (!ap || !ap.ssid) return;
            S.uplink.pick = i; S.uplink.ssid = ap.ssid; S.uplink.sec = ap.sec; S.uplink.wep = !!ap.wep; S.uplink.pass = '';
            render(true);
        }
        else if (act === 'manual-on') { S.uplink.manual = true; S.uplink.ssid = ''; S.uplink.pick = -1; S.uplink.sec = 'wpa2'; S.uplink.wep = false; render(true); }
        else if (act === 'manual-off') { S.uplink.manual = false; S.uplink.ssid = ''; S.uplink.pick = -1; render(true); }
        else if (act === 'reboot') { api(QS + '?action=reboot', { method: 'POST' }).catch(function () {}); t.disabled = true; t.textContent = 'Rebooting…'; }
        else if (act === 'restart') { open(); }
        else if (act === 'finish') { stopTimers(); modal.hide(); }
    }

    // ── scanning (extender) ──────────────────────────────────────────────────
    function mapEnc(encStr) {
        var s = String(encStr == null ? '' : encStr).toUpperCase().trim();
        if (!s || s === 'NONE' || s === 'OPEN' || s === 'NO' || s === '-') return { sec: 'open', label: 'Open' };
        if (/WEP/.test(s)) return { sec: 'open', label: 'WEP', wep: true };
        var w2 = /WPA2/.test(s), w3 = /WPA3|SAE/.test(s), w1 = /WPA(?![23])/.test(s);
        if (w3 && w2) return { sec: 'wpa2wpa3', label: 'WPA2/WPA3' };
        if (w3) return { sec: 'wpa3', label: 'WPA3' };
        if (w1 && w2) return { sec: 'wpa12', label: 'WPA/WPA2' };
        if (w2) return { sec: 'wpa2', label: 'WPA2' };
        if (w1) return { sec: 'wpa', label: 'WPA' };
        return { sec: 'wpa2', label: 'Secured' };
    }

    function scan() {
        var u = S.uplink;
        if (u.scanning) return;
        u.scanning = true; u.aps = []; u.msg = ''; u.pick = -1; u.ssid = '';
        var band = u.band, iface = band === '5' ? 'wlan0' : 'wlan1', tries = 0;
        render(true);
        function attempt() {
            api('/cgi-bin/lme.cgi?action=sitesurvey_scan&iface=' + iface).then(function (d) {
                if (S.uplink.band !== band) return;                    // band changed meanwhile
                var aps = (d && d.aps) || [];
                if (!aps.length && ++tries < 3) { setTimeout(attempt, 4000); return; }
                var best = {};
                aps.forEach(function (ap) {
                    var ssid = (ap.ssid && ap.ssid !== '(hidden)') ? String(ap.ssid) : '';
                    var q = parseInt(ap.rssi, 10) || 0, dbm = q >= 0 ? q - 100 : q;
                    var m = mapEnc(ap.encryption);
                    var item = { ssid: ssid, channel: ap.channel, dbm: dbm, sec: m.sec, label: m.label, wep: !!m.wep };
                    if (!ssid) return;                                  // hidden: nothing to pick
                    if (!best[ssid] || best[ssid].dbm < dbm) best[ssid] = item;
                });
                u.aps = Object.keys(best).map(function (k) { return best[k]; }).sort(function (a, b) { return b.dbm - a.dbm; });
                u.scanned = true; u.scanning = false;
                if (!u.aps.length) u.msg = 'No networks found. If this band\'s WiFi is currently off, turn it on first, or enter the network manually.';
                render(true);
            }).catch(function (e) {
                u.scanning = false; u.scanned = true; u.msg = 'The scan failed (' + (e.message || e) + '). You can enter the network manually.';
                render(true);
            });
        }
        attempt();
    }

    // ── apply ────────────────────────────────────────────────────────────────
    function buildPayload() {
        var p = { mode: S.mode }, m = S.mode, w = S.wan, l = S.lan, d = S.dhcp;
        if (m !== 'extender') {
            p.up_type = S.up.type; p.up_pon = S.up.pon; p.up_port = S.up.port;
            p.wan_action = w.action;
            if (w.action === 'replace') {
                p.wan_type = m === 'ap' ? 'bridge' : w.type;
                p.wan_vlan = w.vlan ? 1 : 0; if (w.vlan) { p.wan_vid = w.vid; p.wan_vprio = w.vprio || 0; }
                if (m === 'router' && w.type === 'pppoe') { p.wan_user = w.user; p.wan_pass = w.pass; }
                if (m === 'router' && w.type === 'static') { p.wan_ip = w.ip; p.wan_mask = w.mask; p.wan_gw = w.gw; p.wan_dns1 = w.dns1; p.wan_dns2 = w.dns2; }
                if (m === 'ap') p.wan_bind = w.bind & ~(S.up.type === 'rj45' ? (1 << S.up.port) : 0);
            }
        }
        if (m === 'router') {
            p.lan_ip = l.ip; p.lan_mask = l.mask; p.dhcp_on = d.on ? 1 : 0;
            if (d.on) { p.dhcp_start = d.start; p.dhcp_end = d.end; p.dhcp_lease = d.lease; p.dhcp_dns_opt = d.dnsOpt; if (d.dnsOpt === 1) { p.dhcp_dns1 = d.dns1; p.dhcp_dns2 = d.dns2; } }
        } else {
            p.lan_mode = l.mode;
            if (l.mode === 'static') { p.lan_ip = l.ip; p.lan_mask = l.mask; p.lan_gw = l.gw; p.lan_dns1 = l.dns1; p.lan_dns2 = l.dns2; }
        }
        ['24', '5'].forEach(function (b) {
            var c = S.wifi['b' + b];
            if (S.ctx.locked && S.ctx.locked[b]) return;
            p['w' + b + '_on'] = c.on ? 1 : 0;
            if (c.on) { p['w' + b + '_ssid'] = c.ssid; p['w' + b + '_sec'] = c.sec; if (c.sec !== 'open') p['w' + b + '_pass'] = c.pass; }
        });
        if (m === 'extender') {
            var u = S.uplink, e = ENC[u.sec] || ENC.wpa2;
            p.up_band = u.band; p.up_ssid = u.ssid; p.up_enc = e.enc; p.up_uc = e.uc; p.up_u2c = e.u2c;
            if (e.enc !== 0) p.up_pass = u.pass;
        }
        return p;
    }

    function newUrl(ip) { return 'http://' + ip + (location.port ? ':' + location.port : '') + '/'; }

    function doApply() {
        var msg = validate('lan') || validate('wifi') || (S.mode === 'extender' ? validate('uplink') : validate('wan'));
        if (msg) { S.err = msg; render(true); return; }
        S.err = ''; applying = true;
        el.next.disabled = true;
        var body = new URLSearchParams(buildPayload()).toString();
        api(QS + '?action=apply', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body })
            .then(function (r) {
                if (!r.ok) { applying = false; S.err = r.detail || 'The device rejected these settings.'; render(true); return; }
                var ip = r.new_ip || '';
                S.apply = { phase: 'running', msg: 'Starting…', step: 0, total: 0, lost: false, fails: 0, newIp: ip, url: ip ? newUrl(ip) : '', probeUrl: ip ? newUrl(ip) : '', notes: [] };
                S.step = 'applying';
                render();
                pollStatus();
            })
            .catch(function (e) { applying = false; S.err = 'Could not send the settings: ' + (e.message || e); render(true); });
    }

    function pollStatus() {
        var a = S.apply;
        api(QS + '?action=status').then(function (r) {
            a.fails = 0; a.lost = false;
            if (r.phase === 'done' || r.phase === 'failed') {
                a.phase = r.phase; a.msg = r.msg; a.notes = r.notes || []; a.rebooting = !!r.rebooting; a.reboot_needed = !!r.reboot_needed;
                if (r.new_ip) { a.newIp = r.new_ip; a.url = newUrl(r.new_ip); a.probeUrl = a.url; }
                applying = false; S.step = 'done'; render();
                if (a.rebooting) waitForDevice();
                return;
            }
            a.msg = r.msg || a.msg; a.step = r.step; a.total = r.total;
            if (S.step === 'applying') render(true);
            pollTimer = setTimeout(pollStatus, 1500);
        }).catch(function () {
            // The job continues on the device even though this connection is gone.
            a.fails++;
            if (a.fails >= 3) { a.lost = true; if (S.step === 'applying') render(true); waitForDevice(true); return; }
            pollTimer = setTimeout(pollStatus, 1500);
        });
    }

    // After the connection dropped: keep trying the device (at the new address if
    // it has one) until it answers, then go there. A no-cors fetch resolves for
    // any reply, which is all that matters here.
    function waitForDevice(isLoss) {
        var a = S.apply, target = a.url || (location.origin + '/'), tries = 0;
        if (probeTimer) { clearTimeout(probeTimer); probeTimer = null; }
        function probe() {
            tries++;
            fetch(target + 'index.html?qs=' + Date.now(), { mode: 'no-cors', cache: 'no-store' }).then(function () {
                if (a.rebooting || a.lost) {
                    S.apply.phase = S.apply.phase === 'running' ? 'done' : S.apply.phase;
                    window.location.href = target;
                }
            }).catch(function () {
                if (tries < 120) probeTimer = setTimeout(probe, 3000);
            });
        }
        probeTimer = setTimeout(probe, a.rebooting ? 25000 : 4000);
    }

    window.lmeQuickSetup = { open: open };
}());
