[CmdletBinding()]
param(
    [ValidateSet("setup", "enable", "disable", "serve", "stop", "status")]
    [string]$Command = "status",

    [int]$ParentPid = 0,

    [ValidateSet("kazakhstan", "telegram")]
    [string]$Mode = "kazakhstan",

    [string]$DiagnosticLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RuntimeDirectory = Join-Path $Root "runtime"
$GatewaySourcePath = Join-Path $PSScriptRoot "KazakhstanProxyGateway.cs"
$InternetSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$ModeSettings = switch ($Mode) {
    "kazakhstan" {
        [pscustomobject]@{
            label = "Kazakhstan sites"
            config_name = "kazakhstan-proxy.local.json"
            state_name = "kazakhstan-proxy-state.json"
            stop_name = "kazakhstan-proxy.stop"
            pac_path = "/mailan-zapret-kz.pac"
            listener_port = 17891
            enabled_by_default = $false
            domains = @("pornhub.com", "phncdn.com", "torproject.org")
        }
    }
    "telegram" {
        [pscustomobject]@{
            label = "Telegram Russia"
            config_name = "telegram-proxy.local.json"
            state_name = "telegram-proxy-state.json"
            stop_name = "telegram-proxy.stop"
            pac_path = "/mailan-zapret-telegram.pac"
            listener_port = 17892
            enabled_by_default = $true
            domains = @("telegram.org", "telegram.me", "telegram.dog", "t.me", "telegra.ph", "telesco.pe", "graph.org", "tdesktop.com", "telegram-cdn.org", "telegramusercontent.com")
        }
    }
}
$ConfigPath = Join-Path $Root (Join-Path "config" $ModeSettings.config_name)
$StatePath = Join-Path $RuntimeDirectory $ModeSettings.state_name
$StopPath = Join-Path $RuntimeDirectory $ModeSettings.stop_name
$PacPath = $ModeSettings.pac_path
$AllowedDomains = @($ModeSettings.domains)

function Write-Utf8Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-RegistryValueState {
    param([Parameter(Mandatory)][string]$Name)

    $properties = Get-ItemProperty -LiteralPath $InternetSettingsPath
    $property = $properties.PSObject.Properties[$Name]
    return [pscustomobject]@{
        exists = [bool]$property
        value = if ($property) { $property.Value } else { $null }
    }
}

function Restore-RegistryValueState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$State
    )

    if ([bool]$State.exists) {
        Set-ItemProperty -LiteralPath $InternetSettingsPath -Name $Name -Value $State.value
    }
    else {
        Remove-ItemProperty -LiteralPath $InternetSettingsPath -Name $Name -ErrorAction SilentlyContinue
    }
}

function Invoke-InternetSettingsRefresh {
    if (-not ("MailanZapret.InternetSettingsNotifier" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace MailanZapret
{
    public static class InternetSettingsNotifier
    {
        [DllImport("wininet.dll", SetLastError = true)]
        private static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);

        public static void Refresh()
        {
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);
            InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
        }
    }
}
'@
    }

    [MailanZapret.InternetSettingsNotifier]::Refresh()
}

function Get-KazakhstanProxyConfiguration {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "$($ModeSettings.label) proxy is not configured."
    }

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $port = [int]$configuration.listener_port
    if ($port -lt 1024 -or $port -gt 65535) {
        throw "$($ModeSettings.label) proxy listener_port must be between 1024 and 65535."
    }

    $domains = @($configuration.domains | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if ($domains.Count -eq 0 -or @($domains | Where-Object { $_ -notin $AllowedDomains }).Count -gt 0) {
        throw "$($ModeSettings.label) proxy domains must be limited to: $($AllowedDomains -join ', ')"
    }

    $proxies = @($configuration.proxies)
    if ($proxies.Count -eq 0 -or $proxies.Count -gt 2) {
        throw "Configure one or two SOCKS5 proxies."
    }

    foreach ($proxy in $proxies) {
        if ([string]::IsNullOrWhiteSpace([string]$proxy.host) -or
            [int]$proxy.port -lt 1 -or [int]$proxy.port -gt 65535 -or
            [string]::IsNullOrWhiteSpace([string]$proxy.username) -or
            [string]::IsNullOrWhiteSpace([string]$proxy.password_protected)) {
        throw "$($ModeSettings.label) proxy configuration is incomplete. Run setup again."
        }
    }

    return $configuration
}

function Get-PlaintextPassword {
    param([Parameter(Mandatory)][string]$ProtectedValue)

    try {
        if ($ProtectedValue.StartsWith("machine:", [StringComparison]::Ordinal)) {
            Add-Type -AssemblyName System.Security
            $cipherBytes = [Convert]::FromBase64String($ProtectedValue.Substring("machine:".Length))
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $cipherBytes,
                $null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine
            )
            return [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        $secureValue = ConvertTo-SecureString -String $ProtectedValue
        $credential = New-Object System.Management.Automation.PSCredential "unused", $secureValue
        return $credential.GetNetworkCredential().Password
    }
    catch {
        throw "The $($ModeSettings.label) proxy password cannot be decrypted for this Windows user. Run setup again."
    }
}

function Protect-LocalPassword {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)

    Add-Type -AssemblyName System.Security
    $credential = New-Object System.Management.Automation.PSCredential "unused", $SecureValue
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($credential.GetNetworkCredential().Password)
    $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    return "machine:" + [Convert]::ToBase64String($cipherBytes)
}

function Get-PacContent {
    param([Parameter(Mandatory)][int]$Port)

    $domainChecks = @($AllowedDomains | ForEach-Object {
        $domain = [string]$_
        "host === `"$domain`" || dnsDomainIs(host, `".$domain`")"
    }) -join " ||`r`n      "

    return @"
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if ($domainChecks) {
    return "PROXY 127.0.0.1:$Port";
  }
  return "DIRECT";
}
"@
}

function Get-ExistingState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }
    return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}

function Restore-PreviousProxySettings {
    param([Parameter(Mandatory)]$State)

    $current = Get-RegistryValueState -Name "AutoConfigURL"
    if ([bool]$current.exists -and [string]$current.value -ne [string]$State.pac_url) {
        return
    }

    Restore-RegistryValueState -Name "AutoConfigURL" -State $State.registry.auto_config_url
    Invoke-InternetSettingsRefresh
}

function Clear-StaleState {
    $state = Get-ExistingState
    if (-not $state) { return }

    $owner = Get-Process -Id ([int]$state.owner_pid) -ErrorAction SilentlyContinue
    if ($owner) {
        throw "$($ModeSettings.label) proxy is already running. PID: $($owner.Id)"
    }

    Restore-PreviousProxySettings -State $state
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
}

function Start-KazakhstanProxySetup {
    [void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)

    Write-Host "$($ModeSettings.label) proxy setup" -ForegroundColor Cyan
    Write-Host "The password is encrypted for the current Windows user and is not added to GitHub."
    $primaryHost = (Read-Host "Primary SOCKS5 host").Trim()
    $primaryPort = 0
    if (-not [int]::TryParse((Read-Host "Primary SOCKS5 port"), [ref]$primaryPort) -or $primaryPort -lt 1 -or $primaryPort -gt 65535) {
        throw "Enter a valid primary SOCKS5 port."
    }
    $username = (Read-Host "SOCKS5 username").Trim()
    $password = Read-Host "SOCKS5 password" -AsSecureString
    if (-not $primaryHost -or -not $username) {
        throw "SOCKS5 host and username are required."
    }

    $proxies = New-Object System.Collections.Generic.List[object]
    [void]$proxies.Add([pscustomobject]@{
        host = $primaryHost
        port = $primaryPort
        username = $username
        password_protected = (Protect-LocalPassword -SecureValue $password)
    })

    $secondaryHost = (Read-Host "Secondary SOCKS5 host (press Enter to skip)").Trim()
    if ($secondaryHost) {
        $secondaryPort = 0
        if (-not [int]::TryParse((Read-Host "Secondary SOCKS5 port"), [ref]$secondaryPort) -or $secondaryPort -lt 1 -or $secondaryPort -gt 65535) {
            throw "Enter a valid secondary SOCKS5 port."
        }
        [void]$proxies.Add([pscustomobject]@{
            host = $secondaryHost
            port = $secondaryPort
            username = $username
            password_protected = (Protect-LocalPassword -SecureValue $password)
        })
    }

    $configuration = [pscustomobject]@{
        enabled = [bool]$ModeSettings.enabled_by_default
        listener_port = [int]$ModeSettings.listener_port
        domains = $AllowedDomains
        proxies = $proxies.ToArray()
    }
    Write-Utf8Json -Path $ConfigPath -Value $configuration
    Write-Host "Saved local $($ModeSettings.label) proxy configuration." -ForegroundColor Green
    if ($Mode -eq "kazakhstan") {
        Write-Host "The Kazakhstan proxy is disabled by default. Enable it only on a Kazakhstan connection with: .\mailan-zapret.cmd proxy-enable"
    }
    else {
        Write-Host "Telegram Russia proxy will start with Zapret. It routes only Telegram domains in system-proxy browsers."
    }
}

function Set-KazakhstanProxyEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "$($ModeSettings.label) proxy is not configured."
    }
    $runningState = Get-ExistingState
    if ($Enabled -and $runningState) {
        throw "Stop the running $($ModeSettings.label) proxy before changing its enabled state."
    }
    if (-not $Enabled -and $runningState) {
        Stop-KazakhstanProxyServer
    }

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $configuration | Add-Member -MemberType NoteProperty -Name "enabled" -Value $Enabled -Force
    Write-Utf8Json -Path $ConfigPath -Value $configuration
    if ($Enabled) {
        Write-Host "$($ModeSettings.label) proxy enabled for the next Zapret start."
    }
    else {
        Write-Host "$($ModeSettings.label) proxy disabled."
    }
}

function Start-KazakhstanProxyServer {
    param([Parameter(Mandatory)][int]$WatchedPid)

    [void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)
    Clear-StaleState
    $configuration = Get-KazakhstanProxyConfiguration
    if (-not (Test-Path -LiteralPath $GatewaySourcePath)) {
        throw "$($ModeSettings.label) proxy gateway source not found: $GatewaySourcePath"
    }

    if (-not ("MailanZapret.LocalSocksGateway" -as [type])) {
        Add-Type -Path $GatewaySourcePath
    }

    $upstreams = New-Object 'System.Collections.Generic.List[MailanZapret.UpstreamProxy]'
    foreach ($proxy in @($configuration.proxies)) {
        $upstream = New-Object MailanZapret.UpstreamProxy
        $upstream.Host = [string]$proxy.host
        $upstream.Port = [int]$proxy.port
        $upstream.Username = [string]$proxy.username
        $upstream.Password = Get-PlaintextPassword -ProtectedValue ([string]$proxy.password_protected)
        [void]$upstreams.Add($upstream)
    }

    $port = [int]$configuration.listener_port
    $pacUrl = "http://127.0.0.1:$port$PacPath"
    $trafficLogPath = if ($Mode -eq "telegram") {
        Join-Path $RuntimeDirectory "telegram-proxy-traffic.log"
    }
    else {
        $null
    }
    if ($trafficLogPath) {
        [IO.File]::WriteAllText($trafficLogPath, "", (New-Object Text.UTF8Encoding($false)))
    }
    $gateway = New-Object MailanZapret.LocalSocksGateway `
        $port, $upstreams.ToArray(), @($configuration.domains), $PacPath, (Get-PacContent -Port $port), $trafficLogPath
    $gateway.Start()

    $state = [pscustomobject]@{
        owner_pid = $PID
        parent_pid = $WatchedPid
        pac_url = $pacUrl
        registry = [pscustomobject]@{
            auto_config_url = Get-RegistryValueState -Name "AutoConfigURL"
        }
    }

    try {
        Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
        Write-Utf8Json -Path $StatePath -Value $state
        Set-ItemProperty -LiteralPath $InternetSettingsPath -Name "AutoConfigURL" -Value $pacUrl
        Invoke-InternetSettingsRefresh
        $gateway.Run($WatchedPid, $StopPath)
    }
    finally {
        $gateway.Stop()
        Restore-PreviousProxySettings -State $state
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-KazakhstanProxyServer {
    $state = Get-ExistingState
    if (-not $state) {
        Write-Host "$($ModeSettings.label) proxy is not running."
        return
    }

    [void](New-Item -ItemType File -Path $StopPath -Force)
    $owner = Get-Process -Id ([int]$state.owner_pid) -ErrorAction SilentlyContinue
    if ($owner) {
        [void]$owner.WaitForExit(5000)
    }
    if (Test-Path -LiteralPath $StatePath) {
        $remainingState = Get-ExistingState
        Restore-PreviousProxySettings -State $remainingState
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    Write-Host "$($ModeSettings.label) proxy stopped and Windows proxy settings restored."
}

function Show-KazakhstanProxyStatus {
    $state = Get-ExistingState
    if (-not $state) {
        Write-Host "$($ModeSettings.label) proxy: not running"
        return
    }

    $owner = Get-Process -Id ([int]$state.owner_pid) -ErrorAction SilentlyContinue
    if (-not $owner) {
        Write-Host "$($ModeSettings.label) proxy: stale state detected"
        return
    }

    Write-Host "$($ModeSettings.label) proxy: running. PID: $($owner.Id)"
    Write-Host "Domains: $($AllowedDomains -join ', ')"
    Write-Host "PAC URL: $($state.pac_url)"
}

switch ($Command) {
    "setup" { Start-KazakhstanProxySetup }
    "enable" { Set-KazakhstanProxyEnabled -Enabled $true }
    "disable" { Set-KazakhstanProxyEnabled -Enabled $false }
    "serve" {
        if ($ParentPid -le 0) { $ParentPid = $PID }
        Start-KazakhstanProxyServer -WatchedPid $ParentPid
    }
    "stop" { Stop-KazakhstanProxyServer }
    "status" { Show-KazakhstanProxyStatus }
}
