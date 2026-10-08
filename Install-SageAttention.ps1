#Requires -Version 7.0
<#
.SYNOPSIS
  Installs a compatible Triton + SageAttention stack into ComfyUI Windows Portable.

.DESCRIPTION
  New-generation installer. It treats the bundled PyTorch stack as read-only:
  Detect -> Resolve -> Plan -> Backup -> Stage -> Execute -> Verify -> Recover on failure.
#>

[CmdletBinding()]
param(
  [switch] $DryRun,
  [switch] $CreateRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$Root = $PSScriptRoot
$Py = Join-Path $Root 'python_embeded\python.exe'
$ComfyMain = Join-Path $Root 'ComfyUI\main.py'
$ComfySageIndex = 'https://comfy-org.github.io/wheels/sageattention/'
$CommunityIndex = 'https://raw.githubusercontent.com/wildminder/AI-windows-whl/refs/heads/main/wheels.json'
$PyDevReleaseApi = 'https://api.github.com/repos/woct0rdho/triton-windows/releases/tags/v3.0.0-windows.post1'
$script:TranscriptStarted = $false
$script:MutationStarted = $false
$script:BackupDir = $null

function Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }
function Warn([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Invoke-Proc {
  param([Parameter(Mandatory)][string]$File, [string[]]$Args = @(), [int]$TimeoutSec = 900)
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $File
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($a in $Args) { [void]$psi.ArgumentList.Add($a) }
  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill($true) } catch {}
      throw "Command timed out: $File $($Args -join ' ')"
    }
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    if ($p.ExitCode -ne 0) {
      throw "Command failed ($($p.ExitCode)): $File $($Args -join ' ')`n$err"
    }
    [pscustomobject]@{ Out = $out.Trim(); Err = $err.Trim(); ExitCode = $p.ExitCode }
  }
  finally { $p.Dispose() }
}

function Py([string]$Code, [int]$TimeoutSec = 120) {
  (Invoke-Proc -File $Py -Args @('-c', $Code) -TimeoutSec $TimeoutSec).Out
}

function Get-BaseVersion([string]$Value) {
  if ($Value -match '(\d+)\.(\d+)(?:\.(\d+))?') {
    $patch = if ($Matches[3]) { $Matches[3] } else { '0' }
    return [version]"$($Matches[1]).$($Matches[2]).$patch"
  }
  throw "Cannot parse version '$Value'."
}

function Test-Range([string]$Current, $Range) {
  if ($null -eq $Range) { return $true }
  $r = @($Range)
  if ($r.Count -eq 0) { return $true }
  $cur = Get-BaseVersion $Current
  $min = if ($r[0]) { Get-BaseVersion ([string]$r[0]) } else { $null }
  $max = if ($r.Count -gt 1 -and $r[1]) { Get-BaseVersion ([string]$r[1]) } else { $null }
  if ($min -and $cur -lt $min) { return $false }
  if ($max -and $cur -gt $max) { return $false }
  return $true
}

function Get-TritonMinor([string]$TorchVersion) {
  $v = Get-BaseVersion $TorchVersion
  $key = "$($v.Major).$($v.Minor)"
  $map = @{
    '2.4'='3.1'; '2.5'='3.1'; '2.6'='3.2'; '2.7'='3.3'; '2.8'='3.4'
    '2.9'='3.5'; '2.10'='3.6'; '2.11'='3.6'; '2.12'='3.7'; '2.13'='3.7'; '2.14'='3.8'
  }
  if (-not $map.ContainsKey($key)) {
    throw "PyTorch $key is not in the current triton-windows compatibility matrix."
  }
  $map[$key]
}

function Get-EnvironmentInfo {
  $code = @'
import json, sys, site, importlib.metadata as m
try:
    import torch
except Exception as e:
    print(json.dumps({"error": f"PyTorch import failed: {e}"}))
    raise SystemExit
def dist(name):
    try: return m.version(name)
    except m.PackageNotFoundError: return None
gpu = None
cc = None
if torch.cuda.is_available():
    gpu = torch.cuda.get_device_name(0)
    cc = ".".join(map(str, torch.cuda.get_device_capability(0)))
print(json.dumps({
    "error": None,
    "python": ".".join(map(str, sys.version_info[:3])),
    "python_mm": ".".join(map(str, sys.version_info[:2])),
    "cp": f"cp{sys.version_info.major}{sys.version_info.minor}",
    "torch": torch.__version__,
    "cuda": torch.version.cuda,
    "cuda_ok": torch.cuda.is_available(),
    "gpu": gpu,
    "cc": cc,
    "site_packages": site.getsitepackages()[0],
    "triton_windows": dist("triton-windows"),
    "legacy_triton": dist("triton"),
    "sageattention": dist("sageattention")
}))
'@
  $obj = (Py $code) | ConvertFrom-Json
  if ($obj.error) { throw $obj.error }
  $obj
}

function Assert-PortableRoot {
  if (-not $IsWindows) { throw 'This installer supports Windows only.' }
  if (-not (Test-Path -LiteralPath $Py -PathType Leaf)) { throw 'python_embeded\python.exe was not found.' }
  if (-not (Test-Path -LiteralPath $ComfyMain -PathType Leaf)) { throw 'ComfyUI\main.py was not found.' }
  $vcLocal = Join-Path (Split-Path $Py -Parent) 'vcruntime140.dll'
  $vcSystem = Join-Path $env:SystemRoot 'System32\vcruntime140.dll'
  if (-not (Test-Path $vcLocal) -and -not (Test-Path $vcSystem)) {
    throw 'Microsoft Visual C++ 2015-2022 Redistributable (x64) was not detected.'
  }
  try {
    $running = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
      Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq [IO.Path]::GetFullPath($Py)) }
  }
  catch { throw "Could not safely check running processes: $($_.Exception.Message)" }
  if ($running) { throw 'ComfyUI embedded Python is currently running. Close ComfyUI and try again.' }
}

function Assert-Hardware([object]$EnvInfo) {
  if (-not $EnvInfo.cuda_ok -or -not $EnvInfo.cuda) { throw 'The bundled PyTorch has no usable NVIDIA CUDA runtime.' }
  $supported = @('8.0','8.6','8.9','9.0','10.0','12.0','12.1')
  if ($EnvInfo.cc -notin $supported) {
    throw "GPU compute capability $($EnvInfo.cc) is not supported by current SageAttention 2.x upstream kernels."
  }
}

function Test-PythonWheelTag([string]$FileName, [string]$PythonMM) {
  $digits = $PythonMM -replace '\.',''
  if ($FileName -match '-cp(\d+)-cp\1-win_amd64\.whl$') { return ($Matches[1] -eq $digits) }
  if ($FileName -match '-cp(\d+)-abi3-win_amd64\.whl$') {
    return ([int]$digits -ge [int]$Matches[1])
  }
  return $false
}

function Get-WheelVersion([string]$FileName) {
  if ($FileName -match '(?i)^sageattention-(.+?)-cp\d+') { return $Matches[1] }
  return $null
}

function Resolve-OfficialSage([object]$EnvInfo) {
  $torch = Get-BaseVersion $EnvInfo.torch
  $torchTag = "$($torch.Major)$($torch.Minor)"
  $cuTag = 'cu' + ($EnvInfo.cuda -replace '\.','')
  $headers = @{ 'User-Agent'='ComfyUI-SageAttention-Installer' }
  $html = (Invoke-WebRequest -Uri $ComfySageIndex -Headers $headers -TimeoutSec 30).Content
  $urls = foreach ($m in [regex]::Matches($html, 'href=["''](?<u>[^"'']+\.whl[^"'']*)["'']', 'IgnoreCase')) {
    $href = [System.Net.WebUtility]::HtmlDecode($m.Groups['u'].Value)
    ([uri]::new([uri]$ComfySageIndex, $href)).AbsoluteUri
  }
  $matches = foreach ($url in $urls) {
    $name = [uri]::UnescapeDataString((Split-Path ([uri]$url).AbsolutePath -Leaf))
    if ($name -notmatch '(?i)^sageattention-') { continue }
    if ($name -notmatch [regex]::Escape("+${cuTag}torch${torchTag}")) { continue }
    if (-not (Test-PythonWheelTag $name $EnvInfo.python_mm)) { continue }
    [pscustomobject]@{ Url=$url; Name=$name; Version=(Get-WheelVersion $name); Source='Comfy-Org/wheels' }
  }
  @($matches | Sort-Object Name -Descending)[0]
}

function Get-VersionRank([string]$Value) {
  if ($Value -match '^(\d+)\.(\d+)\.(\d+)(?:\.post(\d+))?') {
    return ([long]$Matches[1]*1000000000L)+([long]$Matches[2]*1000000L)+([long]$Matches[3]*1000L)+([long]($Matches[4] ?? 0))
  }
  return 0L
}

function Resolve-CommunitySage([object]$EnvInfo) {
  $headers = @{ 'User-Agent'='ComfyUI-SageAttention-Installer' }
  $index = (Invoke-WebRequest -Uri $CommunityIndex -Headers $headers -TimeoutSec 30).Content | ConvertFrom-Json
  $pkg = @($index.packages | Where-Object {
    (($_.id -replace '[^a-zA-Z]','').ToLowerInvariant() -eq 'sageattention') -or
    (($_.name -replace '[^a-zA-Z]','').ToLowerInvariant() -eq 'sageattention')
  })[0]
  if (-not $pkg) { return $null }

  $matches = foreach ($w in @($pkg.wheels)) {
    if (-not $w.url -or $w.url -notmatch '(?i)win_amd64\.whl') { continue }
    if ($w.package_version -notmatch '^2\.2') { continue }
    if (-not (Test-Range $EnvInfo.torch $w.torch_version)) { continue }
    if (-not (Test-Range $EnvInfo.python_mm $w.python_version)) { continue }
    if (-not (Test-Range $EnvInfo.cuda $w.cuda_version)) { continue }
    $name = [uri]::UnescapeDataString((Split-Path ([uri]$w.url).AbsolutePath -Leaf))
    if (-not (Test-PythonWheelTag $name $EnvInfo.python_mm)) { continue }
    [pscustomobject]@{
      Url=[string]$w.url; Name=$name; Version=(Get-WheelVersion $name)
      PackageVersion=[string]$w.package_version; Source='wildminder/AI-windows-whl'
      Rank=(Get-VersionRank ([string]$w.package_version))
    }
  }
  @($matches | Sort-Object Rank,Name -Descending)[0]
}

function Resolve-Sage([object]$EnvInfo) {
  $wheel = Resolve-OfficialSage $EnvInfo
  if ($wheel) { return $wheel }
  Warn 'No exact Comfy-Org SageAttention wheel matches this environment; checking community fallback.'
  Resolve-CommunitySage $EnvInfo
}

function Resolve-PyDevAsset([string]$PythonMM) {
  $release = Invoke-RestMethod -Uri $PyDevReleaseApi -Headers @{ 'User-Agent'='ComfyUI-SageAttention-Installer' } -TimeoutSec 30
  $escaped = [regex]::Escape($PythonMM)
  $asset = @($release.assets | Where-Object { $_.name -match "^python_${escaped}\.\d+_include_libs\.zip$" })[0]
  if (-not $asset) { return $null }
  [pscustomobject]@{ Name=$asset.name; Url=$asset.browser_download_url }
}

function Normalize-PackageVersion([string]$Value) {
  if (-not $Value) { return '' }
  ($Value.ToLowerInvariant() -replace '[-_]','.')
}

function New-Plan([object]$EnvInfo, [object]$SageWheel, [string]$TritonMinor, [object]$PyDevAsset) {
  $tritonAction = if ($EnvInfo.triton_windows -and $EnvInfo.triton_windows -match "^$([regex]::Escape($TritonMinor))(\.|$)") { 'KEEP' } else { 'INSTALL' }
  $sageAction = if ($EnvInfo.sageattention -and $SageWheel.Version -and
    ((Normalize-PackageVersion $EnvInfo.sageattention) -eq (Normalize-PackageVersion $SageWheel.Version))) { 'KEEP' } else { 'INSTALL' }
  $includeOk = Test-Path (Join-Path $Root 'python_embeded\include\Python.h')
  $libsDir = Join-Path $Root 'python_embeded\libs'
  $libsOk = (Test-Path $libsDir) -and (@(Get-ChildItem $libsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue).Count -gt 0)
  $devAction = if ($includeOk -and $libsOk) { 'KEEP' } else { 'INSTALL' }
  if ($devAction -eq 'INSTALL' -and -not $PyDevAsset) {
    throw "Python developer files are missing and no documented include/libs asset was found for Python $($EnvInfo.python_mm)."
  }
  $tm = $TritonMinor.Split('.')
  $tritonUpper = "$($tm[0]).$([int]$tm[1] + 1)"
  [pscustomobject]@{
    Torch='KEEP'
    PythonDev=$devAction
    Triton=$tritonAction
    TritonConstraint="triton-windows>=$TritonMinor,<$tritonUpper"
    SageAttention=$sageAction
    SageSource=$SageWheel.Source
    SageWheel=$SageWheel.Name
  }
}

function Show-Environment([object]$E) {
  Info "Python: $($E.python)"
  Info "PyTorch: $($E.torch)  [READ-ONLY]"
  Info "CUDA: $($E.cuda)"
  Info "GPU: $($E.gpu) (sm$($E.cc -replace '\.',''))"
  Info "Triton-Windows: $(if ($E.triton_windows) {$E.triton_windows} else {'not installed'})"
  Info "SageAttention: $(if ($E.sageattention) {$E.sageattention} else {'not installed'})"
}

function Show-Plan([object]$P) {
  Info "PyTorch:        $($P.Torch)"
  Info "Python dev:    $($P.PythonDev)"
  Info "Triton:        $($P.Triton)  ($($P.TritonConstraint))"
  Info "SageAttention: $($P.SageAttention)"
  Info "Sage source:   $($P.SageSource)"
  Info "Sage wheel:    $($P.SageWheel)"
}

function Start-Log {
  $logs = Join-Path $Root 'logs'
  New-Item -ItemType Directory -Path $logs -Force | Out-Null
  $path = Join-Path $logs ("Install-SageAttention-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Start-Transcript -Path $path -Force | Out-Null
  $script:TranscriptStarted = $true
  Info "Log: $path"
}

function Backup-State([object]$EnvInfo, [object]$Plan) {
  Step 'Backup'
  $script:BackupDir = Join-Path $Root ("backup\Install-SageAttention-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
  $EnvInfo | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:BackupDir 'environment.json') -Encoding UTF8
  $Plan | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:BackupDir 'plan.json') -Encoding UTF8
  (Invoke-Proc $Py @('-m','pip','freeze') 120).Out | Set-Content (Join-Path $script:BackupDir 'pip-freeze.txt') -Encoding UTF8

  $snapshot = Join-Path $script:BackupDir 'site-packages'
  New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
  foreach ($pattern in @('sageattention*','triton*')) {
    Get-ChildItem -LiteralPath $EnvInfo.site_packages -Filter $pattern -ErrorAction SilentlyContinue |
      Copy-Item -Destination $snapshot -Recurse -Force
  }

  if ($Plan.PythonDev -eq 'INSTALL') {
    $dev = Join-Path $script:BackupDir 'python-dev'
    New-Item -ItemType Directory -Path $dev -Force | Out-Null
    foreach ($name in @('include','libs')) {
      $src = Join-Path (Join-Path $Root 'python_embeded') $name
      if (Test-Path $src) { Copy-Item $src (Join-Path $dev $name) -Recurse -Force }
    }
  }
  Ok "Backup created: $script:BackupDir"
}

function Stage-Files([object]$Plan, [object]$SageWheel, [object]$PyDevAsset) {
  Step 'Download / stage'
  $stage = Join-Path $script:BackupDir 'stage'
  New-Item -ItemType Directory -Path $stage -Force | Out-Null

  $tritonWheel = $null
  if ($Plan.Triton -eq 'INSTALL') {
    Invoke-Proc $Py @('-m','pip','download','--only-binary=:all:','--no-deps','--dest',$stage,$Plan.TritonConstraint) 900 | Out-Null
    $tritonWheel = @(Get-ChildItem $stage -Filter 'triton_windows-*.whl' | Sort-Object Name -Descending)[0]
    if (-not $tritonWheel) { throw 'Triton wheel could not be staged.' }
    Ok "Staged $($tritonWheel.Name)"
  }

  $sagePath = $null
  if ($Plan.SageAttention -eq 'INSTALL') {
    $sagePath = Join-Path $stage $SageWheel.Name
    Invoke-WebRequest -Uri $SageWheel.Url -Headers @{ 'User-Agent'='ComfyUI-SageAttention-Installer' } -OutFile $sagePath -TimeoutSec 300
    if ((Get-Item $sagePath).Length -lt 100KB) { throw 'Downloaded SageAttention wheel is unexpectedly small.' }
    Ok "Staged $($SageWheel.Name)"
  }

  $devZip = $null
  if ($Plan.PythonDev -eq 'INSTALL') {
    $devZip = Join-Path $stage $PyDevAsset.Name
    Invoke-WebRequest -Uri $PyDevAsset.Url -Headers @{ 'User-Agent'='ComfyUI-SageAttention-Installer' } -OutFile $devZip -TimeoutSec 300
    Ok "Staged $($PyDevAsset.Name)"
  }

  [pscustomobject]@{
    Triton=$(if ($tritonWheel) { $tritonWheel.FullName } else { $null })
    Sage=$sagePath
    PythonDev=$devZip
    Stage=$stage
  }
}

function Install-PythonDev([string]$ZipPath) {
  $tmp = Join-Path (Split-Path $ZipPath -Parent) 'pydev'
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $tmp -Force
  foreach ($name in @('include','libs')) {
    $src = Join-Path $tmp $name
    if (-not (Test-Path $src)) { throw "Python dev archive is missing '$name'." }
    $dst = Join-Path (Join-Path $Root 'python_embeded') $name
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item (Join-Path $src '*') $dst -Recurse -Force
  }
}

function Install-Wheel([string]$Path) {
  Invoke-Proc $Py @('-m','pip','install','--no-deps','--force-reinstall',$Path) 900 | Out-Null
}

function Remove-TargetPackages([string]$SitePackages) {
  Invoke-Proc $Py @('-m','pip','uninstall','-y','sageattention','triton-windows','triton') 300 | Out-Null
  foreach ($pattern in @('sageattention*','triton*')) {
    Get-ChildItem -LiteralPath $SitePackages -Filter $pattern -ErrorAction SilentlyContinue |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Recover([object]$EnvInfo, [object]$Plan) {
  Step 'Recovery'
  try {
    Remove-TargetPackages $EnvInfo.site_packages
    $snapshot = Join-Path $script:BackupDir 'site-packages'
    if (Test-Path $snapshot) {
      Get-ChildItem $snapshot | Copy-Item -Destination $EnvInfo.site_packages -Recurse -Force
    }
    if ($Plan.PythonDev -eq 'INSTALL') {
      foreach ($name in @('include','libs')) {
        $dst = Join-Path (Join-Path $Root 'python_embeded') $name
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        $saved = Join-Path (Join-Path $script:BackupDir 'python-dev') $name
        if (Test-Path $saved) { Copy-Item $saved $dst -Recurse -Force }
      }
    }
    Ok 'Previous Triton/SageAttention state restored.'
  }
  catch {
    Warn "Automatic recovery was incomplete: $($_.Exception.Message)"
    Warn "Backup is preserved at $script:BackupDir"
  }
}

function Write-VerifyScript([string]$Path) {
  @'
import torch
import torch.nn.functional as F
import triton
import triton.language as tl
from sageattention import sageattn

assert torch.cuda.is_available()

@triton.jit
def add_kernel(x, y, out, n: tl.constexpr, BLOCK: tl.constexpr):
    offs = tl.arange(0, BLOCK)
    mask = offs < n
    tl.store(out + offs, tl.load(x + offs, mask=mask) + tl.load(y + offs, mask=mask), mask=mask)

x = torch.randn(256, device="cuda", dtype=torch.float32)
y = torch.randn_like(x)
z = torch.empty_like(x)
add_kernel[(1,)](x, y, z, x.numel(), BLOCK=256)
torch.cuda.synchronize()
assert torch.allclose(z, x + y, rtol=1e-4, atol=1e-4)

q = torch.randn(1, 2, 128, 64, device="cuda", dtype=torch.float16)
k = torch.randn_like(q)
v = torch.randn_like(q)
out = sageattn(q, k, v, tensor_layout="HND", is_causal=False)
ref = F.scaled_dot_product_attention(q, k, v, is_causal=False)
assert torch.isfinite(out).all()
cos = F.cosine_similarity(out.float().flatten(), ref.float().flatten(), dim=0).item()
assert cos > 0.98, f"SageAttention result differs too much from SDPA (cosine={cos:.6f})"
print(f"OK triton={triton.__version__} cosine={cos:.6f}")
'@ | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Verify-Install([object]$EnvInfo) {
  Step 'Verifying'
  $verify = Join-Path (Join-Path $script:BackupDir 'stage') 'verify_install.py'
  Write-VerifyScript $verify
  $result = Invoke-Proc $Py @($verify) 300
  Ok $result.Out
  $after = Get-EnvironmentInfo
  if ($after.torch -ne $EnvInfo.torch) {
    throw "Safety check failed: PyTorch changed from $($EnvInfo.torch) to $($after.torch)."
  }
  Ok 'PyTorch remained unchanged.'
}

function Create-Runner {
  $path = Join-Path $Root 'run_nvidia_gpu_sageattention.bat'
  if (Test-Path $path) {
    Warn 'Runner already exists; it was not overwritten.'
    return
  }
  "@echo off`r`n.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --use-sage-attention`r`npause`r`n" |
    Set-Content -LiteralPath $path -Encoding ASCII
  Ok 'Created run_nvidia_gpu_sageattention.bat'
}

Set-Location $Root
try {
  Step 'Detecting environment'
  Assert-PortableRoot
  $envInfo = Get-EnvironmentInfo
  Assert-Hardware $envInfo
  Show-Environment $envInfo

  Step 'Compatibility'
  $tritonMinor = Get-TritonMinor $envInfo.torch
  Info "PyTorch $((Get-BaseVersion $envInfo.torch).Major).$((Get-BaseVersion $envInfo.torch).Minor) -> Triton $tritonMinor.x"
  $sageWheel = Resolve-Sage $envInfo
  if (-not $sageWheel) {
    throw "No exact SageAttention 2.2 Windows wheel was found for Python $($envInfo.python_mm), PyTorch $($envInfo.torch), CUDA $($envInfo.cuda)."
  }
  if ($sageWheel.Source -ne 'Comfy-Org/wheels') {
    Warn "Community fallback selected: $($sageWheel.Source)"
  }
  $pyDevAsset = Resolve-PyDevAsset $envInfo.python_mm
  $plan = New-Plan $envInfo $sageWheel $tritonMinor $pyDevAsset

  Step 'Install plan'
  Show-Plan $plan

  $hasChanges = @($plan.PythonDev,$plan.Triton,$plan.SageAttention) -contains 'INSTALL'
  if ($DryRun) {
    Step 'Done'
    Ok 'Dry run complete. No files or packages were changed.'
    return
  }

  Start-Log
  Step 'Install plan (logged)'
  Show-Environment $envInfo
  Show-Plan $plan

  if (-not $hasChanges) {
    if ($CreateRunner) { Create-Runner }
    Step 'Done'
    Ok 'Triton and SageAttention are already compatible. Nothing was changed.'
    return
  }

  Backup-State $envInfo $plan
  $staged = Stage-Files $plan $sageWheel $pyDevAsset

  Step 'Installing'
  $script:MutationStarted = $true
  if ($plan.PythonDev -eq 'INSTALL') {
    Info 'Installing embedded Python include/libs ...'
    Install-PythonDev $staged.PythonDev
  }
  if ($plan.Triton -eq 'INSTALL') {
    Info 'Installing Triton-Windows ...'
    if ($envInfo.legacy_triton) { Invoke-Proc $Py @('-m','pip','uninstall','-y','triton') 300 | Out-Null }
    Install-Wheel $staged.Triton
  }
  if ($plan.SageAttention -eq 'INSTALL') {
    Info "Installing SageAttention from $($sageWheel.Source) ..."
    Install-Wheel $staged.Sage
  }

  Verify-Install $envInfo
  if ($CreateRunner) { Create-Runner }

  Step 'Done'
  Ok 'Installation completed and GPU verification passed.'
  Info "Backup: $script:BackupDir"
}
catch {
  Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
  if (-not $DryRun -and $script:MutationStarted -and $script:BackupDir) {
    Recover $envInfo $plan
  }
  throw
}
finally {
  if ($script:TranscriptStarted) {
    try { Stop-Transcript | Out-Null } catch {}
  }
}
