#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание и обновление llama.cpp как службы Windows.

.DESCRIPTION
    Читает llama-windows-install.ini. Позволяет выбрать версию, сделать бэкап и
    пересоздать службу. Поддерживает флаг -Upgrade для автообновления.
    Папки install, logs, Downloads, Backup, Models сохраняются
    в LlamaCppDir при обновлении/переустановке.
    Ведёт лог работы в llama-windows-install.log.
    Проверяет зависимости (VC++ Redist, CUDA/VRAM), существование модели,
    поддерживает ForceCPU для диагностики.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$ForceDownload,
    [switch]$Upgrade,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$forceDL = [bool]$ForceDownload

# ─── 0. Инициализация путей и логов ───
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'llama-windows-install.ini'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

$global:LogFile = Join-Path $scriptDir 'llama-windows-install.log'
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    Write-Host $Message -ForegroundColor $Color
    if ($global:LogFile) {
        Add-Content -Path $global:LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
function Write-Step([string]$msg) { Write-Log "`n=== $msg ===" -Color Cyan }

Write-Log "=== Запуск llama-windows-install.ps1 (Upgrade=$Upgrade) ===" -Color Cyan

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Запрос прав администратора (UAC)...' -Color Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($Force)         { $argLine += ' -Force'         }
    if ($ForceDownload) { $argLine += ' -ForceDownload' }
    if ($Upgrade)       { $argLine += ' -Upgrade'       }
    if ($NoPause)       { $argLine += ' -NoPause'       }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    exit
}

# ─── 1. Парсер INI ───
function Read-IniFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Не найден INI: $Path" }
    $data = @{}
    $section = ''
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq ';' -or $line[0] -eq '#') { continue }
        if ($line -match '^\[(.+?)\]$') {
            $section = $matches[1].Trim()
            if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
        $data[$section][$key] = $val
    }
    return $data
}

$cfg = Read-IniFile -Path $ConfigPath

function Get-Cfg {
    param([string]$Section, [string]$Key, [string]$Default = '')
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        $v = $cfg[$Section][$Key]
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $Default
}
function Get-CfgBool {
    param([string]$Section, [string]$Key, [bool]$Default = $false)
    $v = Get-Cfg $Section $Key ''
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v -match '^(true|1|yes|y|on)$')
}
function Get-CfgInt {
    param([string]$Section, [string]$Key, [int]$Default = 0)
    $v = Get-Cfg $Section $Key ''
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return $Default
}

# ─── 2. Конфигурация ───
$LlamaCppDir      = Get-Cfg     'paths'     'LlamaCppDir'        'D:\AI\Llama.cpp'
$ModelsDir        = Get-Cfg     'paths'     'ModelsDir'          ''
$NssmDir          = Get-Cfg     'paths'     'NssmDir'            'C:\Program Files\NSSM'
$LogsDir          = Get-Cfg     'paths'     'LogsDir'            ''
$DownloadsDir     = Get-Cfg     'paths'     'DownloadsDir'       ''
$BackupDir        = Get-Cfg     'paths'     'BackupDir'          ''
$ServiceName      = Get-Cfg     'service'   'ServiceName'        'LlamaCpp'
$StartType        = Get-Cfg     'service'   'StartType'          'SERVICE_DELAYED_AUTO_START'
$StartTimeoutSec  = Get-CfgInt  'service'   'StartTimeoutSeconds' 180
$AppRestartDelay  = Get-CfgInt  'service'   'AppRestartDelay'    10000
$AddToPath        = Get-CfgBool 'service'   'AddToPath'          $true
$AddNssmToPath    = Get-CfgBool 'service'   'AddNssmToPath'      $true
$LogRetentionDays = Get-CfgInt  'service'   'LogRetentionDays'   7
$HostOnly         = Get-Cfg     'network'   'Host'               '0.0.0.0'
$Port             = Get-CfgInt  'network'   'Port'               8080
$FirewallEnabled  = Get-CfgBool 'network'   'FirewallEnabled'    $true
$FirewallSubnet   = Get-Cfg     'network'   'FirewallSubnet'     '192.168.117.0/24'
$LlamaCppVersion  = Get-Cfg     'downloads' 'LlamaCppVersion'    'ask'
$LlamaCppUrlFallback = Get-Cfg  'downloads' 'LlamaCppUrl'        'https://github.com/ggml-org/llama.cpp/releases/download/b12184/llama-b12184-bin-win-cuda-13.5-x64.zip'
$CudartUrlFallback   = Get-Cfg  'downloads' 'CudartUrl'          'https://github.com/ggml-org/llama.cpp/releases/download/b12184/cudart-llama-bin-win-cuda-13.5-x64.zip'
$NssmUrl          = Get-Cfg     'downloads' 'NssmUrl'            'https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip'
$KeepDownloads    = Get-CfgBool 'downloads' 'KeepDownloads'      $true

# Параметры llama-server
$ModelPath        = Get-Cfg     'server'    'Model'              'D:\AI\Llama.cpp\Models\model.gguf'
$CtxSize          = Get-CfgInt  'server'    'CtxSize'            4096
$NGpuLayers       = Get-CfgInt  'server'    'NGpuLayers'         999
$FlashAttention   = Get-CfgBool 'server'    'FlashAttention'     $true
$Parallel         = Get-CfgInt  'server'    'Parallel'           1
$ExtraArgs        = Get-Cfg     'server'    'ExtraArgs'          ''
$ForceCPU         = Get-CfgBool 'server'    'ForceCPU'           $false

if ($Upgrade) {
    Write-Log "  [Upgrade] Автообновление: выбор версии отключён, будет установлена latest." -Color Magenta
    $Force = $true
    $LlamaCppVersion = 'latest'
}

# Нормализация путей
if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = Join-Path $LlamaCppDir 'Models'
} elseif (-not [IO.Path]::IsPathRooted($ModelsDir)) {
    $ModelsDir = Join-Path $LlamaCppDir $ModelsDir
}
if ([string]::IsNullOrWhiteSpace($LogsDir)) {
    $LogsDir = Join-Path $LlamaCppDir 'logs'
} elseif (-not [IO.Path]::IsPathRooted($LogsDir)) {
    $LogsDir = Join-Path $LlamaCppDir $LogsDir
}
if ([string]::IsNullOrWhiteSpace($DownloadsDir)) {
    $DownloadsDir = Join-Path $LlamaCppDir 'Downloads'
} elseif (-not [IO.Path]::IsPathRooted($DownloadsDir)) {
    $DownloadsDir = Join-Path $LlamaCppDir $DownloadsDir
}
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $LlamaCppDir 'Backup'
} elseif (-not [IO.Path]::IsPathRooted($BackupDir)) {
    $BackupDir = Join-Path $LlamaCppDir $BackupDir
}

$ModelsDir    = [IO.Path]::GetFullPath($ModelsDir)
$LogsDir      = [IO.Path]::GetFullPath($LogsDir)
$DownloadsDir = [IO.Path]::GetFullPath($DownloadsDir)
$BackupDir    = [IO.Path]::GetFullPath($BackupDir)

$ApiHost     = "${HostOnly}:${Port}"
$InstallPath = [IO.Path]::GetFullPath($scriptDir)

$protectedPaths = @(
    $InstallPath
    [IO.Path]::GetFullPath($LogsDir)
    [IO.Path]::GetFullPath($DownloadsDir)
    [IO.Path]::GetFullPath($BackupDir)
    [IO.Path]::GetFullPath($ModelsDir)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── 3. Вспомогательные функции ───

function Stop-LlamaProcesses {
    Write-Log "  → Завершение процессов llama.cpp..."
    foreach ($procName in @("llama-server", "llama-server.exe")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "    Убит процесс: $($_.Name) (PID: $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Set-LlamaAcl {
    param([string]$LlamaCppDir, [string]$ModelsDir)
    foreach ($dir in @($LlamaCppDir, $ModelsDir)) {
        if ((Test-Path $dir) -and $dir) {
            icacls $dir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
            icacls $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
        }
    }
}

function Get-FileNameFromUrl {
    param([string]$Url, [string]$Fallback = 'download.bin')
    try {
        $uri  = [Uri]$Url
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    return $Fallback
}

function Get-CachedFile {
    param([string]$Url, [string]$FileName, [string]$SubDir = '', [switch]$ForceRedownload)
    $targetDir = if ([string]::IsNullOrWhiteSpace($SubDir)) { $DownloadsDir } else { Join-Path $DownloadsDir $SubDir }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $cachePath = Join-Path $targetDir $FileName
    $urlStamp  = "$cachePath.url"

    if ($KeepDownloads -and -not $ForceRedownload) {
        if ((Test-Path -LiteralPath $cachePath) -and (Test-Path -LiteralPath $urlStamp)) {
            $cachedUrl = ''
            try { $cachedUrl = (Get-Content -LiteralPath $urlStamp -Raw -ErrorAction Stop).Trim() } catch { }
            if ($cachedUrl -eq $Url) {
                $sizeMb = [math]::Round((Get-Item -LiteralPath $cachePath).Length / 1MB, 1)
                Write-Log "  ✓ Кэш: $cachePath ($sizeMb MB)" -Color Green
                return $cachePath
            }
        }
    }

    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Force }
    if (Test-Path -LiteralPath $urlStamp)  { Remove-Item -LiteralPath $urlStamp  -Force }
    Write-Log "  → Скачивание: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $cachePath -UseBasicParsing
    if ($KeepDownloads) { Set-Content -LiteralPath $urlStamp -Value $Url -NoNewline }
    return $cachePath
}

function Add-ToMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $normalized = $parts | ForEach-Object { $_.TrimEnd('\') }
    if ($normalized -contains $Dir.TrimEnd('\')) {
        Write-Log "  ℹ Уже в PATH: $Dir (пропускаем)" -Color DarkGray
        return
    }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    Write-Log "  ✓ Добавлено в PATH: $Dir" -Color Green
    Write-Log "  ℹ Изменения вступят в силу в новых консолях" -Color DarkGray
}

function Add-NssmToMachinePath {
    param([string]$NssmDir)
    if (-not $AddNssmToPath) {
        Write-Log "  ℹ AddNssmToPath=false — NSSM в PATH не добавляем" -Color DarkGray
        return
    }
    foreach ($sub in @('win32','win64')) {
        $p = Join-Path $NssmDir $sub
        if (Test-Path -LiteralPath (Join-Path $p 'nssm.exe')) {
            Add-ToMachinePath -Dir $p
        } else {
            Write-Log "  ℹ Пропуск: $p\nssm.exe не найден" -Color DarkGray
        }
    }
}

function Get-LlamaReleases {
    param([switch]$ForceRefresh)
    $cacheFile = Join-Path $DownloadsDir '.llama_releases_cache.json'
    $cacheTtl  = 12 * 60 * 60

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cacheFile)) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $cacheTtl) {
            try { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
    }

    $headers = @{ 'User-Agent' = 'PowerShell-LlamaCpp-Deploy-Script'; 'Accept' = 'application/vnd.github+json' }
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30' -Headers $headers -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $DownloadsDir)) {
            New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
        }
        $releases | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        return $releases
    } catch {
        Write-Log "  ✗ Не удалось получить список релизов: $($_.Exception.Message)" -Color Yellow
        if (Test-Path -LiteralPath $cacheFile) { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) }
        return $null
    }
}

function Select-LlamaVersionInteractive {
    param($Releases, [string]$CurrentVersion)
    if (-not $Releases) { return $null }

    $list = @($Releases | Select-Object -First 15)
    if ($list.Count -eq 0) {
        Write-Log '  Нет доступных версий для установки.' -Color Yellow
        return $null
    }

    Write-Log ''
    Write-Log 'Доступные версии llama.cpp:' -Color Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $date = ([datetime]$list[$i].published_at).ToString('yyyy-MM-dd')
        $mark = if ($CurrentVersion -and $list[$i].tag_name -eq $CurrentVersion) { ' <-- текущая (переустановка)' } else { '' }
        $color = if ($mark) { 'Yellow' } else { 'White' }
        Write-Log ('  [{0}] {1,-16} {2}  {3}' -f ($i+1), $list[$i].tag_name, $date, $mark) -Color $color
    }
    Write-Log ''

    while ($true) {
        Write-Host 'Введите номер версии (Enter — последняя, s — отмена):' -ForegroundColor Cyan
        $ans = (Read-Host 'Выбор').Trim()

        if ([string]::IsNullOrWhiteSpace($ans)) { return $list[0] }
        if ($ans -match '^[scысSCЫС]$') { return 'CANCEL' }

        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            return $list[$n-1]
        }
        Write-Log "  Некорректный ввод: '$ans'. Введите число от 1 до $($list.Count), 's' для отмены или Enter." -Color Yellow
    }
}

function Resolve-LlamaVersion {
    param([string]$RequestedVersion, [string]$CurrentVersion, [switch]$ForceRefresh)

    if ($RequestedVersion -match '^b\d+$') { return $RequestedVersion }

    $releases = Get-LlamaReleases -ForceRefresh:$ForceRefresh
    if (-not $releases) { return $null }

    if ($RequestedVersion -eq 'ask' -and -not $Force) {
        $sel = Select-LlamaVersionInteractive -Releases $releases -CurrentVersion $CurrentVersion
        if ($sel -is [string] -and $sel -eq 'CANCEL') { return 'CANCEL' }
        if ($null -eq $sel) { return $null }
        if ($sel.tag_name) { return $sel.tag_name }
        return $null
    }

    $latest = @($releases | Where-Object { $_.tag_name -match '^b\d+$' }) | Select-Object -First 1
    if ($latest) { return $latest.tag_name }
    return $null
}

function Test-LlamaHealth {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $resp = Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($resp.status -eq 'ok')
    } catch { return $false }
}

function Test-VCRedist {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            $ver = (Get-ItemProperty $path -ErrorAction SilentlyContinue).Version
            if ($ver) {
                Write-Log "  ✓ Visual C++ Redistributable найден (версия $ver)" -Color Green
                return $true
            }
        }
    }
    Write-Log "  ✗ Visual C++ Redistributable (x64) не найден!" -Color Red
    return $false
}

function Install-VCRedist {
    $url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    $outFile = Join-Path $env:TEMP 'vc_redist.x64.exe'
    Write-Log "  → Скачивание Visual C++ Redistributable..." -Color Cyan
    try {
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
        Write-Log "  → Установка (тихий режим)..." -Color Cyan
        $p = Start-Process -FilePath $outFile -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -NoNewWindow
        Write-Log "  → Код возврата: $($p.ExitCode)" -Color DarkGray
        if ($p.ExitCode -in @(0, 1638, 3010)) {
            Write-Log "  ✓ Visual C++ Redistributable установлен." -Color Green
            return $true
        }
        Write-Log "  ✗ Установка завершилась с кодом $($p.ExitCode)" -Color Red
        return $false
    } catch {
        Write-Log "  ✗ Ошибка установки VC++ Redist: $_" -Color Red
        return $false
    } finally {
        if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    }
}

function Test-CudaCompatibility {
    param([string]$RequiredVersion)
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        $smiPath = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
        if (Test-Path $smiPath) {
            $nvidiaSmi = $smiPath
        } else {
            Write-Log "  ✗ nvidia-smi не найден. Драйвер NVIDIA не установлен." -Color Red
            return $false
        }
    } else {
        $nvidiaSmi = 'nvidia-smi'
    }

    try {
        $smiOut = & $nvidiaSmi 2>&1 | Out-String

        # Поддерживаем оба формата: "CUDA Version: X.Y" и "CUDA UMD Version: X.Y"
        $cudaVer = $null
        if ($smiOut -match 'CUDA\s+(?:UMD\s+)?Version:\s*(\d+\.\d+)') {
            $cudaVer = [version]$matches[1]
        }

        if (-not $cudaVer) {
            Write-Log "  ✗ Не удалось распарсить версию CUDA из nvidia-smi" -Color Red
            Write-Log "    Первые строки вывода:" -Color DarkGray
            $smiOut -split "`n" | Select-Object -First 6 | ForEach-Object { Write-Log "      $_" -Color DarkGray }
            return $false
        }

        # Извлекаем объём VRAM (первое число MiB/N/A в строке GPU)
        $vramMb = $null
        if ($smiOut -match '(\d+)MiB\s*/\s*(\d+)MiB') {
            $vramMb = [int]$matches[2]
        }

        $reqVer = [version]($RequiredVersion -replace 'cuda-','' -replace '\.\d+$','')
        Write-Log "  ℹ Драйвер поддерживает CUDA $cudaVer (требуется >= $reqVer)" -Color DarkGray
        if ($vramMb) {
            Write-Log "  ℹ VRAM: $vramMb MiB" -Color DarkGray
            if ($vramMb -lt 8000) {
                Write-Log "  ⚠ Мало VRAM ($vramMb MiB). Для 7B-модели рекомендуется -ngl <= 30, CtxSize <= 4096" -Color Yellow
            }
        }

        if ($cudaVer.Major -ge $reqVer.Major) {
            Write-Log "  ✓ Версия CUDA совместима." -Color Green
            return $true
        }
        Write-Log "  ✗ Версия CUDA несовместима! Требуется $reqVer.x, обнаружена $cudaVer" -Color Red
        return $false
    } catch {
        Write-Log "  ✗ Не удалось запустить nvidia-smi: $_" -Color Red
        return $false
    }
}

function Test-LlamaServeDirect {
    param([string]$Exe, [string]$Args, [int]$WaitSec = 15)
    Write-Log "  → Прямой запуск llama-server.exe ($WaitSec сек)..."
    Write-Log "    Аргументы: $Args"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Асинхронно читаем оба потока, чтобы не заблокировать процесс
        $stdoutSb = New-Object System.Text.StringBuilder
        $stderrSb = New-Object System.Text.StringBuilder
        $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
            if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
        } -MessageData $stdoutSb
        $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
            if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
        } -MessageData $stderrSb
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        Start-Sleep -Seconds $WaitSec
        $exited = $proc.HasExited
        $exitCode = if ($exited) { $proc.ExitCode } else { $null }

        Start-Sleep -Milliseconds 500

        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue

        if (-not $exited) {
            Write-Log "    ✓ Процесс РАБОТАЕТ после $WaitSec сек (значит бинарник и модель ок)" -Color Green
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(3000) | Out-Null } catch {}
        } else {
            Write-Log "    ✗ Процесс УПАЛ с кодом $exitCode" -Color Red
        }

        $stdout = $stdoutSb.ToString()
        $stderr = $stderrSb.ToString()

        if ($stderr -and $stderr.Trim()) {
            Write-Log "    STDERR:" -Color Yellow
            $stderr -split "`n" | Select-Object -First 40 | ForEach-Object { Write-Log "      $_" -Color DarkGray }
        }
        if ($stdout -and $stdout.Trim()) {
            Write-Log "    STDOUT (первые 30 строк):" -Color Yellow
            $stdout -split "`n" | Select-Object -First 30 | ForEach-Object { Write-Log "      $_" -Color DarkGray }
        }
        return ($exited -eq $false)
    } catch {
        Write-Log "    Не удалось запустить тест: $_" -Color Red
        return $false
    }
}

function Start-LlamaService {
    param([string]$NssmExe, [string]$ServiceName, [int]$TimeoutSec, [int]$MaxAttempts = 3)
    $started = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "  → Попытка запуска $attempt из $MaxAttempts..."
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Служба $ServiceName не найдена после установки" }
        if ($svc.Status -eq 'Running') { $started = $true; break }
        & $NssmExe start $ServiceName 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastStatus = ''
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $svc.Refresh()
            $status = $svc.Status
            if ($status -ne $lastStatus) {
                Write-Log "    Статус: $status"
                $lastStatus = $status
            }
            if ($status -eq 'Running') { $started = $true; break }
            if ($status -eq 'Stopped' -and $sw.Elapsed.TotalSeconds -gt 3) {
                Write-Log "  ⚠ Служба упала через $([int]$sw.Elapsed.TotalSeconds) сек после запуска" -Color Yellow
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($started) { break }
        if ($attempt -lt $MaxAttempts) {
            Write-Log "  → Пауза 5 сек перед повтором..."
            Start-Sleep -Seconds 5
        }
    }
    if ($started) {
        Write-Log "  ✓ Статус: Running" -Color Green
        return $true
    }

    Write-Log ""
    Write-Log "Служба не запустилась за $MaxAttempts × $TimeoutSec сек." -Color Yellow
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) { Write-Log "  Текущий статус : $($svc.Status)" -Color Yellow }
    try {
        $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($svcInfo -and $null -ne $svcInfo.ExitCode) {
            Write-Log "  ExitCode       : $($svcInfo.ExitCode)" -Color Yellow
        }
    } catch {}
    foreach ($logFile in @(
        (Join-Path $LogsDir 'llama-server.err.log'),
        (Join-Path $LogsDir 'llama-server.out.log')
    ) | Select-Object -Unique) {
        if (Test-Path $logFile) {
            $lines = @(Get-Content $logFile -Tail 20 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                Write-Log "`n  Файл $logFile (последние строки):" -Color Yellow
                $lines | ForEach-Object { Write-Log "    $_" -Color DarkGray }
            }
        }
    }
    Write-Log "`n  nssm dump $ServiceName :" -Color Yellow
    try {
        $oemCodePage = 866
        try {
            $oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            if ($oemCp -gt 0) { $oemCodePage = [int]$oemCp }
        } catch { }
        $origOutputEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding($oemCodePage)
            & $NssmExe dump $ServiceName 2>&1 | ForEach-Object { Write-Log "    $_" -Color DarkGray }
        } finally {
            [Console]::OutputEncoding = $origOutputEncoding
        }
    } catch {}
    return $false
}

# ─── 4. Основной блок try ───
try {
    $llamaServerExe = Join-Path $LlamaCppDir 'llama-server.exe'
    $currentVersion = $null

    if (Test-Path $llamaServerExe) {
        $verOut = (& $llamaServerExe --version 2>&1) -join ' '
        if ($verOut -match 'version:\s*(\d+)\s*\(([0-9a-f]+)\)') {
            $currentVersion = "b$($matches[1])"
            Write-Log "`n  ℹ Обнаружена установленная версия: $currentVersion" -Color Green
        } elseif ($verOut -match 'b(\d+)') {
            $currentVersion = "b$($matches[1])"
            Write-Log "`n  ℹ Обнаружена установленная версия: $currentVersion" -Color Green
        }
    } else {
        Write-Log "`n  ℹ llama.cpp не установлен — будет выполнена первичная установка." -Color Cyan
    }

    Write-Step "Выбор версии llama.cpp"
    $targetVersion = $null
    if ($currentVersion -and -not $forceDL -and -not $Upgrade) {
        Write-Log "  Текущая версия: $currentVersion" -Color Cyan
        $resolvedVersion = Resolve-LlamaVersion -RequestedVersion $LlamaCppVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($resolvedVersion -is [string] -and $resolvedVersion -eq 'CANCEL') {
            Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $resolvedVersion) {
            if ($Force) { throw "Не удалось определить версию." }
            $resolvedVersion = $currentVersion
        }
        $targetVersion = $resolvedVersion
    } else {
        $targetVersion = Resolve-LlamaVersion -RequestedVersion $LlamaCppVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($targetVersion -is [string] -and $targetVersion -eq 'CANCEL') {
            Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $targetVersion) {
            Write-Log '  ⚠ Не удалось определить версию. Используем резервный URL из INI.' -Color Yellow
            $targetVersion = 'b12184'
        }
    }

    $isReinstall = $false
    $isUpgrade   = $false
    if ($currentVersion -and $targetVersion) {
        if ($currentVersion -eq $targetVersion) {
            $isReinstall = $true
            Write-Log "`n  ℹ Та же версия: $targetVersion (переустановка)" -Color Yellow
            if (-not $Force) {
                $ans = Read-Host "Переустановить текущую версию $currentVersion? [Y/n]"
                if ($ans -eq 'n' -or $ans -eq 'N') {
                    Write-Log "`n  Установка отменена пользователем. Служба не тронута." -Color Yellow
                    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
                    exit 0
                }
            }
        } else {
            $isUpgrade = $true
            Write-Log "`n  → Обновление/даунгрейд: $currentVersion → $targetVersion" -Color Cyan
        }
    } elseif ($targetVersion) {
        Write-Log "`n  → Первичная установка: $targetVersion" -Color Cyan
    }

    $needsBackup = ($currentVersion -and (Test-Path $LlamaCppDir))
    Write-Log ""
    Write-Log "  План действий:" -Color Cyan
    Write-Log "    • Текущая версия : $(if($currentVersion){$currentVersion} else {'—'})"
    Write-Log "    • Целевая версия : $targetVersion"
    Write-Log "    • Режим          : $(if($isReinstall){'переустановка'} elseif($isUpgrade){'обновление/даунгрейд'} else {'первичная установка'})"
    Write-Log "    • Бэкап          : $(if($needsBackup){'будет создан'} else {'не требуется'})"
    Write-Log "    • Модель         : $ModelPath"
    Write-Log "    • ForceCPU       : $ForceCPU"

    if (-not $Force -and $needsBackup) {
        Write-Host ""
        if ((Read-Host 'Продолжить? [Y/n]') -eq 'n') {
            Write-Log "  Отменено. Служба не тронута." -Color Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
    }

    $llamaDownloadUrl  = "https://github.com/ggml-org/llama.cpp/releases/download/$targetVersion/llama-$targetVersion-bin-win-cuda-13.5-x64.zip"
    $cudartDownloadUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$targetVersion/cudart-llama-bin-win-cuda-13.5-x64.zip"

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Step "Остановка существующей службы $ServiceName"
        & sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    Stop-LlamaProcesses

    # ─── Проверка зависимостей ───
    Write-Step "Проверка системных зависимостей"

    if (-not (Test-VCRedist)) {
        Write-Log "  → Попытка автоматической установки..." -Color Yellow
        if (-not (Install-VCRedist)) {
            Write-Log "  ⚠ Не удалось установить VC++ Redist автоматически." -Color Yellow
            Write-Log "  ⚠ Установите вручную: https://aka.ms/vs/17/release/vc_redist.x64.exe" -Color Yellow
            if (-not $Force) {
                $ans = Read-Host 'Продолжить установку? [y/N]'
                if ($ans -ne 'y') { throw 'Отменено пользователем (нет VC++ Redist)' }
            }
        } elseif (-not (Test-VCRedist)) {
            throw "Visual C++ Redistributable всё ещё не обнаружен после установки."
        }
    }

    $useGpu = -not $ForceCPU
    if ($useGpu) {
        $cudaRequired = if ($llamaDownloadUrl -match 'cuda-(\d+\.\d+)') { $matches[1] } else { '13.5' }
        if (-not (Test-CudaCompatibility -RequiredVersion $cudaRequired)) {
            Write-Log "  ⚠ CUDA несовместима или не найдена. Служба может не запуститься." -Color Yellow
            Write-Log "  ℹ Установите ForceCPU=true в INI, чтобы запустить без GPU." -Color Yellow
            if (-not $Force) {
                $ans = Read-Host 'Продолжить установку с GPU? [y/N]'
                if ($ans -ne 'y') { throw 'Отменено пользователем (CUDA)' }
            }
        }
    } else {
        Write-Log "  ℹ ForceCPU=true — проверка CUDA пропущена, служба будет запущена без GPU." -Color DarkGray
    }

    # ─── Проверка модели ───
    Write-Step "Проверка файла модели"
    if (-not (Test-Path -LiteralPath $ModelPath)) {
        Write-Log "  ✗ Файл модели не найден: $ModelPath" -Color Red
        Write-Log "  ℹ Положите .gguf файл по этому пути или измените [server] Model в INI." -Color Yellow
        if (-not $Force) {
            $ans = Read-Host 'Продолжить всё равно? Служба скорее всего упадёт. [y/N]'
            if ($ans -ne 'y') { throw 'Отменено пользователем (нет модели)' }
        }
    } else {
        $modelSizeMb = [math]::Round((Get-Item -LiteralPath $ModelPath).Length / 1MB, 1)
        Write-Log "  ✓ Модель найдена: $ModelPath ($modelSizeMb MB)" -Color Green
    }

    Write-Step "Проверка порта $Port"
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        $pids = ($busy.OwningProcess | Sort-Object -Unique) -join ', '
        Write-Log "Порт $Port уже занят PID: $pids" -Color Yellow
        if (-not $Force) {
            $ans = Read-Host 'Продолжить? [y/N]'
            if ($ans -ne 'y') { throw 'Отменено пользователем' }
        }
    } else {
        Write-Log '  ✓ Свободен' -Color Green
    }

    Write-Step 'Создание каталогов'
    foreach ($d in @($LlamaCppDir, $ModelsDir, $LogsDir, $NssmDir, $DownloadsDir, $BackupDir) | Select-Object -Unique) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Log "  ✓ $d"
    }

    Write-Step 'Права доступа'
    Set-LlamaAcl -LlamaCppDir $LlamaCppDir -ModelsDir $ModelsDir
    Write-Log "  ✓ Права Full Control выданы (SYSTEM + Administrators)" -Color Green

    Write-Step "Установка NSSM в $NssmDir"
    $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\win64\\' } |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $nssmExe -or $forceDL) {
        $nssmZipName = Get-FileNameFromUrl -Url $NssmUrl -Fallback 'NSSM.zip'
        $nssmVer = if ($NssmUrl -match '/download/([^/]+)/') { $matches[1] -replace '^v', '' } else { 'unknown' }
        $nssmSubDir = "nssm_$nssmVer"
        $nssmZip     = Get-CachedFile -Url $NssmUrl -FileName $nssmZipName -SubDir $nssmSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $nssmZip -DestinationPath $NssmDir -Force
        if (-not $KeepDownloads) { Remove-Item -LiteralPath $nssmZip -Force -ErrorAction SilentlyContinue }
        $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
        if (-not $nssmExe) { $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Select-Object -First 1 -ExpandProperty FullName }
        if (-not $nssmExe) { throw "nssm.exe не найден после распаковки в $NssmDir" }
    }
    Write-Log "  ✓ $nssmExe"

    Write-Step 'Добавление NSSM в Machine PATH'
    Add-NssmToMachinePath -NssmDir $NssmDir

    $backupPath = $null
    if ($needsBackup) {
        Write-Step "Создание резервной копии (только бинарники)"
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupName = "LlamaCpp_$timestamp"
        $backupPath = Join-Path $BackupDir $backupName
        try {
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            $itemsToBackup = Get-ChildItem -Path $LlamaCppDir | Where-Object {
                $fp = [IO.Path]::GetFullPath($_.FullName)
                $protectedPaths -notcontains $fp
            }
            foreach ($item in $itemsToBackup) {
                Copy-Item -Path $item.FullName -Destination $backupPath -Recurse -Force
            }
            Write-Log "  ✓ Резервная копия создана: $backupPath" -Color Green
            Write-Log "  ℹ Папки install, logs, Downloads, Backup, Models не копировались" -Color DarkGray
        } catch {
            throw "Не удалось создать резервную копию (файлы заняты?). Ошибка: $_"
        }
    }

    Write-Step "Очистка старых бинарников (защищённые папки сохраняются)"
    if ($needsBackup) {
        $itemsToRemove = Get-ChildItem -Path $LlamaCppDir | Where-Object {
            $fp = [IO.Path]::GetFullPath($_.FullName)
            $protectedPaths -notcontains $fp
        }
        foreach ($item in $itemsToRemove) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "  ✓ Старые бинарники удалены" -Color Green
    }

    if ($LogRetentionDays -gt 0 -and (Test-Path $LogsDir)) {
        Write-Log "  → Ротация логов: удаление файлов старше $LogRetentionDays дней из $LogsDir" -Color DarkGray
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $LogsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Set-LlamaAcl -LlamaCppDir $LlamaCppDir -ModelsDir $ModelsDir
    Write-Log "  ✓ Права Full Control повторно применены" -Color Green

    Write-Step "Установка llama.cpp в $LlamaCppDir"
    if ($needsBackup -or -not (Test-Path $llamaServerExe) -or $forceDL) {
        Write-Log "  → Целевая версия: $targetVersion" -Color Green
        $llamaSubDir  = 'llama_' + $targetVersion
        $cudartSubDir = 'cudart_' + $targetVersion
        $llamaZip     = Get-CachedFile -Url $llamaDownloadUrl -FileName "llama-$targetVersion-bin-win-cuda-13.5-x64.zip" -SubDir $llamaSubDir -ForceRedownload:$forceDL
        $cudartZip    = Get-CachedFile -Url $cudartDownloadUrl -FileName "cudart-llama-bin-win-cuda-13.5-x64.zip" -SubDir $cudartSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $llamaZip -DestinationPath $LlamaCppDir -Force
        Expand-Archive -Path $cudartZip -DestinationPath $LlamaCppDir -Force
        if (-not $KeepDownloads) {
            Remove-Item -LiteralPath $llamaZip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $cudartZip -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "  ℹ Установка не требуется (используется текущая)"
    }

    $verRaw = (& $llamaServerExe --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { throw "llama-server.exe --version завершился с кодом $LASTEXITCODE." }
    Write-Log "  ✓ $verRaw" -Color Green

    Write-Step 'Переменные окружения (Machine)'
    [Environment]::SetEnvironmentVariable('LLAMA_CPP_DIR', $LlamaCppDir, 'Machine')
    Write-Log "  ✓ LLAMA_CPP_DIR=$LlamaCppDir"

    if ($AddToPath) {
        Write-Step "Переменная PATH (Machine)"
        Add-ToMachinePath -Dir $LlamaCppDir
    } else {
        Write-Log "`n  ℹ AddToPath=false — PATH не изменяем" -Color DarkGray
    }

    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        Write-Step "Правило брандмауэра ($FirewallSubnet)"
        $ruleName = "LlamaCpp API ($FirewallSubnet)"
        Get-NetFirewallRule -DisplayName "LlamaCpp API*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $FirewallSubnet -Action Allow -Profile Any | Out-Null
        Write-Log "  ✓ $ruleName" -Color Green
    }

    # ─── Формирование аргументов сервера ───
    $serverArgs = @(
        '--model', "`"$ModelPath`"",
        '--host', $HostOnly,
        '--port', "$Port",
        '--ctx-size', "$CtxSize",
        '--parallel', "$Parallel"
    )
    if ($useGpu) {
        $serverArgs += @('-ngl', "$NGpuLayers")
        if ($FlashAttention) { $serverArgs += '-fa' }
    } else {
        $serverArgs += @('-ngl', '0')
    }
    if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) {
        $serverArgs += ($ExtraArgs -split ' ' | Where-Object { $_ -ne '' })
    }
    $serverArgsLine = $serverArgs -join ' '

    Write-Step "Регистрация службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Log '  → Остановка старой службы'
        & $nssmExe stop $ServiceName 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
        }
        Write-Log '  → Удаление старой службы'
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
        $sw.Restart()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
        }
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            Write-Log "  NSSM не удалил службу, принудительно через sc.exe" -Color Yellow
            & sc.exe delete $ServiceName 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            throw "Не удалось удалить старую службу $ServiceName"
        }
    }

    & $nssmExe install $ServiceName $llamaServerExe $serverArgsLine 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Ошибка NSSM при установке службы (код $LASTEXITCODE)." }
    & $nssmExe set $ServiceName AppDirectory $LlamaCppDir 2>&1 | Out-Null
    & $nssmExe set $ServiceName Start $StartType 2>&1 | Out-Null
    & $nssmExe set $ServiceName Description "llama.cpp is a high-performance inference engine for large language models. This service exposes the llama-server HTTP API with CUDA acceleration." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'llama-server.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'llama-server.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500 2>&1 | Out-Null
    Write-Log '  ✓ Служба сконфигурирована' -Color Green
    Write-Log "  Аргументы: $serverArgsLine" -Color DarkGray

    Write-Step 'Запуск службы'
    $ok = Start-LlamaService -NssmExe $nssmExe -ServiceName $ServiceName -TimeoutSec $StartTimeoutSec -MaxAttempts 3
    if (-not $ok) {
        Write-Log "`n=== ДОПОЛНИТЕЛЬНАЯ ДИАГНОСТИКА ===" -Color Yellow

        Write-Log "`n  [1/3] Остановка службы, чтобы освободить порт..." -Color Cyan
        & $nssmExe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Stop-LlamaProcesses

        Write-Log "`n  [2/3] Запуск с --verbose (полный лог)..." -Color Cyan
        $verboseArgs = $serverArgsLine + ' --verbose'
        $diagVerboseOk = Test-LlamaServeDirect -Exe $llamaServerExe -Args $verboseArgs -WaitSec 15

        Write-Log "`n  [3/3] Запуск в режиме CPU (-ngl 0)..." -Color Cyan
        $cpuArgs = $serverArgsLine -replace '-ngl \d+', '-ngl 0'
        $cpuArgs = $cpuArgs -replace ' -fa\b', ''
        $diagCpuOk = Test-LlamaServeDirect -Exe $llamaServerExe -Args $cpuArgs -WaitSec 15

        if ($diagCpuOk) {
            Write-Log "`n  ⚠ ВАЖНО: процесс РАБОТАЕТ в режиме CPU, но падает с GPU." -Color Yellow
            Write-Log "  → Проблема в CUDA/драйвере/VRAM, а не в бинарнике или модели." -Color Yellow
            Write-Log "  → Решения:" -Color Yellow
            Write-Log "     1. Установите ForceCPU=true в [server] INI (временно, для работы)" -Color Yellow
            Write-Log "     2. Обновите драйвер NVIDIA" -Color Yellow
            Write-Log "     3. Уменьшите -ngl (например, 20) и/или --ctx-size" -Color Yellow
        } elseif ($diagVerboseOk) {
            Write-Log "`n  ⚠ Процесс работает при прямом запуске с --verbose, но NSSM не запускает." -Color Yellow
            Write-Log "  → Проблема в конфигурации NSSM (права, рабочая директория, окружение)" -Color Yellow
            Write-Log "  → Проверьте вывод 'nssm dump' выше" -Color Yellow
        } else {
            Write-Log "`n  ✗ Процесс падает и при прямом запуске. Смотрите STDERR выше." -Color Red
            Write-Log "  → Вероятные причины: битый бинарник, отсутствует DLL, неверные аргументы" -Color Red
        }

        throw "Служба $ServiceName не запустилась. Смотрите диагностику выше."
    }

    Write-Step 'Проверка API через /health'
    $maxAttempts = 40
    $apiOk = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 3
        if (Test-LlamaHealth -Url "http://127.0.0.1:$Port/health") {
            $apiOk = $true
            Write-Log "  ✓ Попытка ${i}: /health отвечает status=ok" -Color Green
            break
        } else {
            Write-Log "  … Попытка ${i}/${maxAttempts}: /health пока не готов"
        }
    }
    if (-not $apiOk) {
        Write-Log "/health не ответил за $($maxAttempts * 3) секунд." -Color Yellow
        Write-Log "Загрузка большой модели может занимать несколько минут. Проверьте вручную:" -Color Yellow
        Write-Log "  curl http://127.0.0.1:$Port/health" -Color Yellow
        Write-Log "  Get-Content '$LogsDir\llama-server.out.log' -Tail 30" -Color Yellow
    }

    $actionLabel = if ($isReinstall) { 'переустановка' } elseif ($isUpgrade) { 'обновление/даунгрейд' } else { 'первичная установка' }
    Write-Log "`n=============================" -Color Green
    Write-Log " Развёртывание завершено ($actionLabel)" -Color Green
    Write-Log '=============================' -Color Green
    Write-Log " Служба      : $ServiceName"
    Write-Log " Версия      : $(if($currentVersion){$currentVersion} else {'не была установлена'}) -> $(if($targetVersion){$targetVersion} else {'N/A'})"
    Write-Log " Бинарник    : $llamaServerExe"
    Write-Log " Модель      : $ModelPath"
    Write-Log " Логи        : $LogsDir"
    Write-Log " Архивы      : $DownloadsDir\llama_$targetVersion"
    if ($backupPath) { Write-Log " Бэкап       : $backupPath" } else { Write-Log " Бэкапы      : $BackupDir (не требуется)" }
    Write-Log " API локально: http://127.0.0.1:$Port"
    Write-Log " Health-check: http://127.0.0.1:$Port/health"
    Write-Log " Параметры   : CtxSize=$CtxSize, NGpuLayers=$NGpuLayers, FA=$FlashAttention, Parallel=$Parallel, ForceCPU=$ForceCPU"

    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        $localIps = @()
        try {
            $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and $_.PrefixOrigin -ne 'WellKnown' }
            foreach ($ip in $ips) {
                $networkIp = $FirewallSubnet -replace '/.*$'
                $prefixLen = [int]($FirewallSubnet -replace '^.*/', '')
                $ipBytes = ([System.Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes()
                $netBytes = ([System.Net.IPAddress]::Parse($networkIp)).GetAddressBytes()
                $ipNum = [uint32]$ipBytes[0] -shl 24 -bor [uint32]$ipBytes[1] -shl 16 -bor [uint32]$ipBytes[2] -shl 8 -bor [uint32]$ipBytes[3]
                $netNum = [uint32]$netBytes[0] -shl 24 -bor [uint32]$netBytes[1] -shl 16 -bor [uint32]$netBytes[2] -shl 8 -bor [uint32]$netBytes[3]
                $mask = if ($prefixLen -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefixLen)) }
                if (($ipNum -band $mask) -eq ($netNum -band $mask)) { $localIps += $ip.IPAddress }
            }
        } catch {}
        if ($localIps.Count -gt 0) {
            foreach ($ip in $localIps) { Write-Log " API по сети : http://${ip}:$Port ($FirewallSubnet)" }
        } else {
            Write-Log " API по сети : http://<IP-сервера>:$Port ($FirewallSubnet)"
        }
    }

    if ($AddToPath) { Write-Log " PATH        : $LlamaCppDir добавлен (нужна новая консоль)" }
    if ($AddNssmToPath) { Write-Log " NSSM PATH   : $NssmDir\win32 и \win64 (нужна новая консоль)" }
    Write-Log " Проверка    : curl http://127.0.0.1:$Port/health"
}
catch {
    Write-Log "`nERROR: $_" -Color Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
