[CmdletBinding()]
param(
    [ValidateSet("check")]
    [string]$Command = "check",

    [switch]$Interactive,
    [switch]$ShowErrors,
    [string]$ManifestFile,
    [int]$ParentPid = $PID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$VersionConfigPath = Join-Path $Root "config\version.json"
$LocalVersionConfigPath = Join-Path $Root "config\version.local.json"

function Read-VersionConfig {
    if (-not (Test-Path -LiteralPath $VersionConfigPath)) {
        throw "Version configuration not found: $VersionConfigPath"
    }
    $config = Get-Content -LiteralPath $VersionConfigPath -Raw | ConvertFrom-Json
    if (Test-Path -LiteralPath $LocalVersionConfigPath) {
        $localConfig = Get-Content -LiteralPath $LocalVersionConfigPath -Raw | ConvertFrom-Json
        foreach ($property in $localConfig.PSObject.Properties) {
            $config | Add-Member -MemberType NoteProperty -Name $property.Name `
                -Value $property.Value -Force
        }
    }
    return $config
}

function ConvertTo-MailanVersion {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$FieldName
    )

    $parsed = $null
    if (-not [Version]::TryParse($Value, [ref]$parsed) -or $parsed.Major -lt 0) {
        throw "Invalid $FieldName version: $Value"
    }
    return $parsed
}

function Assert-AllowedUpdateUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [Parameter(Mandatory)][string]$Name,
        [bool]$AllowHttpLoopback = $false
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "$Name must be an absolute URL."
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$Name cannot contain credentials."
    }

    $uriHost = $uri.Host.Trim('[', ']').ToLowerInvariant()
    $isLoopback = $uriHost -in @("localhost", "127.0.0.1", "::1")
    $isAllowedScheme = $uri.Scheme -eq "https" -or `
        ($AllowHttpLoopback -and $uri.Scheme -eq "http" -and $isLoopback)
    if (-not $isAllowedScheme) {
        throw "$Name must use HTTPS. HTTP is allowed only for an enabled loopback development server."
    }
    if ($uriHost -notin $AllowedHosts) {
        throw "$Name host is not allowed: $uriHost"
    }
    return $uri
}

function Get-UpdateManifest {
    param(
        [Parameter(Mandatory)]$VersionConfig,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [bool]$AllowHttpLoopback = $false
    )

    if ($ManifestFile) {
        if (-not (Test-Path -LiteralPath $ManifestFile)) {
            throw "Manifest file not found: $ManifestFile"
        }
        return Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    }

    $manifestUri = Assert-AllowedUpdateUrl -Url ([string]$VersionConfig.manifest_url) `
        -AllowedHosts $AllowedHosts -Name "Update manifest URL" `
        -AllowHttpLoopback $AllowHttpLoopback
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return Invoke-RestMethod -Uri $manifestUri.AbsoluteUri -Method Get -TimeoutSec 8 `
        -Headers @{ "Cache-Control" = "no-cache"; "User-Agent" = "Mailan-Zapret-Updater/1" }
}

function Get-RequiredManifestValue {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Manifest.PSObject.Properties[$Name]
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Update manifest field '$Name' is required."
    }
    return [string]$property.Value
}

function Expand-VerifiedArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            if ($relative -match '^(?i)runtime(?:\|$)') {
                throw "Update archives cannot contain the runtime directory."
            }

            $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe path in update archive: $($entry.FullName)"
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                [void](New-Item -ItemType Directory -Path $target -Force)
                continue
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Create($target)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Start-MailanUpdate {
    param(
        [Parameter(Mandatory)]$VersionConfig,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][Version]$RemoteVersion,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [bool]$AllowHttpLoopback = $false
    )

    $downloadUrl = Get-RequiredManifestValue -Manifest $Manifest -Name "url"
    $downloadUri = Assert-AllowedUpdateUrl -Url $downloadUrl -AllowedHosts $AllowedHosts `
        -Name "Update archive URL" -AllowHttpLoopback $AllowHttpLoopback
    $expectedHash = (Get-RequiredManifestValue -Manifest $Manifest -Name "sha256").Trim().ToLowerInvariant()
    if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
        throw "Update manifest sha256 must contain exactly 64 hexadecimal characters."
    }

    $runningWinws = @(Get-Process -Name "winws", "winws2" -ErrorAction SilentlyContinue)
    if ($runningWinws.Count -gt 0) {
        throw "Close every running Zapret console before installing an update."
    }

    $runtimeDir = Join-Path $Root "runtime"
    [void](New-Item -ItemType Directory -Path $runtimeDir -Force)
    $token = [Guid]::NewGuid().ToString("N")
    $archivePath = Join-Path $runtimeDir "update-$RemoteVersion-$token.zip"
    $stagingPath = Join-Path $runtimeDir "update-stage-$token"
    $planPath = Join-Path $runtimeDir "update-plan-$token.json"

    Write-Host "Downloading Mailan Zapret $RemoteVersion..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -OutFile $archivePath -UseBasicParsing `
        -TimeoutSec 120 -Headers @{ "User-Agent" = "Mailan-Zapret-Updater/1" }

    $maxBytes = [int64]$VersionConfig.max_archive_mb * 1MB
    $archiveInfo = Get-Item -LiteralPath $archivePath
    if ($archiveInfo.Length -le 0 -or $archiveInfo.Length -gt $maxBytes) {
        throw "Downloaded update has an invalid size: $($archiveInfo.Length) bytes."
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Update SHA-256 verification failed. The archive was not installed."
    }

    Expand-VerifiedArchive -ArchivePath $archivePath -Destination $stagingPath
    foreach ($requiredFile in @(
        "mailan-zapret.cmd",
        "scripts\mailan-zapret.ps1",
        "scripts\mailan-update.ps1",
        "scripts\apply-update.ps1",
        "config\version.json"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagingPath $requiredFile))) {
            throw "Update archive is missing required file: $requiredFile"
        }
    }
    $stagedVersionConfig = Get-Content -LiteralPath (Join-Path $stagingPath "config\version.json") -Raw | ConvertFrom-Json
    $stagedVersion = ConvertTo-MailanVersion -Value ([string]$stagedVersionConfig.version) -FieldName "archive"
    if ($stagedVersion -ne $RemoteVersion) {
        throw "Archive version $stagedVersion does not match manifest version $RemoteVersion."
    }

    [pscustomobject]@{
        root = $Root
        staging = $stagingPath
        archive = $archivePath
        parent_pid = $ParentPid
        version = $RemoteVersion.ToString()
        launcher = (Join-Path $Root "mailan-zapret.cmd")
    } | ConvertTo-Json | Set-Content -LiteralPath $planPath -Encoding UTF8

    $applyScript = Join-Path $Root "scripts\apply-update.ps1"
    if (-not (Test-Path -LiteralPath $applyScript)) {
        throw "Update installer not found: $applyScript"
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$applyScript`" -PlanPath `"$planPath`""
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Host "The update was verified. Mailan Zapret will restart after installation." -ForegroundColor Green
}

$UpdateWasAccepted = $false
try {
    $versionConfig = Read-VersionConfig
    $allowedHosts = @($versionConfig.allowed_download_hosts | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($allowedHosts.Count -eq 0) {
        throw "allowed_download_hosts cannot be empty."
    }
    $allowHttpLoopbackProperty = $versionConfig.PSObject.Properties["allow_http_loopback"]
    $allowHttpLoopback = $allowHttpLoopbackProperty -and [bool]$allowHttpLoopbackProperty.Value
    $localVersion = ConvertTo-MailanVersion -Value ([string]$versionConfig.version) -FieldName "local"
    $manifest = Get-UpdateManifest -VersionConfig $versionConfig -AllowedHosts $allowedHosts `
        -AllowHttpLoopback $allowHttpLoopback
    $remoteVersionText = Get-RequiredManifestValue -Manifest $manifest -Name "version"
    $remoteVersion = ConvertTo-MailanVersion -Value $remoteVersionText -FieldName "remote"

    if ($remoteVersion -le $localVersion) {
        if ($ShowErrors) {
            Write-Host "Mailan Zapret is up to date: $localVersion"
        }
        exit 0
    }

    Write-Host ""
    Write-Host "Mailan Zapret update available: $localVersion -> $remoteVersion" -ForegroundColor Cyan
    $notesProperty = $manifest.PSObject.Properties["notes"]
    if ($notesProperty -and $notesProperty.Value) {
        $notes = ([string]$notesProperty.Value).Trim()
        if ($notes.Length -gt 500) { $notes = $notes.Substring(0, 500) + "..." }
        Write-Host $notes
    }
    if (-not $Interactive) {
        exit 3
    }

    $answer = (Read-Host "Download and install this update? [y/N]").Trim()
    if ($answer -notmatch '^(?i:y|yes|д|да)$') {
        Write-Host "Update skipped."
        exit 0
    }

    $UpdateWasAccepted = $true
    Start-MailanUpdate -VersionConfig $versionConfig -Manifest $manifest `
        -RemoteVersion $remoteVersion -AllowedHosts $allowedHosts `
        -AllowHttpLoopback $allowHttpLoopback
    exit 10
}
catch {
    if ($ShowErrors -or $UpdateWasAccepted) {
        Write-Host "Update check failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    exit 2
}
