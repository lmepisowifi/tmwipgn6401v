(function () {
    // ----------------------------------------------------------------
    // Auth — runs on every page that loads this file
    // ----------------------------------------------------------------
    fetch('/cgi-bin/check_auth.cgi')
        .then(r => r.text())
        .then(s => { if (s.trim() !== 'authenticated') window.location.href = '/login.html'; });

    window.logout = function () { window.location.href = '/cgi-bin/logout.cgi'; };

// Keepalive — ping check_auth every 1 minute to prevent session expiry
setInterval(function () {
    fetch('/cgi-bin/check_auth.cgi', { cache: 'no-store', keepalive: true })
        .then(r => r.text())
        .then(s => { if (s.trim() !== 'authenticated') window.location.href = '/login.html'; })
        .catch(function () {}); // ignore network errors silently
}, 1 * 60 * 1000); // 1 minute * 60 seconds * 1000 milliseconds

    // ================================================================
    // SITE META — singular favicon + title prefix for every page
    // ================================================================
    var SITE_TITLE  = 'PGN6401V';
    var FAVICON_URL = '/img/logo.png'; // change to .png if needed

    // Inject or replace favicon
    (function () {
        var existing = document.querySelector('link[rel~="icon"]');
        if (!existing) {
            existing = document.createElement('link');
            existing.rel = 'icon';
            document.head.appendChild(existing);
        }
        existing.href = FAVICON_URL;
    })();

    // ================================================================
    // NAV STRUCTURE — edit here to update every page at once
    // ================================================================
    var NAV = [
        { label: 'Home',  href: '/index.html' },
        { label: 'WLAN',  children: [
            { label: 'WiFi Basic',    href: '/wlanbasic.html'     },
            { label: 'Security',      href: '/wlansecurity.html'  },
            { label: 'Advanced',      href: '/wlanadvanced.html'  },
            { label: 'Site Survey',   href: '/sitesurvey.html'    },
            { label: 'MAC Filter',    href: '/wlanmac.html'       },
            { label: 'STA Info',  href: '/wlansta.html'     },
        ]},
        { label: 'LAN',     href: '/lan.html' },
        { label: 'Interfaces', children: [
            { label: 'DHCP Client', href: '/wan-repurpose.html' },
        ]},
        { label: 'Domain Blocking', href: '/domainblk.html' },
        { label: 'Hotspot', module: 'hotspot', children: [
            { label: 'Overview',        href: '/hotspot.html',           hotspot: 'always'  },
            { label: 'Interfaces',      href: '/hotspot-ifaces.html',    hotspot: 'always'  },
            { label: 'DHCP Settings',   href: '/hotspot-dhcp.html',      hotspot: 'always'  },
            { label: 'Income & Alerts', href: '/hotspot-income.html',    hotspot: 'always'  },
            { label: 'Portal',          href: '/hotspot-portal.html',    hotspot: 'always'  },
            { label: 'WiFi Rates',      href: '/hotspot-rates.html',     hotspot: 'enabled' },
            { label: 'NodeMCUs',        href: '/hotspot-nodemcus.html',  hotspot: 'enabled' },
            { label: 'Sessions',        href: '/hotspot-sessions.html',  hotspot: 'enabled' },
            { label: 'Vouchers',        href: '/hotspot-vouchers.html',  hotspot: 'enabled' },
            { label: 'Whitelist',       href: '/hotspot-whitelist.html', hotspot: 'enabled' },
        ]},
        { label: 'Terminal', href: '/terminal.html' },
        { label: 'System', children: [
            { label: 'Settings',         href: '/system.html'        },
            { label: 'Accounts',         href: '/accounts.html'      },
            { label: 'GPON Settings',    href: '/gpon.html'          },
            { label: 'Dashboard Layout', href: '/dashboard-layout.html' },
            { label: 'Modules',          href: '/modules.html'       },
            { label: 'Tailscale',        href: '/tailscale.html', module: 'tailscale' },
            { label: 'Software Update',  href: '/ota.html'           },
            { label: 'MIB Configuration', href: '/mibconfig.html'    },
            { label: 'Reboot',           href: '/reboot.html'        },
        ]},
    ];
    // ================================================================

    var path = location.pathname;

    function isActive(href) {
        return path === href ||
               path === href.replace(/^\//, '') ||
               (href !== '/' && path.endsWith(href));
    }

    // Set page title: "Page Label — SITE_TITLE"
    (function () {
        function findLabel(items) {
            for (var i = 0; i < items.length; i++) {
                var item = items[i];
                if (item.href && isActive(item.href)) return item.label;
                if (item.children) {
                    var found = findLabel(item.children);
                    if (found) return found;
                }
            }
            return null;
        }
        var label = findLabel(NAV);
        document.title = label ? label + ' \u2014 ' + SITE_TITLE : SITE_TITLE;
    })();

    function esc(s) {
        return s.replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function buildItems(items, hotspotRunning) {
        return items.map(function (item) {
            if (item.children) {
                // Filter hotspot sub-items based on running state
                var visibleChildren = item.children.filter(function (c) {
                    if (!c.hotspot) return true;             // non-hotspot items always show
                    if (c.hotspot === 'always') return true; // always visible (overview, interfaces)
                    return hotspotRunning;                   // 'enabled' items only when running
                });
                if (visibleChildren.length === 0) return '';
                var childActive = visibleChildren.some(function (c) { return isActive(c.href); });
                var children = visibleChildren.map(function (c) {
                    return '<li><a class="dropdown-item' + (isActive(c.href) ? ' active' : '') +
                           '" href="' + esc(c.href) + '">' + esc(c.label) + '</a></li>';
                }).join('');
                return '<li class="nav-item dropdown">' +
                    '<a class="nav-link dropdown-toggle' + (childActive ? ' active' : '') +
                    '" href="#" role="button" data-bs-toggle="dropdown">' + esc(item.label) + '</a>' +
                    '<ul class="dropdown-menu">' + children + '</ul>' +
                    '</li>';
            }
            return '<li class="nav-item">' +
                '<a class="nav-link' + (isActive(item.href) ? ' active' : '') +
                '" href="' + esc(item.href) + '">' + esc(item.label) + '</a>' +
                '</li>';
        }).join('');
    }

    // Capture before any async so it stays valid inside .then() callbacks
    var _script = document.currentScript;

    function buildNavHtml(filteredNAV, hotspotRunning) {
        return [
            '<nav class="navbar navbar-expand-lg bg-body-tertiary">',
            '  <div class="container-fluid">',
            '    <a class="navbar-brand d-flex align-items-center" href="/index.html">',
            '      <img src="/img/logo.png" alt="Icon" class="header-icon">',
            '      <div class="header-divider"></div>',
            '      <span class="brand-text">PGN6401V</span>',
            '    </a>',
            '    <button class="navbar-toggler" type="button"',
            '            data-bs-toggle="collapse" data-bs-target="#navbarNav">',
            '      <span class="navbar-toggler-icon"></span>',
            '    </button>',
            '    <div class="collapse navbar-collapse" id="navbarNav">',
            '      <ul class="navbar-nav me-auto">',
                       buildItems(filteredNAV, hotspotRunning),
            '      </ul>',
            '      <button class="btn btn-outline-danger" onclick="logout()">Logout</button>',
            '    </div>',
            '  </div>',
            '</nav>',
        ].join('\n');
    }

    function renderNav(showGpon, hotspotRunning, installedMap) {
        function modOk(m){ return !m || (installedMap && installedMap[m]); }
        var filteredNAV = NAV
            // Hide whole groups (e.g. Hotspot) whose module isn't installed.
            .filter(function(item) { return modOk(item.module); })
            .map(function(item) {
                if (!item.children) return item;
                var fc = item.children.filter(function(c) {
                    if (!modOk(c.module)) return false;   // hide pages (e.g. Tailscale) whose module isn't installed
                    return c.href !== '/gpon.html' || showGpon;
                });
                return { label: item.label, href: item.href, module: item.module, children: fc };
            });
        _script.insertAdjacentHTML('beforebegin', buildNavHtml(filteredNAV, hotspotRunning));
    }

    // Fetch system_status (for GPON visibility) and hotspot status (for Hotspot sub-items)
    // in parallel — render nav only after both resolve so items are correct first paint.
    Promise.all([
        fetch('/cgi-bin/lme.cgi?action=system_status', { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .catch(function() { return {}; }),
        fetch('/cgi-bin/hotspot.cgi?action=config_get', { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .catch(function() { return {}; }),
        fetch('/cgi-bin/modules.cgi?action=list', { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .catch(function() { return null; })
    ]).then(function(results) {
        var sys = results[0]; var hsp = results[1]; var mod = results[2];
        var isGpon = (String(sys.pon_mode) === '1');
        var hotspotRunning = (hsp.hotspot_running === true);
        // Safe defaults: keep an existing hotspot visible on a transient error;
        // tailscale is opt-in so it stays hidden unless the registry confirms it.
        var installedMap = { hotspot: true, tailscale: false };
        if (mod && mod.ok && mod.modules) {
            installedMap = {};
            mod.modules.forEach(function(m){ installedMap[m.id] = (m.installed === true); });
        }
        renderNav(isGpon, hotspotRunning, installedMap);
    }).catch(function() { renderNav(true, false, { hotspot: true, tailscale: false }); });
}());

