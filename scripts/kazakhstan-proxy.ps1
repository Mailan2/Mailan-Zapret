[CmdletBinding()]
param(
    [ValidateSet("setup", "enable", "disable", "serve", "stop", "status")]
    [string]$Command = "status",

    [int]$ParentPid = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RuntimeDirectory = Join-Path $Root "runtime"
$ConfigPath = Join-Path $Root "config\kazakhstan-proxy.local.json"
$GatewaySourcePath = Join-Path $PSScriptRoot "KazakhstanProxyGateway.cs"
$StatePath = Join-Path $RuntimeDirectory "kazakhstan-proxy-state.json"
$StopPath = Join-Path $RuntimeDirectory "kazakhstan-proxy.stop"
$InternetSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$PacPath = "/mailan-zapret-kz.pac"
$AllowedDomains = @("pornhub.com", "phncdn.com", "torproject.org")

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
        throw "Kazakhstan proxy is not configured. Run: .\mailan-zapret.cmd proxy-setup"
    }

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $port = [int]$configuration.listener_port
    if ($port -lt 1024 -or $port -gt 65535) {
        throw "Kazakhstan proxy listener_port must be between 1024 and 65535."
    }

    $domains = @($configuration.domains | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if ($domains.Count -eq 0 -or @($domains | Where-Object { $_ -notin $AllowedDomains }).Count -gt 0) {
        throw "Kazakhstan proxy domains must be limited to: $($AllowedDomains -join ', ')"
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
            throw "Kazakhstan proxy configuration is incomplete. Run proxy-setup again."
        }
    }

    return $configuration
}

function Get-PlaintextPassword {
    param([Parameter(Mandatory)][string]$ProtectedValue)

    try {
        $secureValue = ConvertTo-SecureString -String $ProtectedValue
        $credential = New-Object System.Management.Automation.PSCredential "unused", $secureValue
        return $credential.GetNetworkCredential().Password
    }
    catch {
        throw "The Kazakhstan proxy password cannot be decrypted for this Windows user. Run proxy-setup again."
    }
}

function Get-PacContent {
    param([Parameter(Mandatory)][int]$Port)

    return @"
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (host === "pornhub.com" || dnsDomainIs(host, ".pornhub.com") ||
      host === "phncdn.com" || dnsDomainIs(host, ".phncdn.com") ||
      host === "torproject.org" || dnsDomainIs(host, ".torproject.org")) {
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
        throw "Kazakhstan proxy is already running. PID: $($owner.Id)"
    }

    Restore-PreviousProxySettings -State $state
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
}

function Start-KazakhstanProxySetup {
    [void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)

    Write-Host "Kazakhstan site proxy setup" -ForegroundColor Cyan
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
        password_protected = (ConvertFrom-SecureString -SecureString $password)
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
            password_protected = (ConvertFrom-SecureString -SecureString $password)
        })
    }

    $configuration = [pscustomobject]@{
        enabled = $false
        listener_port = 17891
        domains = $AllowedDomains
        proxies = $proxies.ToArray()
    }
    Write-Utf8Json -Path $ConfigPath -Value $configuration
    Write-Host "Saved local Kazakhstan proxy configuration." -ForegroundColor Green
    Write-Host "The Kazakhstan proxy is disabled by default. Enable it only on a Kazakhstan connection with: .\mailan-zapret.cmd proxy-enable"
}

function Set-KazakhstanProxyEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Kazakhstan proxy is not configured. Run: .\mailan-zapret.cmd proxy-setup"
    }
    $runningState = Get-ExistingState
    if ($Enabled -and $runningState) {
        throw "Stop the running Kazakhstan proxy before changing its enabled state."
    }
    if (-not $Enabled -and $runningState) {
        Stop-KazakhstanProxyServer
    }

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $configuration | Add-Member -MemberType NoteProperty -Name "enabled" -Value $Enabled -Force
    Write-Utf8Json -Path $ConfigPath -Value $configuration
    if ($Enabled) {
        Write-Host "Kazakhstan proxy enabled for the next Zapret start."
    }
    else {
        Write-Host "Kazakhstan proxy disabled."
    }
}

function Start-KazakhstanProxyServer {
    param([Parameter(Mandatory)][int]$WatchedPid)

    [void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)
    Clear-StaleState
    $configuration = Get-KazakhstanProxyConfiguration
    if (-not (Test-Path -LiteralPath $GatewaySourcePath)) {
        throw "Kazakhstan proxy gateway source not found: $GatewaySourcePath"
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
    $gateway = New-Object MailanZapret.LocalSocksGateway `
        $port, $upstreams.ToArray(), @($configuration.domains), $PacPath, (Get-PacContent -Port $port)
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
        Write-Host "Kazakhstan proxy is not running."
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
    Write-Host "Kazakhstan proxy stopped and Windows proxy settings restored."
}

function Show-KazakhstanProxyStatus {
    $state = Get-ExistingState
    if (-not $state) {
        Write-Host "Kazakhstan proxy: not running"
        return
    }

    $owner = Get-Process -Id ([int]$state.owner_pid) -ErrorAction SilentlyContinue
    if (-not $owner) {
        Write-Host "Kazakhstan proxy: stale state detected"
        return
    }

    Write-Host "Kazakhstan proxy: running. PID: $($owner.Id)"
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
