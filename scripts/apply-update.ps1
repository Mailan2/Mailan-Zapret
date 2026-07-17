[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExpectedRoot = [IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$RuntimeRoot = [IO.Path]::GetFullPath((Join-Path $ExpectedRoot "runtime")).TrimEnd('\') + '\'
$LogPath = Join-Path $ExpectedRoot "runtime\update.log"

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name is outside the expected directory: $fullPath"
    }
    return $fullPath
}

function Write-UpdateLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = "{0:u} {1}" -f [DateTime]::UtcNow, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

try {
    $verifiedPlanPath = Assert-ChildPath -Path $PlanPath -Parent $RuntimeRoot -Name "Update plan"
    $plan = Get-Content -LiteralPath $verifiedPlanPath -Raw | ConvertFrom-Json
    $root = [IO.Path]::GetFullPath([string]$plan.root)
    if (-not $root.Equals($ExpectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Update root does not match the installed project."
    }
    $staging = Assert-ChildPath -Path ([string]$plan.staging) -Parent $RuntimeRoot -Name "Staging directory"
    $archive = Assert-ChildPath -Path ([string]$plan.archive) -Parent $RuntimeRoot -Name "Update archive"
    if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
        throw "Staging directory does not exist: $staging"
    }

    try {
        Wait-Process -Id ([int]$plan.parent_pid) -Timeout 30 -ErrorAction SilentlyContinue
    }
    catch { }
    if (Get-Process -Name "winws", "winws2" -ErrorAction SilentlyContinue) {
        throw "A Zapret process is still running. Update cancelled."
    }

    $stagingPrefix = $staging.TrimEnd('\') + '\'
    foreach ($sourceFile in Get-ChildItem -LiteralPath $staging -Recurse -File) {
        $relative = $sourceFile.FullName.Substring($stagingPrefix.Length)
        if ($relative -match '^(?i)runtime(?:\|$)') {
            throw "The staged update contains a forbidden runtime path."
        }
        $destination = [IO.Path]::GetFullPath((Join-Path $root $relative))
        $rootPrefix = $root.TrimEnd('\') + '\'
        if (-not $destination.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe destination path: $destination"
        }
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            [void](New-Item -ItemType Directory -Path $destinationDirectory -Force)
        }
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -Force
    }

    Write-UpdateLog "Installed Mailan Zapret $($plan.version)."
    Remove-Item -LiteralPath $staging -Recurse -Force
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $verifiedPlanPath -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath ([string]$plan.launcher) -WorkingDirectory $root -WindowStyle Normal | Out-Null
}
catch {
    Write-UpdateLog "Update failed: $($_.Exception.Message)"
    exit 1
}
