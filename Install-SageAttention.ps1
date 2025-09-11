#Requires -Version 7.0
<#
.SYNOPSIS
  Triton & SageAttention Installer for ComfyUI (PowerShell 7.x) – uses wheels.json (no scraping), auto Torch, JSON-based resolver, and Triton Python dev files.

.DESCRIPTION
  - Preflight (with timeouts): Python/CP tag, Torch, CUDA (nvcc/nvidia-smi), GPU.
  - Torch auto-install: if Torch is missing → install automatically (prefer CUDA; CPU fallback).
  - Optional Torch-first (force via -TorchVersion/-CudaTag).
  - SageAttention 2.2 (SageAttention2++) & 2.1.1 via wildminder/AI-windows-whl (from wheels.json only).
  - CUDA minor fallback: 12.9→12.8.
  - ABI3 fallback optional (py3/abi3).
  - Triton prerequisite for Python 3.13: auto-download and place only "include" and "libs" into python_embeded (never touch "Lib").
  - Clean, readable console output by default; detailed timings only with -DebugLog / -TraceScript.
  - Retries (pip/web), transcript logging, post-install checks.
  - Saves fetched wheels.json to disk (skipped in DryRun).

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

  # --- Auto-Fetch from AI-windows-whl (JSON index only) ---
  [switch] $AutoFetchFromAIWheels,

  # --- Optional extras ---
  [switch] $InstallFlashAttention,
  [switch] $InstallNATTEN,
  [switch] $InstallXFormers,
  [switch] $InstallBitsAndBytes,

  # --- Triton Python dev headers/libs (for Python 3.13 portable) ---
  [string] $TritonPyDevZipUrl = "https://github.com/woct0rdho/triton-windows/releases/download/v3.0.0-windows.post1/python_3.13.2_include_libs.zip",
  [switch] $SkipTritonPyDev,
  [switch] $ForceTritonPyDev,

  # --- wheels.json endpoint ---
  [string] $WheelsJsonUrl = "https://raw.githubusercontent.com/wildminder/AI-windows-whl/refs/heads/main/wheels.json",
  [string] $WheelsJsonOut = ".\aiwheels_index.json"
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
    [string] $Tag = "",
    [switch] $AllowInDryRun  # erlaubt echte Ausführung im DryRun (z.B. Python-Imports)
  )
  $exe = Resolve-ExecutablePath $FilePath
  $displayArgs = Join-Args $ArgumentList

  if ($DryRun -and -not $AllowInDryRun) {
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
  Exec-Capture -FilePath $py -ArgumentList @('-c', $Code) -TimeoutSec $TimeoutSec -Tag $Tag -AllowInDryRun
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
    $res = Exec-Capture -FilePath "nvidia-smi" `
      -ArgumentList @("--query-gpu=name,driver_version","--format=csv,noheader") `
      -TimeoutSec $CommandTimeoutSec -Tag "nvidia-smi" -AllowInDryRun
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

# --------------------- wheels.json fetching & resolver ------------------------

function Save-Text([string]$Path, [string]$Text) {
  if ($DryRun) { if ($DebugLog) { Write-Info ("DRY-RUN: save {0}" -f $Path) } ; return }
  Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function Get-WheelsIndex {
  Write-Section "Fetch wheels.json"
  Write-Info ("URL: {0}" -f $WheelsJsonUrl)

  $raw = (Invoke-WebRequest -Uri $WheelsJsonUrl -TimeoutSec $WebTimeoutSec).Content
  if (-not $raw) { throw "wheels.json download returned empty content." }

  if ($DryRun) {
    Write-Info "DRY-RUN: skipping save of wheels.json"
  } else {
    Save-Text -Path $WheelsJsonOut -Text $raw
    Write-Ok ("Saved wheels.json → {0}" -f $WheelsJsonOut)
  }

  try {
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $obj.packages) { throw "JSON has no 'packages' array." }
    return $obj
  } catch {
    throw "Failed to parse wheels.json: $($_.Exception.Message)"
  }
}

function Normalize-Name([string]$s) {
  if ($null -eq $s) { return "" }
  ($s -replace '[\s_\-]','' -replace '\+','plus').ToLowerInvariant()
}

function Get-Prop($obj, [string[]]$names) {
  foreach ($n in $names) {
    $p = $obj.PSObject.Properties[$n]
    if ($p) { return $p.Value }
  }
  return $null
}

function Version-MM([string]$ver) {
  if ([string]::IsNullOrWhiteSpace($ver)) { return $null }
  $m = [regex]::Match($ver, '^\s*(\d+)\.(\d+)')
  if ($m.Success) { return ("{0}.{1}" -f $m.Groups[1].Value, $m.Groups[2].Value) }
  return $null
}

function Python-Match($wheelPy, [string]$wantMM, [switch]$AllowAbi3) {
  if (-not $wheelPy) { return $true } # permissive if absent
  $s = [string]$wheelPy

  # exact like "3.12"
  if ($s -match '^\s*\d+\.\d+\s*$') { return ($s -eq $wantMM) }

  # ranges like ">=3.9", ">3.9", "3.9+"
  if ($s -match '>=\s*(\d+\.\d+)') { return ([version]$wantMM -ge [version]$Matches[1]) }
  if ($s -match '>\s*(\d+\.\d+)')  { return ([version]$wantMM -gt [version]$Matches[1]) }
  if ($s -match '(\d+\.\d+)\s*\+') { return ([version]$wantMM -ge [version]$Matches[1]) }

  # generic markers
  if ($s -match '(?i)\babi3\b' -or $s -match '(?i)\bpy3\b' -or $s -match '(?i)\bcp39\+?\b') {
    return [bool]$AllowAbi3
  }
  return $false
}

function Torch-Match($wheelTorch, [string]$wantFull) {
  if (-not $wheelTorch) { return $true } # permissive if absent
  $mmWant = Version-MM $wantFull
  $mmHave = Version-MM ([string]$wheelTorch)
  if ($wheelTorch -eq $wantFull) { return $true }
  if ($mmHave -and $mmWant -and ($mmHave -eq $mmWant)) { return $true }
  return $false
}

function Cuda-Match([string]$wheelCuda, [string]$wantPretty) {
  if (-not $wheelCuda) { return $true } # permissive if absent
  $s = ($wheelCuda -replace '[^\d\.]','').Trim()
  if ($s -eq $wantPretty) { return $true }
  return $false
}

function Resolve-AIWheelsUrl {
  param(
    [Parameter(Mandatory)] $IndexObj,
    [Parameter(Mandatory)][string] $PackageName,    # e.g., "SageAttention", "Flash Attention"
    [Parameter(Mandatory)][string] $TorchVer,       # e.g., 2.8.0
    [Parameter(Mandatory)][string] $CudaTag,        # e.g., cu128
    [Parameter(Mandatory)][string] $PythonMM,       # e.g., 3.12
    [switch] $SageAttentionV22Only,
    [switch] $AllowAbi3Fallback
  )

  $wantCudaPretty = Convert-CuToCuda $CudaTag
  $normWant = Normalize-Name $PackageName

  # Find package(s)
  $pkgs = @()
  foreach ($p in @($IndexObj.packages)) {
    $pname = [string](Get-Prop $p @('name','title','id','slug'))
    if (-not $pname) { continue }
    $normHave = Normalize-Name $pname
    if ($normHave -eq $normWant) { $pkgs += ,$p; continue }
    if ($normHave -match [regex]::Escape($normWant) -or $normWant -match [regex]::Escape($normHave)) { $pkgs += ,$p }
  }
  if ($pkgs.Count -eq 0) { throw "Package '$PackageName' not found in wheels.json." }

  # Collect all candidate wheels
  $cands = @()
  foreach ($pkg in $pkgs) {
    foreach ($w in @($pkg.wheels)) {
      # optional filter: SageAttention 2.2 only
      if ($SageAttentionV22Only) {
        $pv = [string](Get-Prop $w @('package_version','version','pkg_version'))
        $note = [string](Get-Prop $w @('variant','note','notes'))
        $pvOk = ($pv -match '^\s*2\.2') -or ($note -match '2\.2') -or ($note -match 'SageAttention2')
        if (-not $pvOk) { continue }
      }

      $wTorch  = [string](Get-Prop $w @('torch','pytorch','pytorch_version','torch_version'))
      $wPy     = [string](Get-Prop $w @('python','python_version','py'))
      $wCuda   = [string](Get-Prop $w @('cuda','cuda_version','cu'))
      $wUrl    = [string](Get-Prop $w @('url','href','download'))
      $wCxxAbi = [string](Get-Prop $w @('cxx11abi','abi','abi3'))

      if (-not $wUrl) { continue }

      $okTorch = Torch-Match $wTorch $TorchVer
      $okPy    = Python-Match $wPy $PythonMM -AllowAbi3:$AllowAbi3Fallback
      $okCuda  = Cuda-Match $wCuda $wantCudaPretty

      if ($okTorch -and $okPy -and $okCuda) {
        $score = 0
        if ($wTorch -eq $TorchVer) { $score += 3 } elseif (Version-MM $wTorch -eq Version-MM $TorchVer) { $score += 2 }
        if ($wCuda -match [regex]::Escape($wantCudaPretty)) { $score += 2 }
        if ($wPy -match [regex]::Escape($PythonMM)) { $score += 1 }
        if ($wCxxAbi -match '(?i)TRUE') { $score += 1 }
        $cands += ,([pscustomobject]@{ url=$wUrl; score=$score; torch=$wTorch; py=$wPy; cuda=$wCuda })
      }
    }
  }

  if ($cands.Count -eq 0 -and $wantCudaPretty -eq '12.9') {
    # CUDA minor fallback: try 12.8
    return Resolve-AIWheelsUrl -IndexObj $IndexObj -PackageName $PackageName -TorchVer $TorchVer -CudaTag 'cu128' -PythonMM $PythonMM -SageAttentionV22Only:$SageAttentionV22Only -AllowAbi3Fallback:$AllowAbi3Fallback
  }

  if ($cands.Count -eq 0 -and $AllowAbi3Fallback -eq $false) {
    # Retry with ABI3 fallback enabled
    return Resolve-AIWheelsUrl -IndexObj $IndexObj -PackageName $PackageName -TorchVer $TorchVer -CudaTag $CudaTag -PythonMM $PythonMM -SageAttentionV22Only:$SageAttentionV22Only -AllowAbi3Fallback
  }

  if ($cands.Count -eq 0) {
    throw "No matching wheel for $PackageName (Torch $TorchVer, CUDA $CudaTag, Python $PythonMM)."
  }

  $best = $cands | Sort-Object -Property score -Descending | Select-Object -First 1
  return $best.url
}

function Install-AIWheel-FromIndex {
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

  $index = Get-WheelsIndex
  $url = Resolve-AIWheelsUrl -IndexObj $index -PackageName $Package -TorchVer $TorchVer -CudaTag $CudaTag -PythonMM $PythonMM -SageAttentionV22Only:$SageAttentionV22Only -AllowAbi3Fallback:$AllowAbi3Fallback

  $wheelName = Split-Path -Leaf $url
  Write-Ok ("Wheel selected: {0}" -f $wheelName)
  if ($DebugLog) { Write-Info ("Source: {0}" -f $url) }

  Write-Info ("Installing {0} …" -f $Package)
  Pip @('install', $url)
  Write-Ok ("{0} installed." -f $Package)
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

# --------------------- Torch Auto --------------------------------------------

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

  # 4) Install SageAttention 2.2 (via wheels.json, with 12.9→12.8 & optional ABI3)
  Uninstall-Sage
  $pyMM = ($pyInfo.Version -split '\.')[0..1] -join '.'
  Install-AIWheel-FromIndex -Package 'SageAttention' -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM -SageAttentionV22Only -AllowAbi3Fallback

  # 5) Optional extras (from the same wheels.json)
  if ($AutoFetchFromAIWheels) {
    if ($InstallFlashAttention) { Install-AIWheel-FromIndex -Package 'Flash Attention' -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallNATTEN)         { Install-AIWheel-FromIndex -Package 'NATTEN'           -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallXFormers)       { Install-AIWheel-FromIndex -Package 'xformers'         -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
    if ($InstallBitsAndBytes)   { Install-AIWheel-FromIndex -Package 'bitsandbytes'     -TorchVer $effTorch -CudaTag $effCuda -PythonMM $pyMM }
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
