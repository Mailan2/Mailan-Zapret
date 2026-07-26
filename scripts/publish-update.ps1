[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$BaseUrl = "http://localhost:25589/zapret/download",
    [string]$OutputDirectory,
    [string]$Notes = "Mailan Zapret update $Version"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RuntimeDirectory = Join-Path $Root "runtime"
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $Root) "webic\storage\zapret-updates"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$baseUri = $null
if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or `
    $baseUri.Scheme -notin @("http", "https")) {
    throw "BaseUrl must be an absolute HTTP or HTTPS URL."
}
if (-not [string]::IsNullOrEmpty($baseUri.Query) -or -not [string]::IsNullOrEmpty($baseUri.Fragment)) {
    throw "BaseUrl cannot contain a query string or fragment."
}

[void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$token = [Guid]::NewGuid().ToString("N")
$stagingPath = Join-Path $RuntimeDirectory "publish-stage-$token"
$temporaryArchivePath = Join-Path $RuntimeDirectory "publish-$token.zip"
$fileName = "mailan-zapret-$Version.zip"
$archivePath = Join-Path $OutputDirectory $fileName
$checksumPath = Join-Path $OutputDirectory "$fileName.sha256"
$manifestPath = Join-Path $OutputDirectory "update.json"
$temporaryManifestPath = Join-Path $OutputDirectory "update-$token.json"

function Remove-VerifiedRuntimePath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $runtimeRoot = [IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd('\') + '\'
    $resolvedTarget = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedTarget.StartsWith($runtimeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the runtime directory: $resolvedTarget"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

try {
    [void](New-Item -ItemType Directory -Path $stagingPath)
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.Name -in @("runtime", ".git")) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $stagingPath -Recurse -Force
    }

    foreach ($localConfigName in @("version.local.json", "kazakhstan-proxy.local.json", "telegram-proxy.local.json", "language.local.json", "network-selection.local.json")) {
        $localConfigCopy = Join-Path $stagingPath (Join-Path "config" $localConfigName)
        if (Test-Path -LiteralPath $localConfigCopy) {
            Remove-Item -LiteralPath $localConfigCopy -Force
        }
    }

    $packagedVersionPath = Join-Path $stagingPath "config\version.json"
    $packagedConfig = Get-Content -LiteralPath $packagedVersionPath -Raw | ConvertFrom-Json
    $packagedConfig.version = $Version
    $packagedConfigJson = $packagedConfig | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($packagedVersionPath, $packagedConfigJson, $Utf8NoBom)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingPath,
        $temporaryArchivePath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $hash = (Get-FileHash -LiteralPath $temporaryArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Move-Item -LiteralPath $temporaryArchivePath -Destination $archivePath -Force
    [IO.File]::WriteAllText($checksumPath, "$hash  $fileName`n", $Utf8NoBom)

    $manifestJson = [pscustomobject]@{
        version = $Version
        url = $BaseUrl.TrimEnd('/') + "/" + $fileName
        sha256 = $hash
        notes = $Notes
    } | ConvertTo-Json
    [IO.File]::WriteAllText($temporaryManifestPath, $manifestJson, $Utf8NoBom)
    Move-Item -LiteralPath $temporaryManifestPath -Destination $manifestPath -Force

    Write-Host "Published Mailan Zapret $Version" -ForegroundColor Green
    Write-Host "Archive:  $archivePath"
    Write-Host "Manifest: $manifestPath"
    Write-Host "SHA-256:  $hash"
}
finally {
    Remove-VerifiedRuntimePath -Path $stagingPath
    Remove-VerifiedRuntimePath -Path $temporaryArchivePath
    if (Test-Path -LiteralPath $temporaryManifestPath) {
        Remove-Item -LiteralPath $temporaryManifestPath -Force
    }
}
