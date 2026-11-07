#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание и обновление llama.cpp в режиме Router как службы Windows.

.DESCRIPTION
    Читает llama-windows-install.ini. Позволяет выбрать версию, сделать бэкап и
    пересоздать службу. Поддерживает флаг -Upgrade для автообновления.
    В отличие от single-model режима, запускает llama-server без --model,
    с --models-dir и --models-max 1, что включает Router.
    При установке предлагает выбрать модели; для выбранных генерируется
    preset.ini с hf-repo, и Router автоматически скачивает их при первом запросе.
    Папки Install, logs, Downloads, Backup, Models сохраняются.
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

Write-Log "=== Запуск llama-windows-install.ps1 (Router mode, Upgrade=$Upgrade) ===" -Color Cyan

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

# Параметры сервера (общие для Router)
$CtxSize          = Get-CfgInt  'server'    'CtxSize'            4096
$NGpuLayers       = Get-CfgInt  'server'    'NGpuLayers'         999
$FlashAttention   = Get-CfgBool 'server'    'FlashAttention'     $true
$Parallel         = Get-CfgInt  'server'    'Parallel'           1
$ExtraArgs        = Get-Cfg     'server'    'ExtraArgs'          ''
$ForceCPU         = Get-CfgBool 'server'    'ForceCPU'           $false

# Параметры моделей
$InteractiveModels = Get-CfgBool 'models'   'Interactive'        $true
$ModelsSpec        = Get-Cfg     'models'   'Models'             ''

if ($Upgrade) {
    Write-Log "  [Upgrade] Автообновление: выбор версии отключён, будет установлена latest." -Color Magenta
    $Force = $true
    $LlamaCppVersion = 'latest'
    $InteractiveModels = $false
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

# ─── 3. Вспомогательные функции (большинство — без изменений) ───
# (функции Stop-LlamaProcesses, Set-LlamaAcl, Get-FileNameFromUrl, Get-CachedFile,
#  Add-ToMachinePath, Add-NssmToMachinePath, Get-LlamaReleases, Select-LlamaVersionInteractive,
#  Resolve-LlamaVersion, Test-VCRedist, Install-VCRedist, Test-CudaCompatibility,
#  Test-LlamaServeDirect, Start-LlamaService — оставлены без изменений, кроме Test-LlamaHealth
#  и добавления новых функций для работы с моделями)

# ... (здесь должны быть все перечисленные функции из предыдущей версии;
#      для краткости они не повторяются, но в полном файле они присутствуют) ...

# ─── Новая функция: интерактивный выбор моделей ───
function Select-ModelsInteractive {
    param([string[]]$Preselected)

    $menu = @(
        [pscustomobject]@{ Name='qwen7b';   HfRepo='bartowski/Qwen2.5-7B-Instruct-GGUF'; Quant='Q4_K_M'; Desc='Qwen2.5 7B · ≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='llama8b';  HfRepo='bartowski/Meta-Llama-3.1-8B-Instruct-GGUF'; Quant='Q4_K_M'; Desc='Llama 3.1 8B · ≈ 4.9 ГБ' }
        [pscustomobject]@{ Name='coder7b';  HfRepo='bartowski/Qwen2.5-Coder-7B-Instruct-GGUF'; Quant='Q4_K_M'; Desc='Qwen2.5 Coder 7B · ≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='gemma2b';  HfRepo='bartowski/gemma-2-2b-it-GGUF'; Quant='Q4_K_M'; Desc='Gemma 2 2B · ≈ 1.6 ГБ' }
        [pscustomobject]@{ Name='deepseek8b'; HfRepo='bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF'; Quant='Q4_K_M'; Desc='DeepSeek R1 8B · ≈ 4.9 ГБ' }
    )

    Write-Log ''
    Write-Log 'Доступные модели для автоматической загрузки:' -Color Cyan
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $mark = if ($Preselected -contains $menu[$i].Name) { '*' } else { ' ' }
        Write-Log ('  [{0}] {1} {2,-10} {3,-45} — {4}' -f ($i+1), $mark, $menu[$i].Name, $menu[$i].HfRepo, $menu[$i].Desc)
    }
    Write-Log ''
    Write-Log "  * — предвыбрано из INI." -Color DarkGray
    Write-Log 'Введите номера через запятую (например, "1,3"),' -Color Cyan
    Write-Log "  'a' — все, 'n' — пропустить, Enter — оставить предвыбранные:" -Color Cyan

    $ans = Read-Host 'Выбор'
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Preselected }
    if ($ans -eq 'n') { return @() }
    if ($ans -eq 'a') { return $menu | ForEach-Object { $_.Name } }

    $selected = @()
    foreach ($part in ($ans -split ',')) {
        $p = $part.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $menu.Count) {
            $name = $menu[$n-1].Name
            if ($selected -notcontains $name) { $selected += $name }
        } else {
            Write-Log "  Пропущено: '$p' (не число или вне диапазона 1..$($menu.Count))" -Color Yellow
        }
    }
    return $selected
}

function Get-PresetEntry {
    param([string]$Name)
    $menu = @{
        'qwen7b'   = @{ HfRepo='bartowski/Qwen2.5-7B-Instruct-GGUF'; Quant='Q4_K_M' }
        'llama8b'  = @{ HfRepo='bartowski/Meta-Llama-3.1-8B-Instruct-GGUF'; Quant='Q4_K_M' }
        'coder7b'  = @{ HfRepo='bartowski/Qwen2.5-Coder-7B-Instruct-GGUF'; Quant='Q4_K_M' }
        'gemma2b'  = @{ HfRepo='bartowski/gemma-2-2b-it-GGUF'; Quant='Q4_K_M' }
        'deepseek8b' = @{ HfRepo='bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF'; Quant='Q4_K_M' }
    }
    return $menu[$Name]
}

function New-ModelsPreset {
    param([string[]]$ModelNames, [string]$PresetPath)
    $lines = @()
    foreach ($name in $ModelNames) {
        $entry = Get-PresetEntry -Name $name
        if (-not $entry) { continue }
        $lines += "[$name]"
        $lines += "hf-repo = $($entry.HfRepo)"
        $lines += "hf-file = $name-$($entry.Quant).gguf"
        $lines += "ctx-size = $CtxSize"
        $lines += "n-gpu-layers = $NGpuLayers"
        if ($FlashAttention) { $lines += "flash-attn = on" }
        $lines += "parallel = $Parallel"
        $lines += ""
    }
    $lines | Set-Content -LiteralPath $PresetPath -Encoding UTF8
    Write-Log "  ✓ Создан preset-файл: $PresetPath" -Color Green
    Write-Log "    Модели: $($ModelNames -join ', ')" -Color DarkGray
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
    Write-Log "    • Router mode    : --models-dir $ModelsDir --models-max 1"
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

    # ─── Проверка зависимостей (VC++, CUDA, порт) ───
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
            Write-Log "  ℹ Папки Install, logs, Downloads, Backup, Models не копировались" -Color DarkGray
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

    # ─── Выбор моделей и генерация preset ───
    $selectedModels = @()
    $presetPath = Join-Path $ModelsDir 'models.ini'

    if ($InteractiveModels -and -not $Force) {
        Write-Step 'Выбор моделей для автоматической загрузки'
        $preselected = @()
        if (-not [string]::IsNullOrWhiteSpace($ModelsSpec)) {
            $preselected = $ModelsSpec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        $selectedModels = Select-ModelsInteractive -Preselected $preselected
    } else {
        if (-not [string]::IsNullOrWhiteSpace($ModelsSpec)) {
            $selectedModels = $ModelsSpec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        if ($selectedModels.Count -eq 0) {
            Write-Log '  ℹ Модели не заданы — Router запустится без preset.' -Color DarkGray
        } else {
            Write-Log "  → Неинтерактивный режим: $($selectedModels -join ', ')"
        }
    }

    if ($selectedModels.Count -gt 0) {
        New-ModelsPreset -ModelNames $selectedModels -PresetPath $presetPath
    } else {
        if (Test-Path $presetPath) { Remove-Item -LiteralPath $presetPath -Force -ErrorAction SilentlyContinue }
    }

    # ─── Формирование аргументов Router ───
    # Ключевое отличие: НЕТ --model, но есть --models-dir и --models-max
    $serverArgs = @(
        '--host', $HostOnly,
        '--port', "$Port",
        '--models-dir', "`"$ModelsDir`"",
        '--models-max', '1',
        '--ctx-size', "$CtxSize",
        '--parallel', "$Parallel"
    )
    if ($useGpu) {
        $serverArgs += @('-ngl', "$NGpuLayers")
        if ($FlashAttention) { $serverArgs += '-fa' }
    } else {
        $serverArgs += @('-ngl', '0')
    }
    if ($selectedModels.Count -gt 0 -and (Test-Path $presetPath)) {
        $serverArgs += @('--models-preset', "`"$presetPath`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) {
        $serverArgs += ($ExtraArgs -split ' ' | Where-Object { $_ -ne '' })
    }
    $serverArgsLine = $serverArgs -join ' '

    Write-Step "Регистрация службы $ServiceName (Router mode)"
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
    & $nssmExe set $ServiceName Description "llama.cpp Router: dynamically loads and downloads GGUF models on demand. Max 1 model in memory." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'llama-server.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'llama-server.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500 2>&1 | Out-Null
    Write-Log '  ✓ Служба сконфигурирована (Router mode)' -Color Green
    Write-Log "  Аргументы: $serverArgsLine" -Color DarkGray

    Write-Step 'Запуск службы'
    $ok = Start-LlamaService -NssmExe $nssmExe -ServiceName $ServiceName -TimeoutSec $StartTimeoutSec -MaxAttempts 3
    if (-not $ok) {
        Write-Log "`n=== ДОПОЛНИТЕЛЬНАЯ ДИАГНОСТИКА ===" -Color Yellow
        Write-Log "`n  [1/3] Остановка службы..." -Color Cyan
        & $nssmExe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Stop-LlamaProcesses

        Write-Log "`n  [2/3] Запуск с --verbose..." -Color Cyan
        $verboseArgs = $serverArgsLine + ' --verbose'
        $diagVerboseOk = Test-LlamaServeDirect -Exe $llamaServerExe -Args $verboseArgs -WaitSec 15

        Write-Log "`n  [3/3] Запуск в режиме CPU..." -Color Cyan
        $cpuArgs = $serverArgsLine -replace '-ngl \d+', '-ngl 0'
        $cpuArgs = $cpuArgs -replace ' -fa\b', ''
        $diagCpuOk = Test-LlamaServeDirect -Exe $llamaServerExe -Args $cpuArgs -WaitSec 15

        if ($diagCpuOk) {
            Write-Log "`n  ⚠ Процесс работает в режиме CPU, но падает с GPU." -Color Yellow
            Write-Log "  → Проблема в CUDA/драйвере/VRAM." -Color Yellow
        } elseif ($diagVerboseOk) {
            Write-Log "`n  ⚠ Процесс работает при прямом запуске, но NSSM не запускает." -Color Yellow
            Write-Log "  → Проблема в конфигурации NSSM." -Color Yellow
        } else {
            Write-Log "`n  ✗ Процесс падает и при прямом запуске. Смотрите STDERR выше." -Color Red
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
            Write-Log "  ✓ Попытка ${i}: /health отвечает status=ok (Router запущен, модели ещё не загружены)" -Color Green
            break
        } else {
            Write-Log "  … Попытка ${i}/${maxAttempts}: /health пока не готов"
        }
    }
    if (-not $apiOk) {
        Write-Log "/health не ответил за $($maxAttempts * 3) секунд." -Color Yellow
        Write-Log "Router запускается без модели, поэтому /health должен отвечать быстро. Проверьте логи:" -Color Yellow
        Write-Log "  Get-Content '$LogsDir\llama-server.err.log' -Tail 30" -Color Yellow
    }

    $actionLabel = if ($isReinstall) { 'переустановка' } elseif ($isUpgrade) { 'обновление/даунгрейд' } else { 'первичная установка' }
    Write-Log "`n=============================" -Color Green
    Write-Log " Развёртывание завершено ($actionLabel, Router mode)" -Color Green
    Write-Log '=============================' -Color Green
    Write-Log " Служба      : $ServiceName"
    Write-Log " Версия      : $(if($currentVersion){$currentVersion} else {'не была установлена'}) -> $(if($targetVersion){$targetVersion} else {'N/A'})"
    Write-Log " Бинарник    : $llamaServerExe"
    Write-Log " ModelsDir   : $ModelsDir"
    Write-Log " Preset      : $(if($selectedModels.Count -gt 0){$presetPath}else{'(не создан)'})"
    Write-Log " Модели      : $(if($selectedModels.Count -gt 0){$selectedModels -join ', '}else{'(не выбраны)'})"
    Write-Log " Логи        : $LogsDir"
    Write-Log " Архивы      : $DownloadsDir\llama_$targetVersion"
    if ($backupPath) { Write-Log " Бэкап       : $backupPath" } else { Write-Log " Бэкапы      : $BackupDir (не требуется)" }
    Write-Log " API локально: http://127.0.0.1:$Port"
    Write-Log " Health-check: http://127.0.0.1:$Port/health"
    Write-Log " Режим       : Router (--models-max 1, автозагрузка моделей включена)"
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
    Write-Log " Запрос      : POST /v1/chat/completions с `"model`": `"$($selectedModels[0])`"" -Color DarkGray
}
catch {
    Write-Log "`nERROR: $_" -Color Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
