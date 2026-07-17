# Mailan Zapret update server

The launcher checks this HTTPS URL on every normal menu start:

`https://mailan1.ru/zapret/update.json`

Upload a JSON document using the format in
`update-server\update.json.example`. The archive URL must use HTTPS and the host
must be listed in `config\version.json`.

The ZIP archive must contain the project files directly at its root. It must
include at least:

- `mailan-zapret.cmd`
- `scripts\mailan-zapret.ps1`
- `scripts\mailan-update.ps1`
- `scripts\apply-update.ps1`
- `config\version.json`

Set `config\version.json` inside the archive to the same numeric version as the
manifest. Do not place a `runtime` directory in the archive.

Create the SHA-256 value after building the ZIP:

```powershell
(Get-FileHash .\mailan-zapret-1.0.1.zip -Algorithm SHA256).Hash.ToLowerInvariant()
```

Place that 64-character value in `update.json`, upload the ZIP, and then upload
the manifest last. Clients download only after asking the user and install only
when the archive hash and embedded version both match.

## GitHub Releases

The launcher also checks the latest stable release at
`https://github.com/Mailan2/Mailan-Zapret/releases`. Create a tag in the form
`v1.0.4`, then attach both files produced by `publish-update.ps1`:

- `mailan-zapret-1.0.4.zip`
- `mailan-zapret-1.0.4.zip.sha256`

The ZIP name must match the numeric tag version. The updater checks the SHA-256
value before installation and ignores prereleases. Upload the checksum asset
with the archive; a release without one is never offered for installation.

## Publish an update

Build the archive and manifest for the local development site:

```powershell
.\scripts\publish-update.ps1 -Version 1.0.1
```

For the production site, publish directly into its update storage and use the
public HTTPS download URL:

```powershell
.\scripts\publish-update.ps1 -Version 1.0.1 `
  -BaseUrl "https://mailan1.ru/zapret/download" `
  -OutputDirectory "C:\path\to\webic\storage\zapret-updates"
```

`config\version.local.json` switches this development copy to
`http://localhost:25589`. It is ignored by Git and excluded from release
archives. HTTP is accepted only for `localhost`, `127.0.0.1`, or `::1`; normal
clients continue to require HTTPS.
