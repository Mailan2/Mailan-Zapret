[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $root "config\official-links.json"
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$links = @($config.links)

while ($true) {
    Write-Host ""
    Write-Host "Verified official websites:"
    for ($index = 0; $index -lt $links.Count; $index++) {
        Write-Host ("[{0}] {1} - {2}" -f ($index + 1), $links[$index].name, $links[$index].url)
    }
    Write-Host "[Q] close"
    Write-Host ""

    $selection = (Read-Host "Website number").Trim()
    if ($selection -match '^[qQ]$') {
        break
    }

    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $links.Count) {
        Write-Host "Enter a number from 1 to $($links.Count), or Q." -ForegroundColor Yellow
        continue
    }

    $url = [Uri]$links[$number - 1].url
    if ($url.Scheme -ne "https") {
        Write-Host "Blocked non-HTTPS address: $url" -ForegroundColor Red
        continue
    }

    Start-Process -FilePath "explorer.exe" -ArgumentList $url.AbsoluteUri
}
