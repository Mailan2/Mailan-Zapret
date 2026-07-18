[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ParentPid,
    [Parameter(Mandatory)][string]$LogPath,
    [ValidateSet("ru", "en")][string]$Language = "ru"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$TranslationPath = Join-Path $Root "config\translations.json"
$Translations = Get-Content -LiteralPath $TranslationPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-Text {
    param([Parameter(Mandatory)][string]$Key)

    $catalog = $Translations.PSObject.Properties[$Language].Value
    $value = $catalog.PSObject.Properties[$Key].Value
    if (-not $value) {
        $value = $Translations.en.PSObject.Properties[$Key].Value
    }
    return $value
}

function Test-ParentRunning {
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}

function Write-DiagnosticLine {
    param([Parameter(Mandatory)][string]$Line)

    if ($Line -match '\sERROR\s|\sDENY\s') {
        Write-Host $Line -ForegroundColor Red
    }
    elseif ($Line -match '\sCONNECTED\s') {
        Write-Host $Line -ForegroundColor Green
    }
    else {
        Write-Host $Line
    }
}

$Host.UI.RawUI.WindowTitle = "Mailan Zapret - Telegram diagnostics"
Write-Host (Get-Text "telegram_live_title") -ForegroundColor Cyan
Write-Host (Get-Text "telegram_live_privacy")
Write-Host (Get-Text "telegram_live_waiting") -ForegroundColor DarkGray
Write-Host ""

$offset = 0L
while (Test-ParentRunning) {
    if (Test-Path -LiteralPath $LogPath) {
        try {
            $stream = New-Object IO.FileStream($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                if ($stream.Length -lt $offset) {
                    $offset = 0L
                }
                $stream.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
                try {
                    while (($line = $reader.ReadLine()) -ne $null) {
                        Write-DiagnosticLine -Line $line
                    }
                    $offset = $stream.Position
                }
                finally {
                    $reader.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            # The gateway can replace the log while it starts. The next loop retries.
        }
    }
    Start-Sleep -Milliseconds 300
}

Write-Host ""
Write-Host (Get-Text "telegram_live_finished") -ForegroundColor DarkGray
Start-Sleep -Seconds 3
