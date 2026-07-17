# Mailan Zapret

Personal Windows wrapper for running a local Zapret/winws profile.

The project includes the official Zapret v72.12 Windows binary, matching
WinDivert files, Cygwin and blockcheck.sh from the same bundle.

Use this only on networks and devices where you are allowed to change traffic
handling.

## Layout

- `mailan-zapret.cmd` - console launcher.
- `mailan-zapret-admin.cmd` - console launcher with Administrator prompt.
- `mailan-official-links.cmd` - verified official website directory.
- `scripts\mailan-zapret.ps1` - start, stop, status and diagnostics.
- `scripts\mailan-update.ps1` - HTTPS update check, download and verification.
- `scripts\apply-update.ps1` - applies a verified update after Zapret exits.
- `config\profiles.json` - profiles and winws arguments.
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
2. The launcher checks `Mailan1.ru` for a newer version and asks before downloading.
3. Select a numbered bypass strategy, or press `B` for blockcheck.sh.
   Press `L` to open the verified official website directory.
4. Keep the Zapret console open while using the selected strategy.

Closing that console stops Zapret.

You can also run commands manually from PowerShell or Command Prompt:

```powershell
.\mailan-zapret.cmd doctor
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

## Profiles

All profiles include YouTube, Discord, Facebook, Telegram Web and the additional
service hostlist. Telegram WebSocket domains receive the selected TLS bypass
strategy, while Telegram's official IP ranges have a separate TCP profile for
ports 80, 443, 5222 and 5223.

While the console is open, Windows temporarily prefers IPv4. This avoids a
broken IPv6 VPN route preventing Telegram Web from reaching its API servers.
The original prefix policy is restored when the console exits, including when
the window is closed. The launcher does not restart or reconfigure VPN adapters,
and never modifies the Windows HOSTS file or browser settings. If Yandex Browser
was already open, restart it with `Ctrl+Shift+Q` after starting Zapret so it picks
up the current VPN route.

To preview the exact command without starting anything:

```powershell
.\mailan-zapret.cmd start -Profile safe -DryRun
```

Run blockcheck only while every Zapret console and other DPI bypass tool is
stopped. Its report is saved to `vendor\blockcheck\blockcheck.log`.

## Updates

Normal menu startup checks
`https://mailan1.ru/zapret/update.json`. Network or server failures do
not prevent Zapret from starting. The user is prompted only when the manifest
contains a version newer than `config\version.json`.

Accepted updates are downloaded over HTTPS, limited in size, verified against
the manifest SHA-256 value, safely extracted, and checked for a matching embedded
version before installation. A running `winws` process blocks installation so
the current connection is never replaced underneath it.

Server publishing instructions and the manifest format are documented in
`UPDATE-SERVER.md`.
