[中文](/README.md) | English

# Xray Management Script :sparkles:

A pure-Shell Xray deployment and management script, supporting REALITY, XHTTP, SNI splitting, WARP routing and custom reverse-proxy sites.

- **Zero-dependency install** — one `wget` command starts the interactive installer
- **Five built-in profiles** — Vision / XHTTP / Trojan / Fallback / SNI
- **Menu-driven** — install, start/stop, share links, routing and certificates
- **Bilingual** — JSON files under `i18n/`, easy to extend
- **BBR acceleration** — enabled on first quick install, toggleable from the menu

## Profiles

| # | Profile | Description |
| --- | --- | --- |
| 1 | `VLESS + Vision + REALITY` | XTLS Vision solves TLS-in-TLS |
| 2 | `VLESS + XHTTP + REALITY` | Works in all scenarios, multiplexed by default |
| 3 | `Trojan + XHTTP + REALITY` | VLESS replaced by Trojan |
| 4 | Dual protocol | Vision fallback to XHTTP on port 443 |
| 5 | SNI split | Nginx SNI routing, REALITY direct and CDN coexist |

The SNI profile additionally supports:

- Nginx SNI splitting — suitable for CDN, upstream/downstream separation and multi-site hosting
- Split share links (uplink `xhttp+TLS+CDN` / downlink `xhttp+Reality`, or the reverse)
- Custom domains and reverse-proxy apps, each with its own certificate, site config, stream mapping and UDS

## Routing

- Block BitTorrent traffic (optional)
- Block China-bound IP traffic (optional)
- Block ad domains (optional)
- Custom block / WARP routes
- Cloudflare WARP Proxy toggle (Docker)
- geodata auto-update toggle

## BBR Acceleration

The first quick install (`--vision` / `--xhttp` / `--fallback`) enables TCP BBR
(congestion control `bbr` + qdisc `fq`) automatically. The setting is persisted in
`/etc/sysctl.d/99-xrayscript-bbr.conf`, so it survives reboots.

- Menu: `Configuration Management` → `Enable/Disable BBR`
- CLI: `bash /usr/local/xrayscript/core/handler.sh --bbr toggle|enable|disable|status`
- On kernels without BBR (some OpenVZ / LXC containers) it warns and skips; other features are unaffected
- If you disable it manually, a later quick install will not force it back on

## Traffic Statistics

The `Traffic Statistics` entry opens a submenu to show, enable, disable and reset
traffic statistics.

- Show: summarise accumulated traffic by inbound / outbound / user
- Enable: turn on Xray Stats API collection (`stats` + `policy` counters); restarts Xray
- Disable: stop collecting to reduce overhead and drop the counters; restarts Xray
- Reset: keep the switch as is and only zero the counters (no restart)
- CLI: `bash /usr/local/xrayscript/core/handler.sh --traffic show|enable|disable|reset|status`
- The switch is stored as `.system.stats`, so it survives reinstall and port changes
- Select `0` in the submenu to go back to the main menu; after any action the main
  menu is shown again, and `0` there exits

## Defaults and Customisation

| Parameter | Default | Custom |
| --- | --- | --- |
| Port | default 443 | 1-65535 |
| UUID | randomly generated | standard UUID, or any string mapped by Xray |
| trojan password | randomly generated | any input |
| target | random pick from the domain pool | TLS 1.3 and H2 validation, automatic serverNames |
| shortId | random (two by default, length 8 and 16) | input `0`-`8` to auto-generate that length; comma-separated values |
| path | randomly generated | leading `/` optional |

## Quick Start

**Download and launch the menu:**

```sh
wget --no-check-certificate -O ${HOME}/xrayscript-install.sh https://raw.githubusercontent.com/dakerclaw/xrayscript/main/install.sh && bash ${HOME}/xrayscript-install.sh
```

**Step by step:**

```sh
# 1. Download
wget --no-check-certificate -O ${HOME}/xrayscript-install.sh https://raw.githubusercontent.com/dakerclaw/xrayscript/main/install.sh

# 2. Open the interactive menu
bash ${HOME}/xrayscript-install.sh

# 3. Or install a profile directly
bash ${HOME}/xrayscript-install.sh --vision     # VLESS + Vision + REALITY
bash ${HOME}/xrayscript-install.sh --xhttp      # VLESS + XHTTP + REALITY
bash ${HOME}/xrayscript-install.sh --fallback   # Vision + XHTTP composite
```

## Interface Preview

```sh
--------------- xrayscript ------------------
Version      : v2026.11.01
Description  : xrayscript Management Script
------------------ Installation ------------------
1. Full Installation
2. Install/Update Only
3. Uninstall
------------------ Operation ------------------
4. Start
5. Stop
6. Restart
------------------ Configuration ------------------
7. Share Link & QR Code
8. Traffic Statistics
9. Manage Configuration
------------------------------------------------------
0. Exit
```

## FAQ

1. Installed but unusable: make sure the port is open, check with `https://tcp.ping.pe/ip:port`.
2. Before using SNI, ensure ports 80 and 443 are open on the VPS.
3. Do not enable CDN protection before using SNI, or certificate issuance will fail.
4. Split-link details: see [XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113) and [xhttp five-in-one](https://github.com/XTLS/Xray-core/discussions/4118).
5. `Could not get nonce, let's try again` when issuing a certificate: check the [ZeroSSL status page](https://status.zerossl.com/) — their free ACME service is likely disrupted.

## Project Layout

```text
.
├── install.sh              # Bootstrap: download project, install deps, launch menu
├── config.json             # Script config (version, language, generated parameters)
├── core/
│   ├── common.sh           # Shared library: OS detection, i18n cache, logging, JSON helpers
│   ├── main.sh             # Main dispatcher
│   ├── menu.sh             # Menu rendering
│   ├── handler.sh          # Core operations (install/config/routing/sites/certs)
│   ├── read.sh             # Interactive input
│   ├── check.sh            # Input validation and connectivity checks
│   ├── generate.sh         # UUID / password / shortId / path generators
│   └── share.sh            # Share links and QR codes
├── service/
│   ├── nginx.sh            # Nginx source build, install, smooth upgrade
│   ├── ssl.sh              # acme.sh certificate issuance and renewal
│   └── docker.sh           # Docker / WARP / Cloudreve container management
├── tool/
│   ├── geodata.sh          # geoip / geosite updater
│   ├── bbr.sh              # TCP BBR acceleration switch
│   └── traffic.sh          # Traffic statistics
├── i18n/                   # Translations (zh.json / en.json)
└── config/                 # Xray and Nginx templates
```

## Install Locations

| Component | Path |
| --- | --- |
| Script | `/usr/local/xrayscript` |
| Script config | `$HOME/.xrayscript/config.json` |
| Nginx | `/usr/local/nginx` |
| Cloudreve | `$HOME/.xrayscript/docker/cloudreve` |
| Cloudflare-warp | `$HOME/.xrayscript/docker/warp` |
| WARP container | `xrayscript-warp` |
| Xray | see [Xray-install](https://github.com/XTLS/Xray-install) |

## Dependencies

The following packages may be installed automatically when using the SNI profile.

| Purpose | Debian-based | Red Hat-based |
| --- | --- | --- |
| IP / routing | `iproute2` | `iproute` |
| DNS lookup | `dnsutils` | `bind-utils` |
| Download / certs | `wget` `curl` `ca-certificates` | `wget` `curl` `ca-certificates` |
| Process tools | `procps` | `procps-ng` |
| Cron | `cron` | `crontabs` |
| Firewall (one of) | `ufw` | `firewalld` |
| **Build base** | `gcc` `g++` `make` `tar` `gzip` `git` | `gcc` `gcc-c++` `make` `tar` `gzip` `git` |
| **acme.sh** | `openssl` | `openssl` |
| **Build OpenSSL** | `libperl-dev` | `perl-devel` `perl-IPC-Cmd` `perl-Getopt-Long` `perl-Data-Dumper` `perl-FindBin` |
| **Build Brotli** | `libbrotli-dev` | `brotli-devel` |
| **Build Nginx** | `libpcre2-dev` `zlib1g-dev` `libxml2-dev` `libxslt1-dev` `libgd-dev` `libgeoip-dev` `libgoogle-perftools-dev` | `pcre2-devel` `zlib-devel` `libxml2-devel` `libxslt-devel` `gd-devel` `geoip-devel` `gperftools-devel` `perl-ExtUtils-Embed` |

## Installation Time

The SNI profile compiles Nginx from source, so the first install is slow (roughly 15-20 minutes on a 1-core / 1 GB machine). It is meant to be installed once and kept.

Source builds start faster (built with `-O3`) and ship newer versions; the trade-off is compile time.

Switching away from SNI stops Nginx but keeps it installed, so re-enabling SNI does not rebuild it.

## Disclaimer

This project is for learning and technical exchange only. Use it in compliance with the laws and regulations of your country or region. You are solely responsible for your usage.

[XHTTP]: https://github.com/XTLS/Xray-core/discussions/4113
