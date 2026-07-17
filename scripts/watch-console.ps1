[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ParentPid,
    [Parameter(Mandatory)][int]$WinwsPid,
    [Parameter(Mandatory)][string]$PidFile,
    [string]$IPv4PolicyState
)

$ErrorActionPreference = "SilentlyContinue"

try {
    Wait-Process -Id $ParentPid
}
catch {
    # The console may have closed before the watcher finished starting.
}

Stop-Process -Id $WinwsPid -Force -ErrorAction SilentlyContinue
& sc.exe stop WinDivert 2>&1 | Out-Null
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

if ($IPv4PolicyState -and (Test-Path -LiteralPath $IPv4PolicyState)) {
    try {
        $state = Get-Content -LiteralPath $IPv4PolicyState -Raw | ConvertFrom-Json
        & netsh.exe interface ipv6 set prefixpolicy `
            "prefix=$($state.prefix)" `
            "precedence=$($state.precedence)" `
            "label=$($state.label)" `
            "store=active" 2>&1 | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $IPv4PolicyState -Force -ErrorAction SilentlyContinue
    }
}
