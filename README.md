# Mailan Zapret

Personal Windows wrapper for running a local Zapret/winws profile.

The project includes the official Zapret v72.12 Windows binary, matching
WinDivert files, Cygwin and blockcheck.sh from the same bundle.

The root `bin` runtime files are included in GitHub downloads. If a source ZIP
was created without them, the launcher restores the verified local copies from
`vendor` on its first run.

Use this only on networks and devices where you are allowed to change traffic
handling.

## Layout

- `mailan-zapret.cmd` - console launcher.
- `mailan-zapret-admin.cmd` - console launcher with Administrator prompt.
- `mailan-official-links.cmd` - verified official website directory.
- `scripts\mailan-network.ps1` - network calibration and the default launcher mode.
- `scripts\mailan-zapret.ps1` - legacy profiles, blockcheck and diagnostics.
- `scripts\mailan-update.ps1` - HTTPS update check, download and verification.
- `scripts\apply-update.ps1` - applies a verified update after Zapret exits.
- `config\profiles.json` - profiles and winws arguments.
- `config\network-profiles.json` - isolated calibration profiles and HTTPS checks.
- `config\translations.json` - Russian and English launcher text.
- `config\version.json` - installed version and update endpoint.
- `hostlists\youtube.txt` - common YouTube domains.
- `hostlists\discord.txt` - common Discord domains.
- `hostlists\facebook.txt` - Facebook, Messenger and Meta CDN domains.
- `hostlists\telegram.txt` - common Telegram domains.
- `hostlists\openai.txt` - OpenAI, ChatGPT, static assets and user content domains.
- `hostlists\global-platforms.txt` - Cloudflare, Claude, TikTok, Netflix and their media/CDN domains.
- `hostlists\services.txt` - WhatsApp, news, privacy tools, Instagram, APKMirror and Google.
- `hostlists\vpn-services.txt` - VPN provider websites, accounts and download CDNs.
- `vendor\blockcheck\` - official blockcheck.sh Windows bundle.
- `runtime\` - generated PID and optional runtime files.

## Quick start

1. Run `mailan-zapret.cmd` and approve the Administrator prompt.
2. If this was downloaded from GitHub, the launcher restores its bundled winws and
   WinDivert files automatically on the first run.
3. The launcher checks `Mailan1.ru` for a newer version and asks before downloading.
4. The Network launcher detects whether the current connection has a saved
   calibration. On a new network, select `Calibrate and start`.
5. It starts three isolated WinDivert profiles in turn and checks HTTPS access
   to YouTube, Telegram Web, Discord and ChatGPT. The highest scoring profile
   is saved only for the current network fingerprint.
6. Keep the Zapret console open while using the selected profile.

Closing that console stops Zapret.

You can also run commands manually from PowerShell or Command Prompt:

```powershell
.\mailan-zapret.cmd doctor
.\mailan-zapret.cmd network status
.\mailan-zapret.cmd network calibrate
.\mailan-zapret.cmd network args -Profile balanced
.\mailan-zapret.cmd network reset
.\mailan-zapret.cmd language
.\mailan-zapret.cmd bootstrap
.\mailan-zapret.cmd proxy-setup
.\mailan-zapret.cmd proxy-enable
.\mailan-zapret.cmd proxy-disable
.\mailan-zapret.cmd proxy-status
.\mailan-zapret.cmd proxy-stop
.\mailan-zapret.cmd args -Profile safe
.\mailan-zapret.cmd console -Profile safe
.\mailan-zapret.cmd start -Profile safe
.\mailan-zapret.cmd status -Profile safe
.\mailan-zapret.cmd check-update
```

Stop it with:

```powershell
.\mailan-zapret.cmd stop -Profile safe
```

Restart it with:

```powershell
.\mailan-zapret.cmd restart -Profile safe
```

`console` runs winws in the current console window. `start` runs it in the
background and stores a PID in `runtime\`.

## Network Calibration

The default launcher is designed for different providers and routes. It does
not assume that a profile which works at one home network will work elsewhere.
It keeps the selected profile in `config\network-selection.local.json`; this
file stores a one-way fingerprint of the default route and DNS servers, never
proxy credentials or browsing history, and is excluded from updates.

Calibration temporarily starts one profile at a time, performs only HTTPS HEAD
connectivity checks to the listed public targets, stops that profile, then starts
the selected profile in the visible console. If no candidate reaches a service,
run the official `blockcheck` command from the legacy menu instead of assuming a
single universal setting exists.

## Kazakhstan site proxy

`proxy-setup` creates a local, machine-protected SOCKS5 configuration for the
Kazakhstan site proxy. It is disabled by default and is not needed for users in
Russia. It never stores credentials in tracked files or update archives. A
Kazakhstan user can enable it with `proxy-enable`; while Zapret is running,
system-proxy browsers then use a local PAC rule that routes only Pornhub, its
`phncdn.com` content domains, and Tor Project through `127.0.0.1`. All other
traffic remains direct. `proxy-disable` turns this optional feature off and
stops an already running Kazakhstan gateway.

`telegram-proxy-setup` creates a separate Russia Telegram configuration. It
routes only Telegram domains through its own local PAC gateway while Zapret is
running. This browser route does not change the Telegram Desktop application's
own proxy setting. Only one regional proxy can be enabled at a time.

The local gateway accepts traffic only on `127.0.0.1` and only for those three
domain families. It is stopped and the previous Windows proxy setting is
restored when Zapret stops. Chrome, Edge and Yandex Browser use this Windows
PAC rule after a full browser restart. Firefox must be configured to use
Windows system proxy settings to follow it.

## Profiles

All profiles include YouTube, Discord, Facebook, Telegram Web and the additional
service hostlist. Telegram WebSocket domains receive the selected TLS bypass
strategy, while Telegram's official IP ranges have a separate TCP profile for
ports 80, 443, 5222 and 5223.

In addition to `safe`, `fast` and the official preset, the strategy menu offers
three targeted fallback profiles: `hostfake` for fake-host TLS segmentation,
`seqovl` for TLS sequence overlap, and `fakeddisorder` for reverse-order fake
segmentation. Use one alternative at a time and keep the first profile that
works reliably on the current provider. `blockcheck.sh` remains the preferred
way to measure a provider instead of guessing.

`telegram-ws` is a Telegram Web-specific profile. It handles only the Telegram
hostlist, including `web.telegram.org`, `webk.telegram.org` and the `kws*.web.telegram.org`
WebSocket endpoints. It is intended for the browser version of Telegram and
does not route other listed services through the same stronger strategy. It
intentionally bypasses the optional external Telegram SOCKS5 gateway so a
provider-side SOCKS5 destination rejection cannot break Telegram Web.

TGLock is a separate Telegram Desktop SOCKS5/WebSocket tool. It can complement
Zapret for the native Telegram application, but it does not proxy the
`web.telegram.org` browser page itself; keep it separate from this distribution
unless its upstream binary is independently reviewed and obtained by the user.

Profiles leave Windows network preference unchanged. The launcher does not
restart or reconfigure VPN adapters,
and never modifies the Windows HOSTS file or browser profiles. The optional
Kazakhstan site proxy temporarily changes only the Windows automatic-proxy URL
while Zapret is running.

To preview the exact command without starting anything:

```powershell
.\mailan-zapret.cmd start -Profile safe -DryRun
```

Run blockcheck only while every Zapret console and other DPI bypass tool is
stopped. Its report is saved to `vendor\blockcheck\blockcheck.log`.

## Updates

Normal menu startup checks `https://mailan1.ru/zapret/update.json` and the
latest stable GitHub Release from `Mailan2/Mailan-Zapret`. Network or server
failures do not prevent Zapret from starting. The user is prompted only when a
source contains a version newer than `config\version.json`; the newest verified
release wins.

Accepted updates are downloaded over HTTPS, limited in size, verified against
the manifest SHA-256 value, safely extracted, and checked for a matching embedded
version before installation. A running `winws` process blocks installation so
the current connection is never replaced underneath it.

Server publishing instructions and the manifest format are documented in
`UPDATE-SERVER.md`.

## GitHub distribution

Commit the files in `bin` when publishing the repository: `winws.exe`,
`WinDivert.dll`, `WinDivert64.sys`, and `cygwin1.dll`. People who downloaded an
older source ZIP should download the latest ZIP again after it is published, or
run `mailan-zapret.cmd bootstrap` after receiving the updated launcher script.
