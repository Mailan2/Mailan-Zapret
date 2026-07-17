[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("menu", "blockcheck", "bootstrap", "proxy-setup", "proxy-status", "proxy-stop", "console", "start", "stop", "restart", "status", "doctor", "args", "check-update")]
    [string]$Command = "console",

    [string]$Profile = "safe",

    [string]$ConfigPath,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $Root "config\profiles.json"
}

function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $Root $Path)
}

function Read-MailanConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

function Get-MailanProfile {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    $profileProperty = $Config.profiles.PSObject.Properties[$Name]
    if (-not $profileProperty) {
        $available = ($Config.profiles.PSObject.Properties.Name -join ", ")
        throw "Profile '$Name' was not found. Available profiles: $available"
    }

    return $profileProperty.Value
}

function Get-PidFile {
    param([Parameter(Mandatory)][string]$Name)

    $runtimeDir = Join-Path $Root "runtime"
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir | Out-Null
    }

    return (Join-Path $runtimeDir "$Name.pid")
}

function Get-IPv4PolicyStateFile {
    $runtimeDir = Join-Path $Root "runtime"
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir | Out-Null
    }

    return (Join-Path $runtimeDir "ipv4-prefix-policy.json")
}

function Get-KazakhstanProxyConfigPath {
    return (Join-Path $Root "config\kazakhstan-proxy.local.json")
}

function Test-KazakhstanProxyConfigured {
    return (Test-Path -LiteralPath (Get-KazakhstanProxyConfigPath))
}

function Test-LocalTcpPort {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 400
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($result)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Start-KazakhstanProxyGateway {
    param([Parameter(Mandatory)][int]$ParentPid)

    if (-not (Test-KazakhstanProxyConfigured)) {
        return $null
    }

    $proxyScript = Join-Path $Root "scripts\kazakhstan-proxy.ps1"
    if (-not (Test-Path -LiteralPath $proxyScript)) {
        throw "Kazakhstan proxy script not found: $proxyScript"
    }

    $argumentItems = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $proxyScript,
        "serve",
        "-ParentPid", [string]$ParentPid
    )
    $argumentLine = ConvertTo-ArgumentLine -Arguments $argumentItems
    $gatewayProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (Test-LocalTcpPort -Port 17891) {
            Write-Host "Kazakhstan site proxy enabled for Pornhub and Tor Project." -ForegroundColor Green
            return $gatewayProcess
        }
        if ($gatewayProcess.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $gatewayProcess.HasExited) {
        Stop-Process -Id $gatewayProcess.Id -Force -ErrorAction SilentlyContinue
    }
    throw "Kazakhstan site proxy did not start. Run: .\mailan-zapret.cmd proxy-status"
}

function Invoke-KazakhstanProxyCommand {
    param([Parameter(Mandatory)][ValidateSet("setup", "status", "stop")][string]$ProxyCommand)

    $proxyScript = Join-Path $Root "scripts\kazakhstan-proxy.ps1"
    if (-not (Test-Path -LiteralPath $proxyScript)) {
        throw "Kazakhstan proxy script not found: $proxyScript"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $proxyScript $ProxyCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Kazakhstan proxy command failed with exit code $LASTEXITCODE."
    }
}

function Invoke-MailanUpdateCheck {
    param(
        [switch]$Interactive,
        [switch]$ShowErrors
    )

    $updateScript = Join-Path $Root "scripts\mailan-update.ps1"
    if (-not (Test-Path -LiteralPath $updateScript)) {
        if ($ShowErrors) {
            Write-Host "Update checker not found: $updateScript" -ForegroundColor Yellow
        }
        return 2
    }

    $argumentItems = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $updateScript,
        "check",
        "-ParentPid", [string]$PID
    )
    if ($Interactive) { $argumentItems += "-Interactive" }
    if ($ShowErrors) { $argumentItems += "-ShowErrors" }
    & powershell.exe @argumentItems | Out-Host
    $exitCode = $LASTEXITCODE
    return [int]$exitCode
}

function Restore-TemporaryIPv4Preference {
    param([string]$StateFile = (Get-IPv4PolicyStateFile))

    if (-not $StateFile -or -not (Test-Path -LiteralPath $StateFile)) {
        return
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        & netsh.exe interface ipv6 set prefixpolicy `
            "prefix=$($state.prefix)" `
            "precedence=$($state.precedence)" `
            "label=$($state.label)" `
            "store=active" 2>&1 | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
}

function Enable-TemporaryIPv4Preference {
    param([Parameter(Mandatory)]$Config)

    $setting = $Config.PSObject.Properties["prefer_ipv4_while_running"]
    if (-not $setting -or -not [bool]$setting.Value) {
        return $null
    }

    $stateFile = Get-IPv4PolicyStateFile
    Restore-TemporaryIPv4Preference -StateFile $stateFile

    $policy = Get-NetPrefixPolicy -ErrorAction SilentlyContinue |
        Where-Object { $_.Prefix -eq "::ffff:0:0/96" } |
        Select-Object -First 1
    if (-not $policy -or [int]$policy.Precedence -ge 60) {
        return $null
    }

    @{
        prefix = [string]$policy.Prefix
        precedence = [int]$policy.Precedence
        label = [int]$policy.Label
    } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding ASCII

    & netsh.exe interface ipv6 set prefixpolicy `
        "prefix=$($policy.Prefix)" `
        "precedence=60" `
        "label=$($policy.Label)" `
        "store=active" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        Write-Host "WARNING: could not enable temporary IPv4 preference." -ForegroundColor Yellow
        return $null
    }

    return $stateFile
}

function Get-RunningProcess {
    param([Parameter(Mandatory)][string]$PidFile)

    if (-not (Test-Path -LiteralPath $PidFile)) {
        return $null
    }

    $rawPid = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    if (-not $rawPid) {
        return $null
    }

    try {
        return Get-Process -Id ([int]$rawPid) -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Get-WinwsBinary {
    param([Parameter(Mandatory)]$Config)

    $binaryPath = Resolve-ProjectPath $Config.binary
    [void](Restore-BundledRuntimeFiles -BinaryPath $binaryPath)
    if (-not (Test-Path -LiteralPath $binaryPath)) {
        throw "winws binary not found: $binaryPath. Run mailan-zapret.cmd bootstrap or download a complete release archive."
    }

    return $binaryPath
}

function Restore-BundledRuntimeFiles {
    param([Parameter(Mandatory)][string]$BinaryPath)

    $binaryDirectory = Split-Path -Parent $BinaryPath
    $runtimeFiles = @(
        [pscustomobject]@{
            Name = "winws.exe"
            Source = "vendor\\blockcheck\\zapret\\nfq\\winws.exe"
            Sha256 = "2da71e80878dc270ac83f5893ecbb841f9752a57f1da8ff9325636b4346bc632"
        },
        [pscustomobject]@{
            Name = "WinDivert.dll"
            Source = "vendor\\blockcheck\\zapret\\nfq\\WinDivert.dll"
            Sha256 = "06c3f201b815a5798816e8c15b925b28f3c38e5aba31efedec10af9e598ce723"
        },
        [pscustomobject]@{
            Name = "WinDivert64.sys"
            Source = "vendor\\blockcheck\\zapret\\nfq\\WinDivert64.sys"
            Sha256 = "8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2"
        },
        [pscustomobject]@{
            Name = "cygwin1.dll"
            Source = "vendor\\cygwin\\bin\\cygwin1.dll"
            Sha256 = "103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b"
        }
    )

    $missingFiles = @($runtimeFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $binaryDirectory $_.Name))
    })
    if ($missingFiles.Count -eq 0) {
        return @()
    }

    [void](New-Item -ItemType Directory -Path $binaryDirectory -Force)
    Write-Host "Restoring bundled Zapret runtime files..." -ForegroundColor Cyan
    $restored = New-Object System.Collections.Generic.List[string]
    foreach ($file in $missingFiles) {
        $sourcePath = Resolve-ProjectPath $file.Source
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Bundled runtime source is missing: $sourcePath. Download a complete Mailan Zapret release archive."
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -ne $file.Sha256) {
            throw "Bundled runtime verification failed for $($file.Name). Download a fresh Mailan Zapret release archive."
        }

        $destinationPath = Join-Path $binaryDirectory $file.Name
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($destinationHash -ne $file.Sha256) {
            Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
            throw "Runtime restore verification failed for $($file.Name)."
        }
        [void]$restored.Add($file.Name)
    }

    Write-Host ("Restored: {0}" -f ($restored -join ", ")) -ForegroundColor Green
}

function Get-ProfileArguments {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$ProfileConfig
    )

    $arguments = New-Object System.Collections.Generic.List[string]

    $profileHostlistsProperty = $ProfileConfig.PSObject.Properties["hostlists"]
    $profileHostlists = if ($profileHostlistsProperty) {
        @($profileHostlistsProperty.Value)
    }
    else {
        @($Config.hostlists)
    }

    $excludedHostlistsProperty = $Config.PSObject.Properties["excluded_hostlists"]
    $excludedHostlists = if ($excludedHostlistsProperty) { @($excludedHostlistsProperty.Value) } else { @() }
    $excludedIpsetsProperty = $Config.PSObject.Properties["excluded_ipsets"]
    $excludedIpsets = if ($excludedIpsetsProperty) { @($excludedIpsetsProperty.Value) } else { @() }

    function Add-ProfileExclusions {
        foreach ($hostlist in $excludedHostlists) {
            $hostlistPath = Resolve-ProjectPath ([string]$hostlist)
            if (-not (Test-Path -LiteralPath $hostlistPath)) {
                throw "Excluded hostlist not found: $hostlistPath"
            }
            $arguments.Add("--hostlist-exclude=$hostlistPath")
        }

        foreach ($ipset in $excludedIpsets) {
            $ipsetPath = Resolve-ProjectPath ([string]$ipset)
            if (-not (Test-Path -LiteralPath $ipsetPath)) {
                throw "Excluded ipset not found: $ipsetPath"
            }
            $arguments.Add("--ipset-exclude=$ipsetPath")
        }
    }

    foreach ($arg in @($Config.base_args)) {
        if ($arg) {
            $arguments.Add([string]$arg)
        }
    }

    $segmentsProperty = $ProfileConfig.PSObject.Properties["segments"]
    if ($segmentsProperty) {
        $segmentIndex = 0
        foreach ($segment in @($segmentsProperty.Value)) {
            if ($segmentIndex -gt 0) {
                $arguments.Add("--new")
            }

            $segmentHostlistsProperty = $segment.PSObject.Properties["hostlists"]
            $segmentHostlists = if ($segmentHostlistsProperty) {
                @($segmentHostlistsProperty.Value)
            }
            else {
                $profileHostlists
            }

            foreach ($hostlist in $segmentHostlists) {
                $hostlistPath = Resolve-ProjectPath ([string]$hostlist)
                if (-not (Test-Path -LiteralPath $hostlistPath)) {
                    throw "Hostlist not found: $hostlistPath"
                }
                $arguments.Add("--hostlist=$hostlistPath")
            }
            if (@($segmentHostlists).Count -eq 0) {
                Add-ProfileExclusions
            }

            foreach ($arg in @($segment.args)) {
                if ($arg) {
                    $arguments.Add([string]$arg)
                }
            }
            $segmentIndex++
        }
    }
    else {
        foreach ($hostlist in $profileHostlists) {
            $hostlistPath = Resolve-ProjectPath ([string]$hostlist)
            if (-not (Test-Path -LiteralPath $hostlistPath)) {
                throw "Hostlist not found: $hostlistPath"
            }
            $arguments.Add("--hostlist=$hostlistPath")
        }
        Add-ProfileExclusions

        foreach ($arg in @($ProfileConfig.args)) {
            if ($arg) {
                $arguments.Add([string]$arg)
            }
        }
    }

    $tailSegmentsProperty = $Config.PSObject.Properties["tail_segments"]
    if ($tailSegmentsProperty) {
        foreach ($segment in @($tailSegmentsProperty.Value)) {
            $arguments.Add("--new")
            foreach ($arg in @($segment.args)) {
                if ($arg) {
                    $arguments.Add([string]$arg)
                }
            }
        }
    }

    return $arguments.ToArray()
}

function Select-MailanProfile {
    param([Parameter(Mandatory)]$Config)

    $profiles = @($Config.profiles.PSObject.Properties)
    Write-Host ""
    Write-Host "Select bypass strategy:"
    for ($index = 0; $index -lt $profiles.Count; $index++) {
        Write-Host ("[{0}] {1} - {2}" -f ($index + 1), $profiles[$index].Name, $profiles[$index].Value.description)
    }
    Write-Host "[B] blockcheck.sh - auto-detect working strategies"
    Write-Host "[L] verified official website links"
    Write-Host ""

    while ($true) {
        $selection = Read-Host "Strategy number (default 1)"
        if (-not $selection) {
            return $profiles[0].Name
        }
        $selection = $selection.Trim().TrimEnd([char[]]@('\', '/'))
        if ($selection -match '^[bB]$') {
            return "__blockcheck__"
        }
        if ($selection -match '^[lL]$') {
            $linksLauncher = Join-Path $Root "mailan-official-links.cmd"
            if (Test-Path -LiteralPath $linksLauncher) {
                Start-Process -FilePath $linksLauncher -WorkingDirectory $Root -WindowStyle Normal | Out-Null
            }
            else {
                Write-Host "Official links launcher not found: $linksLauncher" -ForegroundColor Yellow
            }
            continue
        }
        $number = 0
        if ([int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $profiles.Count) {
            return $profiles[$number - 1].Name
        }

        Write-Host "Enter a number from 1 to $($profiles.Count)." -ForegroundColor Yellow
    }
}

function Start-MailanBlockcheck {
    $running = @(Get-Process -Name "winws", "winws2" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw "Stop every Zapret console before running blockcheck.sh. Active winws PID(s): $($running.Id -join ', ')"
    }
    if (-not (Test-IsAdministrator)) {
        throw "blockcheck.sh requires Administrator rights. Start mailan-zapret.cmd by double-clicking it."
    }

    $launcher = Join-Path $Root "vendor\blockcheck\blockcheck.cmd"
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "blockcheck launcher not found: $launcher"
    }

    Write-Host ""
    Write-Host "Mailan Zapret blockcheck.sh auto-detect"
    Write-Host "Zapret must remain stopped during the scan."
    Write-Host "Use youtube.com when blockcheck asks for a test domain."
    Write-Host "The scan can take a while and will ask several questions."
    Write-Host ""

    $previousDomainDefault = $env:DOMAINS_DEFAULT
    $env:DOMAINS_DEFAULT = "youtube.com"
    try {
        & $env:ComSpec /d /c ('"{0}"' -f $launcher)
        if ($LASTEXITCODE -ne 0) {
            throw "blockcheck.sh exited with code $LASTEXITCODE"
        }
    }
    finally {
        $env:DOMAINS_DEFAULT = $previousDomainDefault
    }

    $logPath = Join-Path $Root "vendor\blockcheck\blockcheck.log"
    Write-Host ""
    Write-Host "blockcheck.sh finished. Results: $logPath"
}

function ConvertTo-ArgumentLine {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $parts = foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            '"{0}"' -f ($arg -replace '"', '\"')
        }
        else {
            $arg
        }
    }

    return ($parts -join " ")
}

function ConvertTo-CommandLine {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('"{0}"' -f $FilePath))
    foreach ($arg in $Arguments) {
        if ($arg -match '\s') {
            $parts.Add(('"{0}"' -f ($arg -replace '"', '\"')))
        }
        else {
            $parts.Add($arg)
        }
    }

    return ($parts -join " ")
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-WinDivertDriver {
    try {
        $service = Get-Service -Name "WinDivert" -ErrorAction Stop
        if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name "WinDivert" -Force -ErrorAction Stop
            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(5))
        }
    }
    catch {
        # The dynamic WinDivert service may not exist, or this command may be non-elevated.
    }
}

function Show-Status {
    param([Parameter(Mandatory)][string]$Name)

    $pidFile = Get-PidFile $Name
    $process = Get-RunningProcess $pidFile

    if ($process) {
        Write-Host "Profile '$Name' is running. PID: $($process.Id)"
    }
    else {
        Write-Host "Profile '$Name' is stopped."
    }
}

function Start-MailanZapret {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$ProfileConfig,
        [Parameter(Mandatory)][string]$Name
    )

    $pidFile = Get-PidFile $Name
    $existing = Get-RunningProcess $pidFile
    if ($existing) {
        Write-Host "Profile '$Name' is already running. PID: $($existing.Id)"
        return
    }

    $arguments = Get-ProfileArguments $Config $ProfileConfig
    if ($DryRun) {
        $binary = Resolve-ProjectPath $Config.binary
    }
    else {
        $binary = Get-WinwsBinary $Config
    }

    $commandLine = ConvertTo-CommandLine -FilePath $binary -Arguments $arguments

    if ($DryRun) {
        Write-Host $commandLine
        return
    }

    $argumentLine = ConvertTo-ArgumentLine -Arguments $arguments
    $workingDirectory = Split-Path -Parent $binary
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory $workingDirectory -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidFile -Value $process.Id -Encoding ASCII
    try {
        [void](Start-KazakhstanProxyGateway -ParentPid $process.Id)
    }
    catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Started profile '$Name'. PID: $($process.Id)"
}

function Start-MailanZapretConsole {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$ProfileConfig,
        [Parameter(Mandatory)][string]$Name
    )

    $pidFile = Get-PidFile $Name
    $existing = Get-RunningProcess $pidFile
    if ($existing) {
        Write-Host "Profile '$Name' is already running in background. PID: $($existing.Id)"
        Write-Host "Stop it first with: .\mailan-zapret.cmd stop -Profile $Name"
        return 1
    }

    $otherWinws = @(Get-Process -Name "winws", "winws2" -ErrorAction SilentlyContinue)
    if ($otherWinws.Count -gt 0) {
        Write-Host "Another Zapret process is already running. PID(s): $($otherWinws.Id -join ', ')" -ForegroundColor Yellow
        Write-Host "Close its console before selecting another strategy."
        return 1
    }

    Stop-WinDivertDriver

    if (-not (Test-IsAdministrator)) {
        Write-Host "WARNING: this console is not running as Administrator." -ForegroundColor Yellow
        Write-Host "Zapret/winws usually needs Administrator rights for WinDivert."
        Write-Host ""
    }

    $binary = Get-WinwsBinary $Config
    $arguments = Get-ProfileArguments $Config $ProfileConfig
    $commandLine = ConvertTo-CommandLine -FilePath $binary -Arguments $arguments

    Write-Host "Mailan Zapret console mode"
    Write-Host "Profile: $Name"
    Write-Host "Close this console to stop Zapret."
    Write-Host ""
    Write-Host $commandLine
    Write-Host ""

    $argumentLine = ConvertTo-ArgumentLine -Arguments $arguments
    $workingDirectory = Split-Path -Parent $binary
    $ipv4PolicyState = Enable-TemporaryIPv4Preference -Config $Config
    if ($ipv4PolicyState) {
        Write-Host "IPv4 is preferred while this console is open (Telegram compatibility)."
    }
    if (Get-Process -Name "browser" -ErrorAction SilentlyContinue) {
        Write-Host "Yandex Browser is already running. Fully restart it with Ctrl+Shift+Q after Zapret starts." -ForegroundColor Yellow
    }
    if ($ipv4PolicyState) {
        Write-Host ""
    }
    $process = $null
    $kazakhstanProxyGateway = $null
    try {
        $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory $workingDirectory -NoNewWindow -PassThru
        Set-Content -LiteralPath $pidFile -Value $process.Id -Encoding ASCII
        $kazakhstanProxyGateway = Start-KazakhstanProxyGateway -ParentPid $process.Id

        $watcherScript = Join-Path $Root "scripts\watch-console.ps1"
        if (-not (Test-Path -LiteralPath $watcherScript)) {
            throw "Console watcher not found: $watcherScript"
        }
        $watcherArgumentItems = [System.Collections.Generic.List[string]]@(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $watcherScript,
            "-ParentPid", [string]$PID,
            "-WinwsPid", [string]$process.Id,
            "-PidFile", $pidFile
        )
        if ($ipv4PolicyState) {
            $watcherArgumentItems.Add("-IPv4PolicyState")
            $watcherArgumentItems.Add([string]$ipv4PolicyState)
        }
        $watcherArguments = ConvertTo-ArgumentLine -Arguments $watcherArgumentItems.ToArray()
        Start-Process -FilePath "powershell.exe" -ArgumentList $watcherArguments -WindowStyle Hidden | Out-Null
    }
    catch {
        if ($process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Restore-TemporaryIPv4Preference -StateFile $ipv4PolicyState
        throw
    }

    try {
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Stop-WinDivertDriver
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Restore-TemporaryIPv4Preference -StateFile $ipv4PolicyState
    }
}

function Stop-MailanZapret {
    param([Parameter(Mandatory)][string]$Name)

    $pidFile = Get-PidFile $Name
    $process = Get-RunningProcess $pidFile
    if (-not $process) {
        Stop-WinDivertDriver
        Write-Host "Profile '$Name' is already stopped."
        return
    }

    Stop-Process -Id $process.Id -Force
    Stop-WinDivertDriver
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped profile '$Name'."
}

function Show-Doctor {
    param([Parameter(Mandatory)]$Config)

    Write-Host "Project root: $Root"
    Write-Host "Config: $ConfigPath"
    Write-Host ("Administrator: {0}" -f (Test-IsAdministrator))

    $versionPath = Join-Path $Root "config\version.json"
    if (Test-Path -LiteralPath $versionPath) {
        $versionConfig = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
        Write-Host ("Version: {0}" -f $versionConfig.version)
        Write-Host ("Update manifest: {0}" -f $versionConfig.manifest_url)
    }

    $binaryPath = Resolve-ProjectPath $Config.binary
    Write-Host ("winws: {0} ({1})" -f $binaryPath, (Test-Path -LiteralPath $binaryPath))
    foreach ($driverFile in @("cygwin1.dll", "WinDivert.dll", "WinDivert64.sys")) {
        $driverPath = Join-Path (Split-Path -Parent $binaryPath) $driverFile
        Write-Host ("{0}: {1} ({2})" -f $driverFile, $driverPath, (Test-Path -LiteralPath $driverPath))
    }
    Write-Host "Profiles:"
    foreach ($profileProperty in $Config.profiles.PSObject.Properties) {
        $profileConfig = $profileProperty.Value
        Write-Host ("- {0}: {1}" -f $profileProperty.Name, $profileConfig.description)

        $profileHostlistsProperty = $profileConfig.PSObject.Properties["hostlists"]
        $profileHostlists = if ($profileHostlistsProperty) {
            @($profileHostlistsProperty.Value)
        }
        else {
            @($Config.hostlists)
        }

        foreach ($hostlist in $profileHostlists) {
            $hostlistPath = Resolve-ProjectPath ([string]$hostlist)
            if (Test-Path -LiteralPath $hostlistPath) {
                $count = (Get-Content -LiteralPath $hostlistPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") }).Count
                Write-Host ("  hostlist {0}: {1} entries" -f $hostlist, $count)
            }
            else {
                Write-Host ("  hostlist {0}: missing" -f $hostlist)
            }
        }
    }

    Write-Host "Passthrough exclusions:"
    foreach ($hostlist in @($Config.excluded_hostlists)) {
        Write-Host ("- hostlist: {0}" -f $hostlist)
    }
    foreach ($ipset in @($Config.excluded_ipsets)) {
        Write-Host ("- ipset: {0}" -f $ipset)
    }
}

try {
    if ($Command -eq "check-update") {
        $updateExitCode = Invoke-MailanUpdateCheck -Interactive -ShowErrors
        if ($updateExitCode -eq 10) { exit 0 }
        if ($updateExitCode -eq 2) { exit 1 }
        exit 0
    }

    $config = Read-MailanConfig
    if ($Command -eq "menu") {
        $updateExitCode = Invoke-MailanUpdateCheck -Interactive
        if ($updateExitCode -eq 10) { exit 0 }
        $Profile = Select-MailanProfile -Config $config
        $Command = if ($Profile -eq "__blockcheck__") { "blockcheck" } else { "console" }
    }

    $profileConfig = $null
    if ($Command -in @("console", "start", "restart", "args")) {
        $profileConfig = Get-MailanProfile -Config $config -Name $Profile
    }

    switch ($Command) {
        "blockcheck" {
            Start-MailanBlockcheck
        }
        "bootstrap" {
            $binaryPath = Get-WinwsBinary -Config $config
            Write-Host "Bundled runtime is ready: $binaryPath" -ForegroundColor Green
        }
        "proxy-setup" {
            Invoke-KazakhstanProxyCommand -ProxyCommand "setup"
        }
        "proxy-status" {
            Invoke-KazakhstanProxyCommand -ProxyCommand "status"
        }
        "proxy-stop" {
            Invoke-KazakhstanProxyCommand -ProxyCommand "stop"
        }
        "console" {
            $exitCode = Start-MailanZapretConsole -Config $config -ProfileConfig $profileConfig -Name $Profile
            if ($null -ne $exitCode) {
                exit $exitCode
            }
        }
        "start" {
            Start-MailanZapret -Config $config -ProfileConfig $profileConfig -Name $Profile
        }
        "stop" {
            Stop-MailanZapret -Name $Profile
        }
        "restart" {
            Stop-MailanZapret -Name $Profile
            Start-MailanZapret -Config $config -ProfileConfig $profileConfig -Name $Profile
        }
        "status" {
            Show-Status -Name $Profile
        }
        "doctor" {
            Show-Doctor -Config $config
        }
        "args" {
            $binary = if (Test-Path -LiteralPath (Resolve-ProjectPath $config.binary)) {
                Resolve-ProjectPath $config.binary
            }
            else {
                Resolve-ProjectPath $config.binary
            }
            $arguments = Get-ProfileArguments -Config $config -ProfileConfig $profileConfig
            ConvertTo-CommandLine -FilePath $binary -Arguments $arguments | Write-Host
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
