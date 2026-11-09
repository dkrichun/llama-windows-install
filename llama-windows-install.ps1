#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание и обновление llama.cpp в режиме Router как службы Windows.
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
    if ($global:LogFile) { Add-Content -Path $global:LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue }
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
    $data = @{}; $section = ''
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
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) { $val = $val.Substring(1, $val.Length - 2) }
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
$CacheDir         = Get-Cfg     'paths'     'CacheDir'           ''
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
$Port             = Get-CfgInt  'network'   'Port'               9931
$FirewallEnabled  = Get-CfgBool 'network'   'FirewallEnabled'    $true
$FirewallSubnet   = Get-Cfg     'network'   'FirewallSubnet'     '192.168.117.0/24'
$LlamaCppVersion  = Get-Cfg     'downloads' 'LlamaCppVersion'    'ask'
$NssmUrl          = Get-Cfg     'downloads' 'NssmUrl'            'https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip'
$KeepDownloads    = Get-CfgBool 'downloads' 'KeepDownloads'      $true

$CtxSize          = Get-CfgInt  'server'    'CtxSize'            4096
$NGpuLayers       = Get-CfgInt  'server'    'NGpuLayers'         999
$FlashAttention   = Get-CfgBool 'server'    'FlashAttention'     $true
$Parallel         = Get-CfgInt  'server'    'Parallel'           1
$ExtraArgs        = Get-Cfg     'server'    'ExtraArgs'          ''
$ForceCPU         = Get-CfgBool 'server'    'ForceCPU'           $false

$InteractiveModels = Get-CfgBool 'models'   'Interactive'        $true
$ModelsSpec        = Get-Cfg     'models'   'Models'             ''
$PreDownload       = Get-CfgBool 'models'   'PreDownload'        $true

if ($Upgrade) {
    Write-Log "  [Upgrade] Автообновление: выбор версии отключён, будет установлена latest." -Color Magenta
    $Force = $true; $LlamaCppVersion = 'latest'; $InteractiveModels = $false
}

# Нормализация путей
if ([string]::IsNullOrWhiteSpace($ModelsDir)) { $ModelsDir = Join-Path $LlamaCppDir 'Models' } elseif (-not [IO.Path]::IsPathRooted($ModelsDir)) { $ModelsDir = Join-Path $LlamaCppDir $ModelsDir }
if ([string]::IsNullOrWhiteSpace($CacheDir)) { $CacheDir = Join-Path $LlamaCppDir 'Cache' } elseif (-not [IO.Path]::IsPathRooted($CacheDir)) { $CacheDir = Join-Path $LlamaCppDir $CacheDir }
if ([string]::IsNullOrWhiteSpace($LogsDir)) { $LogsDir = Join-Path $LlamaCppDir 'logs' } elseif (-not [IO.Path]::IsPathRooted($LogsDir)) { $LogsDir = Join-Path $LlamaCppDir $LogsDir }
if ([string]::IsNullOrWhiteSpace($DownloadsDir)) { $DownloadsDir = Join-Path $LlamaCppDir 'Downloads' } elseif (-not [IO.Path]::IsPathRooted($DownloadsDir)) { $DownloadsDir = Join-Path $LlamaCppDir $DownloadsDir }
if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = Join-Path $LlamaCppDir 'Backup' } elseif (-not [IO.Path]::IsPathRooted($BackupDir)) { $BackupDir = Join-Path $LlamaCppDir $BackupDir }

$ModelsDir    = [IO.Path]::GetFullPath($ModelsDir)
$CacheDir     = [IO.Path]::GetFullPath($CacheDir)
$LogsDir      = [IO.Path]::GetFullPath($LogsDir)
$DownloadsDir = [IO.Path]::GetFullPath($DownloadsDir)
$BackupDir    = [IO.Path]::GetFullPath($BackupDir)
$InstallPath  = [IO.Path]::GetFullPath($scriptDir)
$ApiKeysTxt   = [IO.Path]::GetFullPath((Join-Path $LlamaCppDir 'api-keys.txt'))
$ApiKeysJson  = [IO.Path]::GetFullPath((Join-Path $LlamaCppDir 'api-keys.json'))
$VersionFile  = [IO.Path]::GetFullPath((Join-Path $LlamaCppDir '.installed_version'))

# Защищённые пути (не бэкапятся и не удаляются при обновлении)
$protectedPaths = @(
    $InstallPath, $LogsDir, $DownloadsDir, $BackupDir, $ModelsDir, $CacheDir, $ApiKeysTxt, $ApiKeysJson, $VersionFile
) | Select-Object -Unique

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── 3. Вспомогательные функции ───
function Stop-LlamaProcesses {
    Write-Log "  → Завершение процессов llama.cpp..."
    foreach ($procName in @("llama-server", "llama-server.exe")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
}

function Set-LlamaAcl {
    param([string]$LlamaCppDir, [string]$ModelsDir, [string]$CacheDir)
    foreach ($dir in @($LlamaCppDir, $ModelsDir, $CacheDir)) {
        if ((Test-Path $dir) -and $dir) {
            icacls $dir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
            icacls $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
        }
    }
}

function Get-FileNameFromUrl {
    param([string]$Url, [string]$Fallback = 'download.bin')
    try { $name = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath); if ($name) { return $name } } catch {}
    return $Fallback
}

function Get-CachedFile {
    param([string]$Url, [string]$FileName, [string]$SubDir = '', [switch]$ForceRedownload)
    $targetDir = if ($SubDir) { Join-Path $DownloadsDir $SubDir } else { $DownloadsDir }
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    $cachePath = Join-Path $targetDir $FileName
    $urlStamp  = "$cachePath.url"

    # Проверяем кэш
    if ($KeepDownloads -and -not $ForceRedownload -and (Test-Path $cachePath) -and (Test-Path $urlStamp)) {
        $cachedUrl = ''
        try { $cachedUrl = (Get-Content $urlStamp -Raw -ErrorAction Stop).Trim() } catch { }
        if ($cachedUrl -eq $Url) {
            $sizeMb = [math]::Round((Get-Item $cachePath).Length / 1MB, 1)
            Write-Log "  ✓ Найдено в кэше: $cachePath ($sizeMb MB) — повторное скачивание не требуется" -Color Green
            return $cachePath
        }
    }

    if (Test-Path $cachePath) { Remove-Item $cachePath -Force }
    if (Test-Path $urlStamp)  { Remove-Item $urlStamp -Force }
    Write-Log "  → Скачивание: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $cachePath -UseBasicParsing
    if ($KeepDownloads) { Set-Content $urlStamp -Value $Url -NoNewline }
    return $cachePath
}

function Add-ToMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if (($parts | ForEach-Object { $_.TrimEnd('\') }) -contains $Dir.TrimEnd('\')) { return }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    Write-Log "  ✓ Добавлено в PATH: $Dir" -Color Green
}

function Add-NssmToMachinePath {
    param([string]$NssmDir)
    if (-not $AddNssmToPath) { return }
    foreach ($sub in @('win32','win64')) {
        $p = Join-Path $NssmDir $sub
        if (Test-Path (Join-Path $p 'nssm.exe')) { Add-ToMachinePath -Dir $p }
    }
}

function Get-LlamaReleases {
    param([switch]$ForceRefresh)
    $cacheFile = Join-Path $DownloadsDir '.llama_releases_cache.json'
    if (-not $ForceRefresh -and (Test-Path $cacheFile)) {
        if (((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds -lt 43200) {
            try { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
    }
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30' -Headers @{'User-Agent'='PS-Script'} -ErrorAction Stop
        if (-not (Test-Path $DownloadsDir)) { New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null }
        $releases | ConvertTo-Json -Depth 5 | Set-Content $cacheFile -Encoding UTF8
        return $releases
    } catch {
        if (Test-Path $cacheFile) { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) }
        return $null
    }
}

function Select-LlamaVersionInteractive {
    param($Releases, [string]$CurrentVersion)
    if (-not $Releases) { return $null }
    $list = @($Releases | Select-Object -First 15)
    if ($list.Count -eq 0) { return $null }
    Write-Log 'Доступные версии llama.cpp:' -Color Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $date = if ($list[$i].published_at) { ([datetime]$list[$i].published_at).ToString('yyyy-MM-dd') } else { '—' }
        $mark = if ($CurrentVersion -and $list[$i].tag_name -eq $CurrentVersion) { ' <-- текущая' } else { '' }
        Write-Log ('  [{0}] {1,-16} {2}  {3}' -f ($i+1), $list[$i].tag_name, $date, $mark) -Color $(if($mark){'Yellow'}else{'White'})
    }
    while ($true) {
        $ans = (Read-Host 'Введите номер версии (Enter — последняя, s — отмена)').Trim()
        if (-not $ans) { return $list[0] }
        if ($ans -match '^[scыс]$') { return 'CANCEL' }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { return $list[$n-1] }
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
        if ($sel.tag_name) { return $sel.tag_name }
        return $null
    }
    $latest = @($releases | Where-Object { $_.tag_name -match '^b\d+$' }) | Select-Object -First 1
    if ($latest) { return $latest.tag_name }
    return $null
}

function Test-LlamaHealth {
    param([string]$Url, [int]$TimeoutSec = 5)
    try { return ((Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec).status -eq 'ok') } catch { return $false }
}

function Test-VCRedist {
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64','HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        if (Test-Path $path) { return $true }
    }
    return $false
}

function Install-VCRedist {
    $outFile = Join-Path $env:TEMP 'vc_redist.x64.exe'
    try {
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $outFile -UseBasicParsing
        $p = Start-Process -FilePath $outFile -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -NoNewWindow
        return ($p.ExitCode -in @(0, 1638, 3010))
    } catch { return $false } finally { if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue } }
}

function Test-CudaCompatibility {
    param([string]$RequiredVersion)
    $smi = $null
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $smi = 'nvidia-smi'
    } else {
        $path = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path $path) { $smi = $path }
    }
    if (-not $smi) {
        Write-Log "  ⚠ nvidia-smi не найден в PATH или System32." -Color Yellow
        return $false
    }

    try {
        $smiOut = & $smi 2>&1 | Out-String -Width 500
    } catch {
        Write-Log "  ⚠ Ошибка запуска nvidia-smi: $_" -Color Yellow
        return $false
    }

    $cudaVerStr = $null
    if ($smiOut -match 'CUDA\s+(?:UMD\s+)?Version:\s*(\d+(?:\.\d+)?)') {
        $cudaVerStr = $matches[1]
    }

    if (-not $cudaVerStr) {
        Write-Log "  ⚠ Не удалось распарсить версию CUDA из вывода nvidia-smi." -Color Yellow
        return $false
    }

    $cudaMajor = [int]$cudaVerStr.Split('.')[0]
    $reqMajor = [int](($RequiredVersion -replace '^cuda-','').Split('.')[0])

    Write-Log "  ℹ Драйвер поддерживает CUDA $cudaVerStr (требуется >= $reqMajor.x)" -Color DarkGray

    if ($cudaMajor -ge $reqMajor) {
        Write-Log "  ✓ Версия CUDA совместима." -Color Green
        return $true
    }
    Write-Log "  ✗ Версия CUDA несовместима! Требуется $reqMajor.x, обнаружена $cudaVerStr" -Color Red
    return $false
}

function Test-LlamaServeDirect {
    param([string]$Exe, [string]$Args, [int]$WaitSec = 15)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = $Args; $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutSb = New-Object System.Text.StringBuilder; $stderrSb = New-Object System.Text.StringBuilder
        $outEvt = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action { if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } } -MessageData $stdoutSb
        $errEvt = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action { if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } } -MessageData $stderrSb
        $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine()
        Start-Sleep -Seconds $WaitSec
        $exited = $proc.HasExited
        Start-Sleep -Milliseconds 500
        Unregister-Event -SourceIdentifier $outEvt.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvt.Name -ErrorAction SilentlyContinue
        if (-not $exited) { try { $proc.Kill() } catch {} } else {
            $err = $stderrSb.ToString()
            if ($err -and $err.Trim()) { Write-Log "    STDERR:" -Color Yellow; $err -split "`n" | Select-Object -First 20 | ForEach-Object { Write-Log "      $_" -Color DarkGray } }
        }
        return ($exited -eq $false)
    } catch { return $false }
}

function Start-LlamaService {
    param([string]$NssmExe, [string]$ServiceName, [int]$TimeoutSec, [int]$MaxAttempts = 3)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Служба не найдена" }
        if ($svc.Status -eq 'Running') { return $true }
        & $NssmExe start $ServiceName 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $svc.Refresh()
            if ($svc.Status -eq 'Running') { return $true }
            if ($svc.Status -eq 'Stopped' -and $sw.Elapsed.TotalSeconds -gt 3) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Select-ModelsInteractive {
    param([string[]]$Preselected)
    if ($null -eq $Preselected) { $Preselected = @() }
    $menu = @(
        [pscustomobject]@{ Name='qwen7b'; HfRepo='bartowski/Qwen2.5-7B-Instruct-GGUF'; HfFile='Qwen2.5-7B-Instruct-Q4_K_M.gguf'; Desc='≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='llama8b'; HfRepo='bartowski/Meta-Llama-3.1-8B-Instruct-GGUF'; HfFile='Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf'; Desc='≈ 4.9 ГБ' }
        [pscustomobject]@{ Name='coder7b'; HfRepo='bartowski/Qwen2.5-Coder-7B-Instruct-GGUF'; HfFile='Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf'; Desc='≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='gemma2b'; HfRepo='bartowski/gemma-2-2b-it-GGUF'; HfFile='gemma-2-2b-it-Q4_K_M.gguf'; Desc='≈ 1.6 ГБ' }
        [pscustomobject]@{ Name='deepseek8b'; HfRepo='bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF'; HfFile='DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf'; Desc='≈ 4.9 ГБ' }
    )
    Write-Log 'Доступные модели:' -Color Cyan
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $mark = if ($Preselected -contains $menu[$i].Name) { '*' } else { ' ' }
        Write-Log ('  [{0}] {1} {2,-10} {3,-45} — {4}' -f ($i+1), $mark, $menu[$i].Name, $menu[$i].HfRepo, $menu[$i].Desc)
    }
    Write-Log "Введите номера через запятую ('a' — все, 'n' — пропустить):" -Color Cyan
    $ans = Read-Host 'Выбор'
    if ([string]::IsNullOrWhiteSpace($ans)) { return @($Preselected) }
    if ($ans -eq 'n') { return @() }
    if ($ans -eq 'a') { return @($menu | ForEach-Object { $_.Name }) }
    $selected = @()
    foreach ($part in ($ans -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $menu.Count) {
            if ($selected -notcontains $menu[$n-1].Name) { $selected += $menu[$n-1].Name }
        }
    }
    return @($selected)
}

function Get-PresetEntry {
    param([string]$Name)
    $menu = @{
        'qwen7b'     = @{ HfRepo='bartowski/Qwen2.5-7B-Instruct-GGUF';            HfFile='Qwen2.5-7B-Instruct-Q4_K_M.gguf' }
        'llama8b'    = @{ HfRepo='bartowski/Meta-Llama-3.1-8B-Instruct-GGUF';    HfFile='Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf' }
        'coder7b'    = @{ HfRepo='bartowski/Qwen2.5-Coder-7B-Instruct-GGUF';     HfFile='Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf' }
        'gemma2b'    = @{ HfRepo='bartowski/gemma-2-2b-it-GGUF';                 HfFile='gemma-2-2b-it-Q4_K_M.gguf' }
        'deepseek8b' = @{ HfRepo='bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF'; HfFile='DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf' }
    }
    return $menu[$Name]
}

function Invoke-ModelDownload {
    param([string]$Url, [string]$Destination, [string]$DisplayName, [switch]$NoProgress)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 0) { return $true }
    $partFile = "$Destination.part"
    $resumeFrom = 0
    if (Test-Path $partFile) { $resumeFrom = (Get-Item $partFile).Length }

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(4)
    $client.DefaultRequestHeaders.Add('User-Agent', 'PowerShell-LlamaCpp')
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        if ($resumeFrom -gt 0) { $request.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue -ArgumentList $resumeFrom, $null }
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $response.EnsureSuccessStatusCode()
        $totalBytes = if ($response.Content.Headers.ContentLength) { [long]$response.Content.Headers.ContentLength } else { 0 }
        if ($resumeFrom -gt 0 -and $totalBytes) { $totalBytes += $resumeFrom }

        $fileMode = if ($resumeFrom -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fileStream = New-Object System.IO.FileStream($partFile, $fileMode, [System.IO.FileAccess]::Write)
        $httpStream = $response.Content.ReadAsStreamAsync().Result
        $buffer = New-Object byte[] 81920
        $totalRead = $resumeFrom
        $lastUpdate = [DateTime]::MinValue

        try {
            while (($read = $httpStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read); $totalRead += $read
                if (-not $NoProgress -and ([DateTime]::Now - $lastUpdate).TotalMilliseconds -ge 200) {
                    $readMb = [math]::Round($totalRead / 1MB, 1)
                    if ($totalBytes -gt 0) {
                        $percent = [int](($totalRead / $totalBytes) * 100)
                        $msg = "  Скачивание {0}: {1} / {2} MB ({3}%)" -f $DisplayName, $readMb, [math]::Round($totalBytes/1MB,1), $percent
                    } else { $msg = "  Скачивание {0}: {1} MB" -f $DisplayName, $readMb }
                    Write-Host ("`r" + $msg + (" " * 10)) -NoNewline
                    $lastUpdate = [DateTime]::Now
                }
            }
        } finally { $fileStream.Close(); $httpStream.Close() }
        if (-not $NoProgress) { Write-Host "" }
        if (Test-Path $Destination) { Remove-Item $Destination -Force }
        Move-Item $partFile $Destination -Force
        Write-Log "  ✓ Скачано: $Destination" -Color Green
        return $true
    } catch {
        if (-not $NoProgress) { Write-Host "" }
        Write-Log "  ✗ Ошибка: $_" -Color Red
        return $false
    } finally { $client.Dispose() }
}

# ─── 4. Основной блок try ───
try {
    $llamaServerExe = Join-Path $LlamaCppDir 'llama-server.exe'
    $currentVersion = $null
    $currentVersionRaw = $null

    # 1. Пытаемся определить версию из бинарника
    if (Test-Path $llamaServerExe) {
        $verOut = ''
        try { $verOut = (& $llamaServerExe --version 2>&1) -join ' ' } catch { }

        # Формат b12184+: "version: 0.9.0-dev (build 12184, commit ...)"
        if ($verOut -match 'build\s+(\d{3,})') {
            $currentVersion = "b$($matches[1])"
            $currentVersionRaw = $verOut.Trim()
        }
        elseif ($verOut -match 'version:\s*b?(\d{3,})\b') {
            $currentVersion = "b$($matches[1])"
            $currentVersionRaw = $verOut.Trim()
        }
        elseif ($verOut -match '\bb(\d{3,})\b') {
            $currentVersion = "b$($matches[1])"
            $currentVersionRaw = $verOut.Trim()
        }
    }

    # 2. Fallback: читаем кэш версии
    if (-not $currentVersion -and (Test-Path $VersionFile)) {
        try {
            $cached = (Get-Content -LiteralPath $VersionFile -Raw -ErrorAction Stop).Trim()
            if ($cached -match '^b\d+') { $currentVersion = $cached }
        } catch { }
    }

    # 3. Выводим результат
    if ($currentVersion) {
        Write-Log "`n  ℹ Установленная версия: $currentVersion" -Color Green
        if ($currentVersionRaw -and $currentVersionRaw -ne $currentVersion) {
            Write-Log "    $currentVersionRaw" -Color DarkGray
        }
    } elseif (Test-Path $llamaServerExe) {
        Write-Log "`n  ℹ Бинарник присутствует, но версию распознать не удалось." -Color DarkGray
        if ($verOut) { Write-Log "    Вывод: $($verOut.Trim())" -Color DarkGray }
    } else {
        Write-Log "`n  ℹ llama.cpp не установлен — будет выполнена первичная установка." -Color Cyan
    }

    Write-Step "Выбор версии llama.cpp"
    $targetVersion = $null
    if ($currentVersion -and -not $forceDL -and -not $Upgrade) {
        $resolvedVersion = Resolve-LlamaVersion -RequestedVersion $LlamaCppVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($resolvedVersion -is [string] -and $resolvedVersion -eq 'CANCEL') { exit 0 }
        if (-not $resolvedVersion) { $resolvedVersion = $currentVersion }
        $targetVersion = $resolvedVersion
    } else {
        $targetVersion = Resolve-LlamaVersion -RequestedVersion $LlamaCppVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($targetVersion -is [string] -and $targetVersion -eq 'CANCEL') { exit 0 }
        if (-not $targetVersion) { $targetVersion = 'b12184' }
    }

    $isReinstall = ($currentVersion -eq $targetVersion)
    
    # Бэкап нужен всегда, если существует бинарник
    $needsBackup = Test-Path $llamaServerExe

    if (-not $Force -and $needsBackup) {
        if ($isReinstall) { 
            if ((Read-Host "Переустановить $currentVersion? [Y/n]") -eq 'n') { exit 0 } 
        }
        if ((Read-Host 'Продолжить? [Y/n]') -eq 'n') { exit 0 }
    }

    $llamaDownloadUrl  = "https://github.com/ggml-org/llama.cpp/releases/download/$targetVersion/llama-$targetVersion-bin-win-cuda-13.5-x64.zip"
    $cudartDownloadUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$targetVersion/cudart-llama-bin-win-cuda-13.5-x64.zip"

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { & sc.exe stop $ServiceName 2>&1 | Out-Null; Start-Sleep -Seconds 2 }
    Stop-LlamaProcesses

    Write-Step "Проверка зависимостей"
    if (-not (Test-VCRedist)) {
        if (-not (Install-VCRedist)) { if ((Read-Host 'Нет VC++ Redist. Продолжить? [y/N]') -ne 'y') { throw 'Отменено' } }
    }
    $useGpu = -not $ForceCPU
    if ($useGpu) {
        $cudaReq = if ($llamaDownloadUrl -match 'cuda-(\d+\.\d+)') { $matches[1] } else { '13.5' }
        if (-not (Test-CudaCompatibility -RequiredVersion $cudaReq)) {
            if ((Read-Host 'CUDA несовместима. Продолжить? [y/N]') -ne 'y') { throw 'Отменено' }
        }
    }

    Write-Step 'Создание каталогов'
    foreach ($d in @($LlamaCppDir, $ModelsDir, $CacheDir, $LogsDir, $NssmDir, $DownloadsDir, $BackupDir) | Select-Object -Unique) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Set-LlamaAcl -LlamaCppDir $LlamaCppDir -ModelsDir $ModelsDir -CacheDir $CacheDir

    Write-Step "Установка NSSM"
    $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $nssmExe -or $forceDL) {
        $nssmVer = if ($NssmUrl -match '/download/([^/]+)/') { $matches[1] -replace '^v', '' } else { 'unknown' }
        $nssmSubDir = "nssm_$nssmVer"
        $nssmZipName = Get-FileNameFromUrl -Url $NssmUrl
        $nssmZip = Get-CachedFile -Url $NssmUrl -FileName $nssmZipName -SubDir $nssmSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $nssmZip -DestinationPath $NssmDir -Force
        $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
    } else {
        Write-Log "  ✓ NSSM уже установлен: $nssmExe" -Color Green
    }
    Add-NssmToMachinePath -NssmDir $NssmDir

    if ($needsBackup) {
        Write-Step "Резервное копирование"
        $backupPath = Join-Path $BackupDir "LlamaCpp_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
        
        $itemsToBackup = Get-ChildItem -Path $LlamaCppDir | Where-Object { $protectedPaths -notcontains [IO.Path]::GetFullPath($_.FullName) }
        if ($itemsToBackup.Count -eq 0) {
            Write-Log "  ℹ Нечего бэкапить (бинарники не найдены или всё защищено)" -Color DarkGray
        } else {
            foreach ($item in $itemsToBackup) {
                Copy-Item -Path $item.FullName -Destination $backupPath -Recurse -Force
                Write-Log "    Сохранён: $($item.Name)" -Color DarkGray
            }
            Write-Log "  ✓ Бэкап создан: $backupPath" -Color Green
        }

        Write-Step "Очистка старых файлов"
        foreach ($item in $itemsToBackup) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "  ✓ Старые файлы удалены (защищённые папки сохранены)" -Color Green
    }

    if ($LogRetentionDays -gt 0 -and (Test-Path $LogsDir)) {
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $LogsDir -File | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Установка llama.cpp"
    if ($needsBackup -or -not (Test-Path $llamaServerExe) -or $forceDL) {
        $llamaZip = Get-CachedFile -Url $llamaDownloadUrl -FileName "llama-$targetVersion-bin-win-cuda-13.5-x64.zip" -SubDir "llama_$targetVersion" -ForceRedownload:$forceDL
        $cudartZip = Get-CachedFile -Url $cudartDownloadUrl -FileName "cudart-llama-bin-win-cuda-13.5-x64.zip" -SubDir "cudart_$targetVersion" -ForceRedownload:$forceDL
        Expand-Archive -Path $llamaZip -DestinationPath $LlamaCppDir -Force
        Expand-Archive -Path $cudartZip -DestinationPath $LlamaCppDir -Force
    } else {
        Write-Log "  ℹ Установка не требуется (используется текущая)" -Color DarkGray
    }

    [Environment]::SetEnvironmentVariable('LLAMA_CPP_DIR', $LlamaCppDir, 'Machine')
    if ($AddToPath) { Add-ToMachinePath -Dir $LlamaCppDir }

    if ($FirewallEnabled -and $FirewallSubnet) {
        Get-NetFirewallRule -DisplayName "LlamaCpp API*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName "LlamaCpp API ($FirewallSubnet)" -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $FirewallSubnet -Action Allow -Profile Any | Out-Null
    }

    # ─── Выбор и скачивание моделей ───
    $selectedModels = @()
    if ($InteractiveModels -and -not $Force) {
        Write-Step 'Выбор моделей'
        $preselected = if ($ModelsSpec) { @($ModelsSpec -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
        $selectedModels = @(Select-ModelsInteractive -Preselected $preselected)
    } else {
        if ($ModelsSpec) { $selectedModels = @($ModelsSpec -split ',' | ForEach-Object { $_.Trim() }) }
    }

    if ($selectedModels.Count -gt 0) {
        $doPreDownload = $PreDownload
        if (-not $Force) { $doPreDownload = ((Read-Host 'Скачать модели сейчас? [Y/n]') -ne 'n') }
        if ($doPreDownload) {
            Write-Step 'Скачивание моделей'
            foreach ($name in $selectedModels) {
                $entry = Get-PresetEntry -Name $name
                $modelUrl = "https://huggingface.co/$($entry.HfRepo)/resolve/main/$($entry.HfFile)"
                $destPath = Join-Path $ModelsDir $entry.HfFile
                Invoke-ModelDownload -Url $modelUrl -Destination $destPath -DisplayName $name | Out-Null
            }
        }
    }

    # ─── Формирование аргументов Router ───
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
        if ($FlashAttention) { $serverArgs += @('-fa', 'on') }
    } else {
        $serverArgs += @('-ngl', '0')
    }
    if ($ExtraArgs) { $serverArgs += ($ExtraArgs -split ' ' | Where-Object { $_ }) }
    $serverArgsLine = $serverArgs -join ' '

    Write-Step "Регистрация службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & $nssmExe stop $ServiceName 2>&1 | Out-Null; Start-Sleep -Seconds 2
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null; Start-Sleep -Seconds 2
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { & sc.exe delete $ServiceName | Out-Null; Start-Sleep -Seconds 2 }
    }

    & $nssmExe install $ServiceName $llamaServerExe $serverArgsLine 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppDirectory $LlamaCppDir 2>&1 | Out-Null
    & $nssmExe set $ServiceName Start $StartType 2>&1 | Out-Null
    & $nssmExe set $ServiceName Description "llama.cpp Router: dynamically loads GGUF models on demand. Max 1 model in memory." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'llama-server.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'llama-server.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500 2>&1 | Out-Null

    Write-Step 'Запуск службы'
    $ok = Start-LlamaService -NssmExe $nssmExe -ServiceName $ServiceName -TimeoutSec $StartTimeoutSec -MaxAttempts 3
    if (-not $ok) {
        Write-Log "`n=== ОШИБКА ЗАПУСКА ===" -Color Red
        Write-Log "  Последние строки лога ошибок:" -Color Yellow
        if (Test-Path (Join-Path $LogsDir 'llama-server.err.log')) {
            Get-Content (Join-Path $LogsDir 'llama-server.err.log') -Tail 20 | ForEach-Object { Write-Log "    $_" -Color DarkGray }
        }
        throw "Служба $ServiceName не запустилась. Проверьте логи."
    }

    Write-Step "Проверка API (порт $Port)"
    $apiOk = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 3
        if (Test-LlamaHealth -Url "http://127.0.0.1:$Port/health") { $apiOk = $true; break }
        Write-Log "  … Ожидание /health ($i/30)"
    }
    if (-not $apiOk) { Write-Log "API не ответил, но служба работает. Проверьте логи." -Color Yellow }

    # Сохраняем установленную версию в кэш
    if ($targetVersion) {
        try { Set-Content -LiteralPath $VersionFile -Value $targetVersion -NoNewline -Encoding UTF8 } catch { }
    }

    Write-Log "`n=============================" -Color Green
    Write-Log " Развёртывание завершено (Router mode)" -Color Green
    Write-Log '=============================' -Color Green
    Write-Log " Служба      : $ServiceName"
    Write-Log " Версия была : $(if($currentVersion){$currentVersion}else{'(не установлена)'})"
    Write-Log " Версия стала: $(if($targetVersion){$targetVersion}else{'(не определена)'})" -Color Green
    Write-Log " Бинарник    : $llamaServerExe"
    Write-Log " Модели в    : $ModelsDir"
    Write-Log " API         : http://127.0.0.1:$Port"
    Write-Log " Health-check: http://127.0.0.1:$Port/health"
    if ($selectedModels.Count -gt 0) {
        Write-Log " Пример      : `"model`": `"$((Get-PresetEntry -Name $selectedModels[0]).HfFile)`"" -Color DarkGray
    }
}
catch {
    Write-Log "`nERROR: $_" -Color Red
}
if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }