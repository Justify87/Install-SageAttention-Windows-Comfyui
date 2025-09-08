#Requires -Version 7.0
<#
.SYNOPSIS
  Triton & SageAttention Installer for ComfyUI (PowerShell 7.x) – no local wheels, auto Torch, README→JSON, and Triton Python dev files.

.DESCRIPTION
  - Preflight (with timeouts): Python/CP tag, Torch, CUDA (nvcc/nvidia-smi), GPU.
  - Torch auto-install: if Torch is missing → install automatically (prefer CUDA; CPU fallback).
  - Optional Torch-first (force via -TorchVersion/-CudaTag).
  - SageAttention 2.2 (SageAttention2++) & 2.1.1 directly from wildminder/AI-windows-whl (README parsing → JSON).
  - CUDA minor fallback: 12.9→12.8.
  - ABI3 fallback (cp39-abi3) optional.
  - Triton prerequisite for Python 3.13: auto-download and place only "include" and "libs" into python_embeded (never touch "Lib").
  - Clean, readable console output by default; detailed timings only with -DebugLog / -TraceScript.
  - Retries (pip/web), transcript logging, post-install checks.
  - Saves the extracted README table structure as JSON in the script folder.

.NOTES
  Run from the ComfyUI portable root folder (contains: .\ComfyUI, .\python_embeded, .\update …).
#>

[CmdletBinding()]
param(
  # --- Debugging & Timeouts ---
  [switch] $DebugLog,
  [switch] $TraceScript,
  [int] $CommandTimeoutSec = 30,
  [int] $PipTimeoutSec = 1800,
  [int] $WebTimeoutSec = 300,

  # --- Execution control ---
  [switch] $DryRun,
  [switch] $SkipUninstall,

  # --- Torch-first parameters (optional force) ---
  [string] $TorchVersion,  # e.g., 2.8.0
  [string] $CudaTag,       # e.g., cu129 or cu128

  # --- Packages / Indexes ---
  [string] $TritonConstraint = "triton-windows<3.4",
  [string] $PipIndexUrl = "https://pypi.org/simple",
  [string] $PipExtraIndexUrl,          # e.g., https://download.pytorch.org/whl/cu129
  [switch] $NoCache,

  # --- Create runners ---
  [switch] $CreatePsRunner,
  [switch] $CreateBatRunner = $true,

  # --- Auto-Fetch from wildminder/AI-windows-whl ---
  [switch] $AutoFetchFromAIWheels,

  # --- Optional extras ---
  [switch] $InstallFlashAttention,
  [switch] $InstallNATTEN,
  [switch] $InstallXFormers,
  [switch] $InstallBitsAndBytes,

  # --- Triton Python dev headers/libs (for Python 3.13 portable) ---
  [string] $TritonPyDevZipUrl = "https://github.com/woct0rdho/triton-windows/releases/download/v3.0.0-windows.post1/python_3.13.2_include_libs.zip",
  [switch] $SkipTritonPyDev,
  [switch] $ForceTritonPyDev
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
try { $host.UI.RawUI.WindowTitle = "Triton & SageAttention Installer (PowerShell 7)" } catch {}

# --------------------- Output style (modern, readable) ------------------------

function Write-Section([string] $Text) { Write-Host ""; Write-Host ("▶ {0}" -f $Text) -ForegroundColor Cyan }
function Write-Info([string] $Text)    { Write-Host ("  • {0}" -f $Text) -ForegroundColor Gray }
function Write-Ok([string] $Text)      { Write-Host ("  ✓ {0}" -f $Text) -ForegroundColor Green }
function Write-Warn([string] $Text)    { Write-Host ("  ! {0}" -f $Text) -ForegroundColor Yellow }
function Write-Err([string] $Text)     { Write-Host ("  ✖ {0}" -f $Text) -ForegroundColor Red }

# Optional timing (only with -DebugLog / -TraceScript)
function Now { (Get-Date).ToString("HH:mm:ss.fff") }
$global:__step_sw = $null
function Step-Begin([string]$Name) {
  if (-not $DebugLog) { return }
  $global:__step_sw = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Host ("[{0}] >> {1}" -f (Now), $Name) -ForegroundColor DarkCyan
}
function Step-End([string]$Name) {
  if (-not $DebugLog) { return }
  if ($global:__step_sw) { $global:__step_sw.Stop() }
  $ms = if ($global:__step_sw) { $global:__step_sw.ElapsedMilliseconds } else { 0 }
  Write-Host ("[{0}] << {1} ({2} ms)" -f (Now), $Name, $ms) -ForegroundColor DarkCyan
}
function Heartbeat([string]$Msg) {
  if ($DebugLog) { Write-Host ("[{0}] ♥ {1}" -f (Now), $Msg) -ForegroundColor DarkGray }
}

if ($TraceScript) {
  Write-Host "TRACE: Set-PSDebug -Trace 1 enabled (very verbose!)" -ForegroundColor Magenta
  Set-PSDebug -Trace 1
}

# --------------------- Exec with timeout & capture ----------------------------

function Join-Args([string[]]$argList) {
  ( @($argList) | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"','`"') + '"' } else { $_ }
  } ) -join ' '
}

function Resolve-ExecutablePath([string]$PathOrName) {
  if ([string]::IsNullOrWhiteSpace($PathOrName)) { return $PathOrName }
  if (Test-Path -LiteralPath $PathOrName -PathType Leaf) {
    return (Resolve-Path -LiteralPath $PathOrName).Path
  }
  return $PathOrName
}

function Exec-Capture {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter()][string[]] $ArgumentList = @(),
    [int] $TimeoutSec = 60,
    [string] $Tag = ""
  )
  $exe = Resolve-ExecutablePath $FilePath
  $displayArgs = Join-Args $ArgumentList

  if ($DryRun) {
    Write-Info ("DRY-RUN: {0} {1}" -f $exe, $displayArgs)
    return [pscustomobject]@{ ExitCode=0; StdOut=""; StdErr="" }
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = (Get-Location).Path
  $psi.ArgumentList.Clear()
  foreach ($a in @($ArgumentList)) { [void]$psi.ArgumentList.Add($a) }

  if ($DebugLog) { Step-Begin ("Exec: {0} {1} {2}" -f $exe, $displayArgs, $Tag) }

  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      throw ("Command timed out after {0}s: {1} {2}" -f $TimeoutSec, $exe, $displayArgs)
    }
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    if ($DebugLog) {
      if ($out) { Write-Host ("[StdOut] {0}" -f $out.TrimEnd()) -ForegroundColor DarkGray }
      if ($err) { Write-Host ("[StdErr] {0}" -f $err.TrimEnd()) -ForegroundColor DarkYellow }
    }
    if ($p.ExitCode -ne 0) {
      throw ("ExitCode={0} Cmd=""{1}"" Args=""{2}""" -f $p.ExitCode, $exe, $displayArgs)
    }
    return [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$out; StdErr=$err }
  }
  finally {
    if ($DebugLog) { Step-End ("Exec: {0} {1} {2}" -f $exe, $displayArgs, $Tag) }
    $p.Dispose()
  }
}

# --------------------- Retry wrapper -----------------------------------------

function Invoke-WithRetry {
  param([Parameter(Mandatory)][scriptblock] $Script, [int] $MaxRetries = 3)
  $delay = 2
  for ($i=1; $i -le $MaxRetries; $i++) {
    try { & $Script; return }
    catch {
      Write-Warn ("Attempt {0}/{1} failed: {2}" -f $i, $MaxRetries, $_.Exception.Message)
      if ($i -eq $MaxRetries) { throw }
      Start-Sleep -Seconds $delay
      $delay = [Math]::Min(15, [int][math]::Ceiling($delay * 2))
    }
  }
}

# --------------------- PIP & Python Helpers ----------------------------------

$Global:PyExeRel = ".\python_embeded\python.exe"
function Get-PyExe() {
  if (-not (Test-Path $Global:PyExeRel)) { throw "python_embeded\python.exe not found. Please run from the ComfyUI root folder." }
  (Resolve-Path -LiteralPath $Global:PyExeRel).Path
}

function Pip {
  param([string[]] $pipArgs)
  $py = Get-PyExe
  if (-not $pipArgs -or $pipArgs.Count -eq 0) { throw "Pip: missing command (install/uninstall/...)" }

  $cmd = $pipArgs[0]
  $finalArgs = @('-m','pip') + @($pipArgs)

  if ($cmd -in @('install','download','wheel')) {
    if ($PipIndexUrl)      { $finalArgs += @('--index-url', $PipIndexUrl) }
    if ($PipExtraIndexUrl) { $finalArgs += @('--extra-index-url', $PipExtraIndexUrl) }
    if ($NoCache)          { $finalArgs += '--no-cache-dir' }
    $finalArgs += @('--upgrade-strategy','only-if-needed')
  }
  Invoke-WithRetry { Exec-Capture -FilePath $py -ArgumentList $finalArgs -TimeoutSec $PipTimeoutSec -Tag "pip" | Out-Null }
}

function Pip-FreezeToFile([string]$Path) {
  $py = Get-PyExe
  if ($DryRun) { if ($DebugLog) { Write-Info ("DRY-RUN: python -m pip freeze > {0}" -f $Path) }; return }
  $res = Exec-Capture -FilePath $py -ArgumentList @('-m','pip','freeze') -TimeoutSec $CommandTimeoutSec -Tag "pip-freeze"
  $res.StdOut | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Py-Run([string]$Code, [int]$TimeoutSec = $CommandTimeoutSec, [string]$Tag = "py") {
  $py = Get-PyExe
  Exec-Capture -FilePath $py -ArgumentList @('-c', $Code) -TimeoutSec $TimeoutSec -Tag $Tag
}

# --------------------- Preflight / Info --------------------------------------

function Get-PythonInfo {
  $code = @'
import sys, platform
v = sys.version_info
print("PY", platform.python_version(), f"cp{v.major}{v.minor}")
'@
  $res = Py-Run $code -TimeoutSec $CommandTimeoutSec -Tag "py-info"
  $parts = ($res.StdOut -split '\s+')
  [pscustomobject]@{
    Version = $parts[1]
    CpTag   = $parts[2]
    Path    = (Resolve-Path ".\python_embeded\python.exe").Path
  }
}

function Get-TorchInfo {
  $code = @'
try:
  import torch, json
  print(json.dumps({"ok":True,"ver":torch.__version__,"cuda":getattr(torch.version,"cuda",None),"avail":torch.cuda.is_available()}))
except Exception:
  print("{""ok"":false}")
'@
  try {
    $res = Py-Run $code -TimeoutSec $CommandTimeoutSec -Tag "torch-info"
    if (-not $res.StdOut) { return $null }
    $obj = $res.StdOut | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $obj.ok) { return $null }
    return [pscustomobject]@{ Version=$obj.ver; Cuda=$obj.cuda; CudaOk=[bool]$obj.avail }
  } catch { return $null }
}

function Get-NvccVersion {
  try {
    $res = Exec-Capture -FilePath "nvcc" -ArgumentList @("--version") -TimeoutSec $CommandTimeoutSec -Tag "nvcc"
    if (-not $res.StdOut) { return $null }
    return ($res.StdOut -split "`n")[-1].Trim()
  } catch { return $null }
}
function Get-NvidiaSmi {
  try {
    $res = Exec-Capture -FilePath "nvidia-smi" -ArgumentList @("--query-gpu=name,driver_version","--format=csv,noheader") -TimeoutSec $CommandTimeoutSec -Tag "nvidia-smi"
    return $res.StdOut
  } catch { return $null }
}

# --------------------- Utilities ---------------------------------------------

function Ensure-Dirs {
  if (-not (Test-Path '.\ComfyUI\main.py')) { throw "ComfyUI\main.py not found. Please run from the ComfyUI root folder." }
  if (-not (Test-Path $Global:PyExeRel)) { throw "python_embeded\python.exe not found. Portable build required." }
  if (-not (Test-Path '.\logs')) {
    if ($DryRun) { if ($DebugLog) { Write-Info "DRY-RUN: mkdir .\logs" } }
    else { New-Item -ItemType Directory -Path '.\logs' -Force | Out-Null }
  }
}
function Start-TranscriptSafe {
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $global:TranscriptPath = ".\logs\Install-SageAttention-$stamp.log"
  if (-not $DryRun) { Start-Transcript -Path $TranscriptPath -Force | Out-Null }
}
function Stop-TranscriptSafe { try { if (-not $DryRun) { Stop-Transcript | Out-Null } } catch {} }

function Convert-CuToCuda([string]$CuTag) {
  if ($CuTag -match '^cu(\d+)$') {
    $d = $Matches[1]
    if ($d.Length -ge 2) {
      $major = $d.Substring(0, $d.Length - 1)
      $minor = $d.Substring($d.Length - 1)
      return ("{0}.{1}" -f $major, $minor)   # e.g., 129 -> 12.9, 118 -> 11.8
    } else {
      throw ("Invalid CUDA tag (too short): {0}" -f $CuTag)
    }
  } elseif ($CuTag -match '^\d+\.\d+$') {
    return $CuTag
  } else {
    throw ("Invalid CUDA tag: {0}" -f $CuTag)
  }
}

# --------------------- Triton Python dev (include/libs) ----------------------

function Download-File {
  param([Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $OutFile)
  if ($DryRun) { if ($DebugLog) { Write-Info "DRY-RUN: download $Url -> $OutFile" } ; return }
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $WebTimeoutSec
}

function Ensure-TritonPythonDev {
  param(
    [Parameter(Mandatory)][string] $PythonVersion,  # e.g., "3.13.2"
    [Parameter(Mandatory)][string] $PythonHome,     # e.g., ".\python_embeded" full path
    [Parameter(Mandatory)][string] $ZipUrl,
    [switch] $Force
  )

  $includePath = Join-Path $PythonHome 'include'
  $libsPath    = Join-Path $PythonHome 'libs'

  $haveHeaders = Test-Path (Join-Path $includePath 'Python.h')
  $haveLibs    = (Test-Path $libsPath) -and ((Get-ChildItem -LiteralPath $libsPath -Filter '*.lib' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

  if ($haveHeaders -and $haveLibs -and -not $Force) {
    Write-Ok "Triton prerequisite: Python headers & libs already present."
    return
  }

  if (-not $Force) {
    if ($PythonVersion -notmatch '^3\.13(\.|$)') {
      Write-Info "Triton prerequisite: skipping (only needed for Python 3.13). Use -ForceTritonPyDev to override."
      return
    }
  }

  $tmpTag = [Guid]::NewGuid().ToString('N')
  $tmpZip = Join-Path $env:TEMP "pydev_${tmpTag}.zip"
  $tmpDir = Join-Path $env:TEMP "pydev_${tmpTag}"

  Write-Info "Fetching Python headers & libs for Triton …"
  if ($DryRun) { Write-Info "DRY-RUN: would download/extract headers & libs." }
  else {
    Download-File -Url $ZipUrl -OutFile $tmpZip
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    foreach ($name in @('include','libs')) {
      $src = Join-Path $tmpDir $name
      if (-not (Test-Path $src)) { throw "Expected folder '$name' not found inside the ZIP." }
      $dst = Join-Path $PythonHome $name
      if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
      Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    }
  }

  if (-not $DryRun) {
    $hdrOk = Test-Path (Join-Path $includePath 'Python.h')
    $libOk = (Get-ChildItem -LiteralPath $libsPath -Filter '*.lib' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
    if (-not ($hdrOk -and $libOk)) { throw "Headers/libs installation incomplete: 'Python.h' or .lib files not found." }
  }
  Write-Ok "Triton prerequisite: installed include/ and libs/ into python_embeded (never touched 'Lib')."

  if (-not $DryRun) {
    try { if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue } } catch {}
    try { if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
  }
}

# --------------------- Install / Uninstall -----------------------------------

function Install-Triton {
  Write-Section ("Triton")
  Write-Info ("Constraint: {0}" -f $TritonConstraint)
  if (-not $SkipUninstall) {
    Write-Info "Removing previous Triton (if any) …"
    Pip @('uninstall','-y','triton-windows')
  } else { Write-Info "Skipping uninstall (per flag)" }
  Write-Info "Installing Triton …"
  Pip @('install','-U',$TritonConstraint)
  Write-Ok "Triton ready."
}

function Uninstall-Torch {
  Write-Section "Torch"
  if (-not $SkipUninstall) {
    Write-Info "Removing torch/torchvision/torchaudio …"
    Pip @('uninstall','-y','torch','torchvision','torchaudio')
  } else { Write-Info "Skipping uninstall (Torch stack)" }
}

function Install-TorchExact([string] $Version, [string] $Cuda) {
  if (-not $Version) { throw "Torch version is missing." }
  if (-not $Cuda)    { throw "CUDA tag is missing (e.g., cu129 or cu128)." }
  $cudaTag = if ($Cuda -match '^cu\d{3}$') { $Cuda } elseif ($Cuda -match '^\d+\.\d+$') { "cu$($Cuda -replace '\.')" } else { throw ("Invalid CUDA tag: {0}" -f $Cuda) }
  $extra = "https://download.pytorch.org/whl/$cudaTag"
  Write-Section ("Torch (forced)")
  Write-Info ("Installing torch=={0} ({1}) …" -f $Version, $cudaTag)
  Pip @('install',"torch==$Version",'torchvision','torchaudio','--extra-index-url', $extra)
  Write-Ok "Torch installed (forced)."
}

function Uninstall-Sage  {
  Write-Section "SageAttention"
  if (-not $SkipUninstall) { Write-Info "Removing existing SageAttention …"; Pip @('uninstall','-y','sageattention') }
  else { Write-Info "Skipping uninstall (SageAttention)" }
}

function Install-WheelFromUrl([string] $Url) {
  # Silent installer (caller prints friendly info)
  Pip @('install', $Url)
}

# --- Torch Auto-Install -------------------------------------------------------

function Test-HasGPU { return [bool](Get-NvidiaSmi) }

function Install-TorchAuto([string] $PreferredCudaTag) {
  Write-Section "Torch"
  Write-Info "Torch not found – installing automatically …"

  $hasGpu = Test-HasGPU
  $candidates = New-Object System.Collections.Generic.List[string]

  if ($PreferredCudaTag) { [void]$candidates.Add($PreferredCudaTag) }
  if ($hasGpu) {
    foreach ($tag in @('cu129','cu128','cu126','cu124','cu121','cu118')) {
      if (-not $candidates.Contains($tag)) { [void]$candidates.Add($tag) }
    }
  }
  if (-not $candidates.Contains('cpu')) { [void]$candidates.Add('cpu') }

  $savedExtra = $script:PipExtraIndexUrl
  try {
    foreach ($cand in $candidates) {
      try {
        if ($cand -eq 'cpu') {
          if ($DebugLog) { Write-Info "[TorchAuto] Trying CPU build …" }
          $script:PipExtraIndexUrl = $null
          Pip @('install','torch','torchvision','torchaudio')
        } else {
          if ($DebugLog) { Write-Info ("[TorchAuto] Trying {0} …" -f $cand) }
          $script:PipExtraIndexUrl = "https://download.pytorch.org/whl/$cand"
          Pip @('install','torch','torchvision','torchaudio')
        }
        Write-Ok ("Torch installation succeeded ({0})." -f $cand)
        return $cand
      } catch {
        Write-Warn ("[TorchAuto] Failed for {0}: {1}" -f $cand, $_.Exception.Message)
      }
    }
    throw "Could not install Torch (CUDA or CPU)."
  }
  finally {
    $script:PipExtraIndexUrl = $savedExtra
  }
}

# --------------------- README → JSON (parse all tables with headers) ----------

function Get-AIWindowsWhlReadme {
  $url = "https://raw.githubusercontent.com/wildminder/AI-windows-whl/main/README.md"
  if ($DryRun) { if ($DebugLog) { Write-Info ("DRY-RUN: GET {0}" -f $url) }; return "" }
  if ($DebugLog) { Step-Begin "Download README.md (AI-windows-whl)" }
  try {
    (Invoke-WebRequest -Uri $url -TimeoutSec $WebTimeoutSec).Content
  } finally {
    if ($DebugLog) { Step-End "Download README.md (AI-windows-whl)" }
  }
}

function Normalize-HeaderCell([string]$s) {
  if ($null -eq $s) { return "" }
  $t = $s.Trim()
  $t = $t.Trim('|')
  $t = $t -replace '^\*+','' -replace '\*+$',''
  $t = $t -replace '^`+','' -replace '`+$',''
  $t
}

function Split-PipeRow([string]$row) {
  $parts = @()
  $acc = ""
  $chars = $row.ToCharArray()
  for ($i=0; $i -lt $chars.Length; $i++) {
    $ch = $chars[$i]
    if ($ch -eq '|') { $parts += ,$acc; $acc = "" }
    else { $acc += $ch }
  }
  $parts += ,$acc
  ($parts | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
}

function Try-ParsePipeTable([string[]]$lines) {
  if ($null -eq $lines -or $lines.Length -lt 2) { return $null }
  $header = Split-PipeRow $lines[0]
  if ($header.Length -lt 2) { return $null }
  $startIdx = 1
  if ($lines.Length -ge 2 -and ($lines[1] -replace '\s','') -match '^\|?:?-{3,}') { $startIdx = 2 }
  $hdr = @(); foreach ($h in $header) { $hdr += ,(Normalize-HeaderCell $h) }
  if ($hdr.Length -lt 2) { return $null }

  $rows = @()
  for ($i=$startIdx; $i -lt $lines.Length; $i++) {
    $ln = $lines[$i]
    if (-not ($ln.TrimStart().StartsWith('|'))) { break }
    if (($ln -replace '\s','') -match '^\|?:?-{3,}') { continue }
    $cells = Split-PipeRow $ln
    if ($cells.Length -lt $hdr.Length) {
      $pad = @(); for ($k=$cells.Length; $k -lt $hdr.Length; $k++) { $pad += ,'' }
      $cells = @($cells + $pad)
    }
    if ($cells.Length -gt $hdr.Length) { $cells = $cells[0..($hdr.Length-1)] }
    $obj = [ordered]@{}
    for ($c=0; $c -lt $hdr.Length; $c++) { $obj[$hdr[$c]] = $cells[$c] }
    $rows += ,[pscustomobject]$obj
  }
  if ($rows.Length -eq 0) { return $null }
  [pscustomobject]@{ header = $hdr; rows = $rows }
}

function Parse-Readme-ToTablesJson {
  param([Parameter(Mandatory)][string] $Markdown)

  $lines = $Markdown -split "\r?\n"
  $tables = New-Object System.Collections.Generic.List[object]
  $currentSection = $null
  $currentSub = $null
  $buffer = @()
  $collecting = $false
  $indexByKey = @{}

  function Flush-Buffer {
    param([string]$section, [string]$subsection)
    if (-not $collecting) { return }
    $collect = @($buffer); $buffer = @(); $script:collecting = $false

    $chunks = @(); $cur = @()
    foreach ($ln in $collect) {
      if ($ln.Trim().StartsWith('|')) { $cur += ,$ln }
      else { if ($cur.Length -ge 2) { $chunks += ,@($cur); $cur = @() } }
    }
    if ($cur.Length -ge 2) { $chunks += ,@($cur) }

    $idx = if ($indexByKey.ContainsKey("$section|$subsection")) { $indexByKey["$section|$subsection"] } else { 0 }
    foreach ($ch in $chunks) {
      $parsed = Try-ParsePipeTable -lines $ch
      if ($parsed -ne $null) {
        $tables.Add([pscustomobject]@{
          section    = $section
          subsection = $subsection
          index      = $idx
          header     = $parsed.header
          rows       = $parsed.rows
        }) | Out-Null
        $idx++
      }
    }
    $indexByKey["$section|$subsection"] = $idx
  }

  foreach ($ln in $lines) {
    if ($ln -match '^\s*###\s+(.+)$') {
      Flush-Buffer -section $currentSection -subsection $currentSub
      $currentSection = $Matches[1].Trim(); $currentSub = $null; $collecting = $false; $buffer = @(); continue
    }
    if ($ln -match '^\s*####\s+(.+)$') {
      Flush-Buffer -section $currentSection -subsection $currentSub
      $currentSub = $Matches[1].Trim(); $collecting = $false; $buffer = @(); continue
    }
    $isPipe = $ln.TrimStart().StartsWith('|')
    if ($isPipe) { $collecting = $true; $buffer += ,$ln; continue }
    else { if ($collecting) { Flush-Buffer -section $currentSection -subsection $currentSub; $buffer = @(); $collecting = $false } }
  }
  Flush-Buffer -section $currentSection -subsection $currentSub

  $obj = [ordered]@{ tables = @($tables.ToArray()) }
  $json = ($obj | ConvertTo-Json -Depth 8)
  return $json, $obj
}

function Save-JsonToScriptDir([string]$JsonText, [string]$FileName = "aiwheels_tables.json") {
  $dest = Join-Path (Get-Location) $FileName
  if (-not $DryRun) { Set-Content -LiteralPath $dest -Value $JsonText -Encoding UTF8 }
  if ($DebugLog) { Write-Ok ("Saved README→JSON: {0}" -f $dest) }
  return $dest
}

# --------------------- Link selection (incl. SageAttention 2.2) --------------

function Extract-LinkUrl([string] $Cell) {
  if (-not $Cell) { return $null }
  $m = [regex]::Match($Cell, '\((https?://[^\)]+)\)')
  if ($m.Success) { return $m.Groups[1].Value }
  if ($Cell -match '^https?://') { return $Cell }
  return $null
}

function Find-ColumnName([string[]] $Names, [string[]] $Patterns) {
  foreach ($pat in $Patterns) {
    $m = $Names | Where-Object { $_ -match $pat } | Select-Object -First 1
    if ($m) { return $m }
  }
  return $null
}

function Get-Cell($row, [string]$name) {
  if (-not $row) { return $null }
  $p = $row.PSObject.Properties[$name]
  if ($p) { return [string]$p.Value }
  return $null
}

function Resolve-SageAttentionUrl-FromJson {
  param(
    [Parameter(Mandatory)] $JsonObj,
    [Parameter(Mandatory)][string] $TorchVer,
    [Parameter(Mandatory)][string] $CudaTag,
    [Parameter(Mandatory)][string] $PythonMM,
    [switch] $AllowAbi3Fallback
  )

  $CudaPretty = Convert-CuToCuda $CudaTag
  $tables = @($JsonObj.tables)
  if (-not $tables -or $tables.Count -eq 0) { throw "JSON has no 'tables' – README may not have loaded/parsed." }

  $sa22 = @($tables | Where-Object {
    $_.section -match '^\s*SageAttention\s*$' -and
    ($_.subsection -match 'SageAttention\s*2\.2' -or $_.subsection -match 'SageAttention2\+\+')
  })
  if ($sa22.Count -eq 0) {
    $sa22 = @($tables | Where-Object { $_.section -match '^\s*SageAttention\s*$' -and $_.subsection -eq $null -and $_.index -ge 1 })
  }
  $saAll = @($tables | Where-Object { $_.section -match '^\s*SageAttention\s*$' })

  function Try-Select {
    param([object[]]$tableSet, [string]$cudaWanted, [switch]$allowPyMissing)
    foreach ($tbl in @($tableSet)) {
      $headers = @($tbl.header)
      $torchCol = Find-ColumnName $headers @('(?i)pytorch','(?i)\btorch\b')
      $pyCol    = Find-ColumnName $headers @('(?i)^python','(?i)python\s*ver','(?i)^py\b')
      $cudaCol  = Find-ColumnName $headers @('(?i)^cuda','(?i)compute','(?i)cu\d')
      $linkCol  = Find-ColumnName $headers @('(?i)download','(?i)link','(?i)href','(?i)wheel','(?i)\.whl')
      if (-not $linkCol) { continue }
      foreach ($r in @($tbl.rows)) {
        $tv = if ($torchCol){ Get-Cell $r $torchCol } else { $null }
        $pv = if ($pyCol)  { Get-Cell $r $pyCol } else { $null }
        $cv = if ($cudaCol){ Get-Cell $r $cudaCol } else { $null }

        $torchMM = ($TorchVer -split '\.')[0..1] -join '\.'
        $okTorch = (-not $torchCol) -or ($tv -and ($tv -match ("^" + [regex]::Escape($TorchVer) + "(\b|$)") -or $tv -match ("^" + $torchMM)))
        $okCuda  = (-not $cudaCol) -or ($cv -and ($cv -match [regex]::Escape($cudaWanted)))
        $okPy    = $allowPyMissing -or (-not $pyCol) -or ($pv -and ($pv -match [regex]::Escape($PythonMM)))

        if ($okTorch -and $okCuda -and $okPy) {
          $linkCell = Get-Cell $r $linkCol
          $url = Extract-LinkUrl $linkCell
          if ($url) { return $url }
        }
      }
    }
    return $null
  }

  $url = $null
  if (-not $url) { $url = Try-Select -tableSet $sa22 -cudaWanted $CudaPretty }
  if (-not $url -and $CudaPretty -eq '12.9') { $url = Try-Select -tableSet $sa22 -cudaWanted '12.8' }
  if (-not $url) { $url = Try-Select -tableSet $saAll -cudaWanted $CudaPretty }
  if (-not $url -and $CudaPretty -eq '12.9') { $url = Try-Select -tableSet $saAll -cudaWanted '12.8' }

  if (-not $url -and $AllowAbi3Fallback) {
    if (-not $url) { $url = Try-Select -tableSet $sa22 -cudaWanted $CudaPretty -allowPyMissing }
    if (-not $url -and $CudaPretty -eq '12.9') { $url = Try-Select -tableSet $sa22 -cudaWanted '12.8' -allowPyMissing }
    if (-not $url) { $url = Try-Select -tableSet $saAll -cudaWanted $CudaPretty -allowPyMissing }
    if (-not $url -and $CudaPretty -eq '12.9') { $url = Try-Select -tableSet $saAll -cudaWanted '12.8' -allowPyMissing }
  }
  return $url
}

function Install-AIWheel-Resolved {
  param(
    [Parameter(Mandatory)][string] $Package,      # "SageAttention" / "Flash Attention" / …
    [Parameter(Mandatory)][string] $TorchVer,
    [Parameter(Mandatory)][string] $CudaTag,
    [Parameter(Mandatory)][string] $PythonMM,
    [switch] $SageAttentionV22Only,
    [switch] $AllowAbi3Fallback
  )

  Write-Section ("{0}" -f $Package)
  Write-Info ("Selecting a compatible wheel (Torch {0}, CUDA {1}, Python {2}) …" -f $TorchVer, $CudaTag, $PythonMM)

  $readme = Get-AIWindowsWhlReadme
  $jsonText, $jsonObj = Parse-Readme-ToTablesJson -Markdown $readme
  Save-JsonToScriptDir -JsonText $jsonText | Out-Null

  $url = $null
  if ($Package -match '^(?i)sageattention$' -and $SageAttentionV22Only) {
    $url = Resolve-SageAttentionUrl-FromJson -JsonObj $jsonObj -TorchVer $TorchVer -CudaTag $CudaTag -PythonMM $PythonMM -AllowAbi3Fallback:$AllowAbi3Fallback
  } else {
    $tables = @($jsonObj.tables | Where-Object { $_.section -match [regex]::Escape($Package) })
    $CudaPretty = Convert-CuToCuda $CudaTag
    foreach ($tbl in $tables) {
      $headers = @($tbl.header)
      $torchCol = Find-ColumnName $headers @('(?i)pytorch','(?i)\btorch\b')
      $pyCol    = Find-ColumnName $headers @('(?i)^python','(?i)python\s*ver','(?i)^py\b')
      $cudaCol  = Find-ColumnName $headers @('(?i)^cuda','(?i)compute','(?i)cu\d')
      $linkCol  = Find-ColumnName $headers @('(?i)download','(?i)link','(?i)href','(?i)wheel','(?i)\.whl')
      if (-not $linkCol) { continue }
      foreach ($r in @($tbl.rows)) {
        $tv = if ($torchCol){ Get-Cell $r $torchCol } else { $null }
        $pv = if ($pyCol)  { Get-Cell $r $pyCol } else { $null }
        $cv = if ($cudaCol){ Get-Cell $r $cudaCol } else { $null }

        $okTorch = (-not $torchCol) -or ($tv -and ($tv -match [regex]::Escape($TorchVer) -or $tv -match ([regex]::Escape(($TorchVer -split '\.')[0..1] -join '\.'))))
        $okPy    = (-not $pyCol)    -or ($pv -and ($pv -match [regex]::Escape($PythonMM)))
        $okCuda  = (-not $cudaCol)  -or ($cv -and ($cv -match [regex]::Escape($CudaPretty) -or ($CudaPretty -eq '12.9' -and $cv -match '12\.8')))

        if ($okTorch -and $okPy -and $okCuda) {
          $linkCell = Get-Cell $r $linkCol
          $cand = Extract-LinkUrl $linkCell
          if ($cand) { $url = $cand; break }
        }
      }
      if ($url) { break }
    }
  }

  if (-not $url) {
    throw ("No matching wheel (even with CUDA-minor/abi3 fallback) for {0}{1} (Torch {2}, CUDA {3}, Python {4})." -f $Package, ($(if($SageAttentionV22Only){" 2.2"}else{""})), $TorchVer, $CudaTag, $PythonMM)
  }

  $wheelName = Split-Path -Leaf $url
  Write-Ok ("Wheel selected: {0}" -f $wheelName)
  if ($DebugLog) { Write-Info ("Source: {0}" -f $url) }

  Write-Info ("Installing {0} …" -f $Package)
  Install-WheelFromUrl -Url $url
  Write-Ok ("{0} installed." -f $Package)
}

# --------------------- Post-Install ------------------------------------------

function PostInstall-Checks {
  Write-Section "Verify"
  $code = @'
import importlib, json, torch
mods = ["torch","sageattention"]
out = {}
for m in mods:
  try:
    mod = importlib.import_module(m)
    out[m] = {"ok": True, "ver": getattr(mod,"__version__","")}
  except Exception as e:
    out[m] = {"ok": False, "err": str(e)}
out["cuda"] = {"ver": getattr(torch.version,"cuda",None), "is_available": torch.cuda.is_available()}
print(json.dumps(out))
'@
  if ($DryRun) { Write-Info "DRY-RUN: skipping import checks."; return }
  $res = Py-Run $code -TimeoutSec $CommandTimeoutSec -Tag "post-check"
  if ($res.ExitCode -ne 0) { throw "Post-install check failed." }
  $obj = $null
  try { $obj = $res.StdOut | ConvertFrom-Json } catch {}
  if ($null -ne $obj) {
    if ($obj.torch.ok) { Write-Ok ("torch import OK ({0})" -f $obj.torch.ver) } else { Write-Err ("torch import failed: {0}" -f $obj.torch.err) }
    if ($obj.sageattention.ok) { Write-Ok ("sageattention import OK ({0})" -f $obj.sageattention.ver) } else { Write-Err ("sageattention import failed: {0}" -f $obj.sageattention.err) }
    $cudaVer = if ($obj.cuda.ver) { $obj.cuda.ver } else { "n/a" }
    Write-Info ("CUDA runtime: {0}, available: {1}" -f $cudaVer, $obj.cuda.is_available)
  } else {
    if ($DebugLog) { Write-Info "Could not parse verification JSON — raw:"; Write-Host $res.StdOut -ForegroundColor DarkGray }
  }
}

# --------------------- Main Flow ---------------------------------------------

try {
  Start-TranscriptSafe

  Write-Section "Preflight"
  Ensure-Dirs

  $pyInfo    = Get-PythonInfo
  $torchInfo = Get-TorchInfo
  $nvcc      = Get-NvccVersion
  $smi       = Get-NvidiaSmi
  $gpuLine   = if ($smi) { ($smi -split "\r?\n")[0] } else { $null }

  Write-Ok  ("Python: {0}  ({1})" -f $pyInfo.Version, $pyInfo.CpTag)
  if ($torchInfo) {
    Write-Ok ("Torch: {0} (CUDA {1}, available={2})" -f $torchInfo.Version, ($torchInfo.Cuda ?? 'n/a'), $torchInfo.CudaOk)
  } else {
    Write-Warn "Torch: not installed"
  }
  if ($nvcc)  { Write-Info ("CUDA Toolkit (nvcc) (optional): detected") } else { Write-Warn "CUDA Toolkit (nvcc) (optional): not found" }
  if ($gpuLine) { Write-Info ("GPU/Driver: {0}" -f $gpuLine) } else { Write-Warn "NVIDIA driver/GPU not detected" }

  # Triton prerequisite: Python dev headers/libs (only include/libs, never Lib)
  if (-not $SkipTritonPyDev) {
    Write-Section "Triton prerequisites"
    $pyHome = (Split-Path -Parent (Get-PyExe))
    Ensure-TritonPythonDev -PythonVersion $pyInfo.Version -PythonHome $pyHome -ZipUrl $TritonPyDevZipUrl -Force:$ForceTritonPyDev
  } else {
    Write-Info "Skipping Triton Python dev step (per flag)."
  }

  if (-not $DryRun) {
    Pip-FreezeToFile ".\logs\requirements.before.txt"
    if ($DebugLog) { Write-Info "Saved environment snapshot (before)." }
  }

  Write-Section "Install plan"
  # 1) If Torch version explicitly provided → install that (and ensure Triton).
  if ($TorchVersion -and $CudaTag) {
    Install-Triton
    Uninstall-Torch
    Install-TorchExact -Version $TorchVersion -Cuda $CudaTag
    $torchInfo = Get-TorchInfo
    if (-not $torchInfo) { throw "Forced Torch installation failed." }
  }

  # 2) If Torch still missing → automatic installation (CUDA preferred, CPU fallback)
  if (-not $torchInfo) {
    $chosen = Install-TorchAuto -PreferredCudaTag $CudaTag
    $torchInfo = Get-TorchInfo
    if (-not $torchInfo) { throw "Automatic Torch installation failed." }
  } else {
    Install-Triton
  }

  # 3) Determine effective Torch/CUDA (for SageAttention)
  $effTorch = ($torchInfo.Version -replace '\+.*$','') # e.g., "2.8.0"
  if ($CudaTag) {
    $effCuda = $CudaTag
  } elseif ($torchInfo.Version -match '\+cu(\d{3})') {
    $effCuda = "cu$($Matches[1])"
  } elseif ($torchInfo.Cuda -match '^\d+\.\d+$') {
    $effCuda = "cu$($torchInfo.Cuda -replace '\.')"
  } else {
    throw "Installed Torch build is CPU-only. SageAttention requires a CUDA build (e.g., cu128)."
  }

  # 4) Install SageAttention 2.2 (via README→JSON, with 12.9→12.8 & optional ABI3)
  Uninstall-Sage
  $pyMM = ($pyInfo.Version -split '\.')[0..1] -join '.'
  Install-AIWheel-Resolved -Package 'SageAttention' -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM -SageAttentionV22Only -AllowAbi3Fallback

  # 5) Optional extras (from the same README)
  if ($AutoFetchFromAIWheels) {
    if ($InstallFlashAttention) { Install-AIWheel-Resolved -Package 'Flash Attention' -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallNATTEN)         { Install-AIWheel-Resolved -Package 'NATTEN'           -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallXFormers)       { Install-AIWheel-Resolved -Package 'xformers'         -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallBitsAndBytes)   { Install-AIWheel-Resolved -Package 'bitsandbytes'     -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
  }

  # Runners
  if ($CreateBatRunner) {
    Write-Section "Run shortcuts"
    $bat = "@echo off`r`n.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --use-sage-attention`r`npause`r`n"
    if ($DryRun) { Write-Info "DRY-RUN: write run_nvidia_gpu_sageattention.bat" }
    else { Set-Content -LiteralPath ".\run_nvidia_gpu_sageattention.bat" -Value $bat -Encoding ASCII }
    Write-Ok "Created: .\run_nvidia_gpu_sageattention.bat"
  }
  if ($CreatePsRunner) {
    $ps = @'
#Requires -Version 7.0
$ErrorActionPreference = "Stop"
& ".\python_embeded\python.exe" -s "ComfyUI\main.py" --windows-standalone-build --use-sage-attention
'@
    if ($DryRun) { Write-Info "DRY-RUN: write Run-ComfyUI-Sage.ps1" }
    else { Set-Content -LiteralPath ".\Run-ComfyUI-Sage.ps1" -Value $ps -Encoding UTF8 }
    Write-Ok "Created: .\Run-ComfyUI-Sage.ps1"
  }

  # Post-Install & Snapshot
  PostInstall-Checks
  if (-not $DryRun) {
    Pip-FreezeToFile ".\logs\requirements.after.txt"
    if ($DebugLog) { Write-Info "Saved environment snapshot (after)." }
  }

  Write-Section "Done"
  Write-Ok "Installation finished."
  Write-Info "Start ComfyUI with SageAttention:"
  if ($CreatePsRunner)  { Write-Host "    .\Run-ComfyUI-Sage.ps1" -ForegroundColor White }
  if ($CreateBatRunner) { Write-Host "    .\run_nvidia_gpu_sageattention.bat" -ForegroundColor White }
  Write-Host "    or: python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --use-sage-attention" -ForegroundColor White
}
catch {
  Write-Err ("ERROR: {0}" -f $_.Exception.Message)
  throw
}
finally {
  Stop-TranscriptSafe
  if ($TraceScript) { Set-PSDebug -Off }
}
