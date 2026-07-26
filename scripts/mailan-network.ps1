[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("menu", "run", "calibrate", "status", "args", "reset")]
    [string]$Command = "menu",

    [string]$Profile,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ConfigPath = Join-Path $Root "config\network-profiles.json"
$SelectionPath = Join-Path $Root "config\network-selection.local.json"
$LanguageConfigPath = Join-Path $Root "config\language.local.json"
$RuntimeDirectory = Join-Path $Root "runtime"
$PidPath = Join-Path $RuntimeDirectory "network-winws.pid"
$Script:NetworkLanguage = "ru"

$NetworkText = @{
    ru = @{
        language_title = "Выберите язык:"
        language_russian = "[1] Русский"
        language_prompt = "Номер языка (по умолчанию {0})"
        language_invalid = "Введите 1 для русского или 2 для English."
        no_calibration = "Для этой сети нет сохранённой калибровки."
        saved_profile = "Сохранённый профиль для этой сети: {0}"
        start_saved = "[1] Запустить сохранённый профиль"
        calibrate_start = "[1] Подобрать профиль и запустить"
        recalibrate = "[2] Повторить подбор для этой сети"
        show_status = "[3] Показать сохранённый результат"
        reset = "[4] Сбросить сохранённый результат"
        blockcheck = "[B] Открыть официальный blockcheck"
        menu_prompt = "Выберите действие (по умолчанию 1)"
        calibration_title = "Mailan Zapret: подбор для текущей сети"
        calibration_notice = "Проверяются отдельные стратегии для этого подключения. Не открывайте сайты до завершения проверки."
        testing = "Проверяется {0}..."
        score = "  баллы {0} | {1}"
        selected = "Выбран профиль: {0} (баллы {1})."
        no_profile = "Ни один профиль не прошёл HTTPS-проверку. Запустите официальный blockcheck или проверьте соединение с провайдером."
        console_title = "Mailan Zapret: сетевой режим"
        console_profile = "Профиль: {0}"
        console_close = "Закройте эту консоль, чтобы остановить фильтрацию сети."
        saved_status = "Сохранённый профиль: {0}"
        network_matches = "Сохранённая сеть совпадает с текущей: {0}"
        last_calibration = "Последняя калибровка: {0}"
        score_status = "Баллы: {0}"
        reset_done = "Сохранённый результат для сети удалён."
        error = "ОШИБКА: {0}"
    }
    en = @{
        language_title = "Select language:"
        language_russian = "[1] Russian"
        language_prompt = "Language number (default {0})"
        language_invalid = "Enter 1 for Russian or 2 for English."
        no_calibration = "No calibration is saved for this network."
        saved_profile = "Saved profile for this network: {0}"
        start_saved = "[1] Start saved profile"
        calibrate_start = "[1] Calibrate and start"
        recalibrate = "[2] Calibrate this network again"
        show_status = "[3] Show saved status"
        reset = "[4] Reset saved calibration"
        blockcheck = "[B] Open official blockcheck"
        menu_prompt = "Choose an action (default 1)"
        calibration_title = "Mailan Zapret Network calibration"
        calibration_notice = "Testing isolated strategies for this connection. Do not browse until the scan finishes."
        testing = "Testing {0}..."
        score = "  score {0} | {1}"
        selected = "Selected profile: {0} (score {1})."
        no_profile = "No profile completed a HTTPS test. Run the official blockcheck or check the provider connection."
        console_title = "Mailan Zapret Network mode"
        console_profile = "Profile: {0}"
        console_close = "Close this console to stop network filtering."
        saved_status = "Saved profile: {0}"
        network_matches = "Saved network matches current network: {0}"
        last_calibration = "Last calibration: {0}"
        score_status = "Score: {0}"
        reset_done = "Saved network calibration removed."
        error = "ERROR: {0}"
    }
}

function Get-NetworkText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments = @()
    )

    $value = $NetworkText[$Script:NetworkLanguage][$Key]
    if ($null -eq $value) {
        $value = $NetworkText.en[$Key]
    }
    if ($Arguments.Count -eq 0) {
        return [string]$value
    }
    return ([string]$value -f $Arguments)
}

function Get-NetworkLanguage {
    if (-not (Test-Path -LiteralPath $LanguageConfigPath)) {
        return "ru"
    }
    try {
        $saved = Get-Content -LiteralPath $LanguageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$saved.language -in @("ru", "en")) {
            return [string]$saved.language
        }
    }
    catch {
    }
    return "ru"
}

function Save-NetworkLanguage {
    param([Parameter(Mandatory)][ValidateSet("ru", "en")][string]$Language)

    $json = [pscustomobject]@{ language = $Language } | ConvertTo-Json
    [IO.File]::WriteAllText($LanguageConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
}

function Select-NetworkLanguage {
    $saved = Get-NetworkLanguage
    $Script:NetworkLanguage = $saved
    if ($Command -ne "menu") {
        return
    }

    $defaultNumber = if ($saved -eq "ru") { "1" } else { "2" }
    while ($true) {
        Write-Host ""
        Write-Host (Get-NetworkText "language_title")
        Write-Host (Get-NetworkText "language_russian")
        Write-Host "[2] English"
        Write-Host ""
        $choice = (Read-Host (Get-NetworkText "language_prompt" @($defaultNumber))).Trim()
        if (-not $choice) { $choice = $defaultNumber }
        if ($choice -eq "1") {
            $Script:NetworkLanguage = "ru"
            Save-NetworkLanguage -Language "ru"
            return
        }
        if ($choice -eq "2") {
            $Script:NetworkLanguage = "en"
            Save-NetworkLanguage -Language "en"
            return
        }
        Write-Host (Get-NetworkText "language_invalid") -ForegroundColor Yellow
    }
}

function Read-NetworkConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Network profile configuration not found: $ConfigPath"
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-NetworkUpdateCheck {
    $updateScript = Join-Path $Root "scripts\mailan-update.ps1"
    if (-not (Test-Path -LiteralPath $updateScript)) {
        return 0
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updateScript check -Interactive -ParentPid $PID | Out-Host
    return [int]$LASTEXITCODE
}

function Resolve-NetworkPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $Root $Path
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
    return $parts -join " "
}

function ConvertTo-CommandLine {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    return ('"{0}" {1}' -f $FilePath, (ConvertTo-ArgumentLine -Arguments $Arguments))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NetworkFingerprint {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) {
        return "offline"
    }

    $dns = Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ServerAddresses } |
        Sort-Object
    $raw = "{0}|{1}|{2}" -f $route.InterfaceIndex, $route.NextHop, ($dns -join ",")
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Read-NetworkSelection {
    if (-not (Test-Path -LiteralPath $SelectionPath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $SelectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-NetworkSelection {
    param(
        [Parameter(Mandatory)][string]$SelectedProfile,
        [Parameter(Mandatory)][int]$Score,
        [Parameter(Mandatory)]$Results
    )

    $value = [pscustomobject]@{
        network_fingerprint = Get-NetworkFingerprint
        profile = $SelectedProfile
        score = $Score
        tested_at = [DateTime]::UtcNow.ToString("o")
        results = $Results
    } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($SelectionPath, $value, (New-Object Text.UTF8Encoding($false)))
}

function Get-ProfileArguments {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ProfileName
    )

    $profileProperty = $Config.profiles.PSObject.Properties[$ProfileName]
    if (-not $profileProperty) {
        throw "Network profile '$ProfileName' was not found."
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($Config.capture_args)) {
        $arguments.Add([string]$arg)
    }

    $index = 0
    foreach ($segment in @($profileProperty.Value.segments)) {
        if ($index -gt 0) {
            $arguments.Add("--new")
        }

        $match = [string]$segment.match
        if ($match -eq "hostlists") {
            foreach ($hostlist in @($Config.hostlists)) {
                $path = Resolve-NetworkPath ([string]$hostlist)
                if (-not (Test-Path -LiteralPath $path)) {
                    throw "Hostlist not found: $path"
                }
                $arguments.Add("--hostlist=$path")
            }
        }
        elseif ($match -eq "ipset") {
            $path = Resolve-NetworkPath ([string]$segment.ipset)
            if (-not (Test-Path -LiteralPath $path)) {
                throw "IP set not found: $path"
            }
            $arguments.Add("--ipset=$path")
        }
        else {
            throw "Unknown segment match type '$match' in profile '$ProfileName'."
        }

        foreach ($arg in @($segment.args)) {
            $arguments.Add([string]$arg)
        }
        $index++
    }

    return $arguments.ToArray()
}

function Test-NoActiveWinws {
    $processes = @(Get-Process -Name "winws", "winws2" -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        throw "Close every existing Zapret console before calibration. Active winws PID(s): $($processes.Id -join ', ')."
    }
}

function Test-UrlReachability {
    param([Parameter(Mandatory)][string]$Url)

    $status = & curl.exe --ipv4 --head --silent --show-error --location --connect-timeout 4 --max-time 8 --output NUL --write-out "%{http_code}" $Url 2>$null
    $exitCode = $LASTEXITCODE
    $statusCode = 0
    [void][int]::TryParse(([string]$status).Trim(), [ref]$statusCode)
    return [pscustomobject]@{
        url = $Url
        status = $statusCode
        success = ($exitCode -eq 0 -and $statusCode -ge 100 -and $statusCode -lt 600)
    }
}

function Stop-OwnedWinws {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 450
}

function Test-NetworkProfile {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ProfileName
    )

    $binary = Resolve-NetworkPath ([string]$Config.binary)
    if (-not (Test-Path -LiteralPath $binary)) {
        throw "winws binary not found: $binary"
    }

    $arguments = Get-ProfileArguments -Config $Config -ProfileName $ProfileName
    if ($DryRun) {
        return [pscustomobject]@{ profile = $ProfileName; score = 0; results = @(); command = (ConvertTo-CommandLine -FilePath $binary -Arguments $arguments) }
    }

    $process = $null
    try {
        $process = Start-Process -FilePath $binary -ArgumentList (ConvertTo-ArgumentLine -Arguments $arguments) -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 900
        if ($process.HasExited) {
            throw "Profile '$ProfileName' exited before tests started."
        }

        $results = @()
        $score = 0
        foreach ($target in @($Config.targets)) {
            $result = Test-UrlReachability -Url ([string]$target.url)
            $result | Add-Member -NotePropertyName id -NotePropertyValue ([string]$target.id)
            $result | Add-Member -NotePropertyName weight -NotePropertyValue ([int]$target.weight)
            if ($result.success) {
                $score += [int]$target.weight
            }
            $results += $result
        }
        return [pscustomobject]@{ profile = $ProfileName; score = $score; results = $results; command = (ConvertTo-CommandLine -FilePath $binary -Arguments $arguments) }
    }
    finally {
        Stop-OwnedWinws -Process $process
    }
}

function Invoke-NetworkCalibration {
    param([Parameter(Mandatory)]$Config)

    if ($DryRun) {
        foreach ($property in $Config.profiles.PSObject.Properties) {
            $test = Test-NetworkProfile -Config $Config -ProfileName $property.Name
            Write-Host ("Dry run {0}: {1}" -f $property.Name, $test.command)
        }
        return "balanced"
    }

    Test-NoActiveWinws
    if (-not (Test-IsAdministrator)) {
        throw "Network calibration requires Administrator rights. Start mailan-zapret.cmd by double-clicking it."
    }

    Write-Host ""
    Write-Host (Get-NetworkText "calibration_title") -ForegroundColor Cyan
    Write-Host (Get-NetworkText "calibration_notice")

    $tests = @()
    foreach ($property in $Config.profiles.PSObject.Properties) {
        Write-Host (Get-NetworkText "testing" @($property.Name))
        $test = Test-NetworkProfile -Config $Config -ProfileName $property.Name
        $tests += $test
        $summary = ($test.results | ForEach-Object { "{0}:{1}" -f $_.id, $_.status }) -join "  "
        Write-Host (Get-NetworkText "score" @($test.score, $summary))
    }

    $best = $tests | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "profile"; Descending = $false } | Select-Object -First 1
    if (-not $best -or $best.score -eq 0) {
        throw (Get-NetworkText "no_profile")
    }

    Save-NetworkSelection -SelectedProfile $best.profile -Score $best.score -Results $best.results
    Write-Host (Get-NetworkText "selected" @($best.profile, $best.score)) -ForegroundColor Green
    return $best.profile
}

function Start-NetworkConsole {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ProfileName
    )

    $binary = Resolve-NetworkPath ([string]$Config.binary)
    if (-not (Test-Path -LiteralPath $binary)) {
        throw "winws binary not found: $binary"
    }
    $arguments = Get-ProfileArguments -Config $Config -ProfileName $ProfileName
    $commandLine = ConvertTo-CommandLine -FilePath $binary -Arguments $arguments

    if ($DryRun) {
        Write-Host $commandLine
        return
    }

    Test-NoActiveWinws
    if (-not (Test-IsAdministrator)) {
        throw "Administrator rights are required for WinDivert. Start mailan-zapret.cmd by double-clicking it."
    }

    Write-Host ""
    Write-Host (Get-NetworkText "console_title") -ForegroundColor Cyan
    Write-Host (Get-NetworkText "console_profile" @($ProfileName))
    Write-Host (Get-NetworkText "console_close")
    Write-Host ""
    Write-Host $commandLine
    Write-Host ""

    [void](New-Item -ItemType Directory -Path $RuntimeDirectory -Force)
    $process = $null
    try {
        $process = Start-Process -FilePath $binary -ArgumentList (ConvertTo-ArgumentLine -Arguments $arguments) -WorkingDirectory (Split-Path -Parent $binary) -NoNewWindow -PassThru
        Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ASCII
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        Stop-OwnedWinws -Process $process
    }
}

function Show-NetworkStatus {
    $selection = Read-NetworkSelection
    $fingerprint = Get-NetworkFingerprint
    if (-not $selection) {
        Write-Host (Get-NetworkText "no_calibration")
        return
    }

    $matches = ([string]$selection.network_fingerprint -eq $fingerprint)
    Write-Host (Get-NetworkText "saved_status" @($selection.profile))
    Write-Host (Get-NetworkText "network_matches" @($matches))
    Write-Host (Get-NetworkText "last_calibration" @($selection.tested_at))
    Write-Host (Get-NetworkText "score_status" @($selection.score))
}

function Select-NetworkAction {
    param([Parameter(Mandatory)]$Config)

    $selection = Read-NetworkSelection
    $currentFingerprint = Get-NetworkFingerprint
    $savedProfile = if ($selection -and [string]$selection.network_fingerprint -eq $currentFingerprint) { [string]$selection.profile } else { $null }

    Write-Host ""
    Write-Host "Mailan Zapret Network"
    if ($savedProfile) {
        Write-Host (Get-NetworkText "saved_profile" @($savedProfile)) -ForegroundColor Green
        Write-Host (Get-NetworkText "start_saved")
    }
    else {
        Write-Host (Get-NetworkText "no_calibration") -ForegroundColor Yellow
        Write-Host (Get-NetworkText "calibrate_start")
    }
    Write-Host (Get-NetworkText "recalibrate")
    Write-Host (Get-NetworkText "show_status")
    Write-Host (Get-NetworkText "reset")
    Write-Host (Get-NetworkText "blockcheck")
    Write-Host ""

    $choice = (Read-Host (Get-NetworkText "menu_prompt")).Trim().ToLowerInvariant()
    if (-not $choice) { $choice = "1" }
    switch ($choice) {
        "1" {
            if ($savedProfile) { return [pscustomobject]@{ action = "run"; profile = $savedProfile } }
            return [pscustomobject]@{ action = "calibrate"; profile = $null }
        }
        "2" { return [pscustomobject]@{ action = "calibrate"; profile = $null } }
        "3" { return [pscustomobject]@{ action = "status"; profile = $null } }
        "4" { return [pscustomobject]@{ action = "reset"; profile = $null } }
        "b" { return [pscustomobject]@{ action = "blockcheck"; profile = $null } }
        default { throw "Unknown menu selection '$choice'." }
    }
}

try {
    Select-NetworkLanguage
    if ($Command -eq "menu" -and -not $DryRun) {
        $updateExitCode = Invoke-NetworkUpdateCheck
        if ($updateExitCode -eq 10) {
            exit 0
        }
    }

    $config = Read-NetworkConfig
    switch ($Command) {
        "args" {
            if (-not $Profile) { $Profile = "balanced" }
            $binary = Resolve-NetworkPath ([string]$config.binary)
            ConvertTo-CommandLine -FilePath $binary -Arguments (Get-ProfileArguments -Config $config -ProfileName $Profile) | Write-Host
        }
        "calibrate" {
            $selected = Invoke-NetworkCalibration -Config $config
            Start-NetworkConsole -Config $config -ProfileName $selected
        }
        "run" {
            if (-not $Profile) {
                $saved = Read-NetworkSelection
                if ($saved -and [string]$saved.network_fingerprint -eq (Get-NetworkFingerprint)) {
                    $Profile = [string]$saved.profile
                }
                else {
                    $Profile = Invoke-NetworkCalibration -Config $config
                }
            }
            Start-NetworkConsole -Config $config -ProfileName $Profile
        }
        "status" {
            Show-NetworkStatus
        }
        "reset" {
            Remove-Item -LiteralPath $SelectionPath -Force -ErrorAction SilentlyContinue
            Write-Host (Get-NetworkText "reset_done")
        }
        "menu" {
            $action = Select-NetworkAction -Config $config
            switch ($action.action) {
                "run" { Start-NetworkConsole -Config $config -ProfileName $action.profile }
                "calibrate" { $selected = Invoke-NetworkCalibration -Config $config; Start-NetworkConsole -Config $config -ProfileName $selected }
                "status" { Show-NetworkStatus }
                "reset" { Remove-Item -LiteralPath $SelectionPath -Force -ErrorAction SilentlyContinue; Write-Host (Get-NetworkText "reset_done") }
                "blockcheck" { & (Join-Path $Root "mailan-zapret.cmd") blockcheck }
            }
        }
    }
}
catch {
    Write-Host ""
    Write-Host (Get-NetworkText "error" @($_.Exception.Message)) -ForegroundColor Red
    exit 1
}
