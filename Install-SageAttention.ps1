#Requires -Version 7.0
<#
.SYNOPSIS
  Installs compatible SageAttention backends for ComfyUI Windows Portable.

.DESCRIPTION
  Backend-aware installer for SageAttention 2.2 / SageAttention2++ and SageAttention 3.
  PyTorch, torchvision and torchaudio are always treated as read-only.

  Detect -> Evaluate -> Recommend -> Select -> Resolve -> Plan -> Backup -> Stage ->
  Execute -> Verify -> Recover on failure.
#>

[CmdletBinding()]
param(
  [ValidateSet('Auto','Sage2','Sage3','Both')]
  [string] $Backend,
  [switch] $DryRun,
  [switch] $Yes,
  [switch] $CreateRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$Root = $PSScriptRoot
$Py = Join-Path $Root 'python_embeded\python.exe'
$ComfyMain = Join-Path $Root 'ComfyUI\main.py'
$ComfyAttention = Join-Path $Root 'ComfyUI\comfy\ldm\modules\attention.py'
$ComfyCliArgs = Join-Path $Root 'ComfyUI\comfy\cli_args.py'
$CommunityIndexUrl = 'https://raw.githubusercontent.com/wildminder/AI-windows-whl/refs/heads/main/wheels.json'
$PyDevReleaseApi = 'https://api.github.com/repos/woct0rdho/triton-windows/releases/tags/v3.0.0-windows.post1'
$UserAgent = 'ComfyUI-SageAttention-Installer/3'

# Current upstream SageAttention3 runtime kernels explicitly accept sm120/sm121.
# Prebuilt Windows wheel architecture must ALSO be proven by the selected wheel source.
$Sage3RuntimeArchs = @('12.0','12.1')
$CommunitySage3VerifiedArchs = @('12.0')

$script:LogPath = $null
$script:MutationStarted = $false
$script:BackupDir = $null
$script:CommunityIndexData = $null
$script:ComfySpecCache = @{}

function Write-LogLine([string]$Text) {
  if ($script:LogPath) {
    Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Text) -Encoding UTF8
  }
}

function Phase([int]$Number, [string]$Text) {
  Write-Host "`n[$Number/8] $Text" -ForegroundColor Cyan
  Write-LogLine "PHASE $Number/8 $Text"
}
function Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green; Write-LogLine "OK $Text" }
function Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray; Write-LogLine "INFO $Text" }
function Warn([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow; Write-LogLine "WARN $Text" }
function Fail([string]$Text) { Write-Host "  [X] $Text" -ForegroundColor Red; Write-LogLine "ERROR $Text" }

function Start-Log {
  $logs = Join-Path $Root 'logs'
  New-Item -ItemType Directory -Path $logs -Force | Out-Null
  $script:LogPath = Join-Path $logs ("Install-SageAttention-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
  Set-Content -LiteralPath $script:LogPath -Value "ComfyUI SageAttention Installer log" -Encoding UTF8
  Info "Log: $script:LogPath"
}

function Invoke-Proc {
  param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$Args = @(),
    [int]$TimeoutSec = 900,
    [switch]$AllowFailure
  )
  Write-LogLine "COMMAND: $File $($Args -join ' ')"
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
      throw "Command timed out. See the log for details."
    }
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    Write-LogLine "EXIT: $($p.ExitCode)"
    if ($out) { Write-LogLine "STDOUT:`n$out" }
    if ($err) { Write-LogLine "STDERR:`n$err" }
    if ($p.ExitCode -ne 0 -and -not $AllowFailure) {
      throw "A required command failed. See the log for the full output."
    }
    [pscustomobject]@{ Out=$out.Trim(); Err=$err.Trim(); ExitCode=$p.ExitCode }
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

function Get-MajorMinor([string]$Value) {
  $v = Get-BaseVersion $Value
  "$($v.Major).$($v.Minor)"
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

function Test-MinVersion([string]$Current, [string]$Minimum) {
  (Get-BaseVersion $Current) -ge (Get-BaseVersion $Minimum)
}

function Normalize-PackageVersion([string]$Value) {
  if (-not $Value) { return '' }
  ($Value.ToLowerInvariant() -replace '[-_]','.')
}

function Get-TritonMinor([string]$TorchVersion) {
  $key = Get-MajorMinor $TorchVersion
  $map = @{
    '2.4'='3.1'; '2.5'='3.1'; '2.6'='3.2'; '2.7'='3.3'; '2.8'='3.4'
    '2.9'='3.5'; '2.10'='3.6'; '2.11'='3.6'; '2.12'='3.7'; '2.13'='3.7'; '2.14'='3.8'
  }
  if (-not $map.ContainsKey($key)) { return $null }
  $map[$key]
}

function Get-Architecture([string]$ComputeCapability) {
  switch ($ComputeCapability) {
    '8.0'  { return [pscustomobject]@{ Name='Ampere'; Family='Ampere'; CC='8.0' } }
    '8.6'  { return [pscustomobject]@{ Name='Ampere'; Family='Ampere'; CC='8.6' } }
    '8.9'  { return [pscustomobject]@{ Name='Ada'; Family='Ada'; CC='8.9' } }
    '9.0'  { return [pscustomobject]@{ Name='Hopper'; Family='Hopper'; CC='9.0' } }
    '10.0' { return [pscustomobject]@{ Name='Blackwell (datacenter)'; Family='Blackwell'; CC='10.0' } }
    '12.0' { return [pscustomobject]@{ Name='Blackwell'; Family='Blackwell'; CC='12.0' } }
    '12.1' { return [pscustomobject]@{ Name='Blackwell'; Family='Blackwell'; CC='12.1' } }
    default { return [pscustomobject]@{ Name='Unknown'; Family='Unknown'; CC=$ComputeCapability } }
  }
}

function Get-EnvironmentInfo {
  $code = @'
import json, sys, site, struct, importlib.metadata as m
try:
    import torch
except Exception as e:
    print(json.dumps({"error": f"PyTorch import failed: {e}"}))
    raise SystemExit

def dist(name):
    try: return m.version(name)
    except m.PackageNotFoundError: return None

gpu = cc = None
vram = 0
if torch.cuda.is_available():
    gpu = torch.cuda.get_device_name(0)
    cc = ".".join(map(str, torch.cuda.get_device_capability(0)))
    vram = round(torch.cuda.get_device_properties(0).total_memory / (1024 ** 3), 1)

print(json.dumps({
    "error": None,
    "python": ".".join(map(str, sys.version_info[:3])),
    "python_mm": ".".join(map(str, sys.version_info[:2])),
    "python_bits": struct.calcsize("P") * 8,
    "cp": f"cp{sys.version_info.major}{sys.version_info.minor}",
    "torch": torch.__version__,
    "cuda": torch.version.cuda,
    "cuda_ok": torch.cuda.is_available(),
    "gpu": gpu,
    "cc": cc,
    "vram_gb": vram,
    "site_packages": site.getsitepackages()[0],
    "triton_windows": dist("triton-windows"),
    "legacy_triton": dist("triton"),
    "sageattention": dist("sageattention"),
    "sageattn3": dist("sageattn3")
}))
'@
  $obj = (Py $code) | ConvertFrom-Json
  if ($obj.error) { throw $obj.error }
  $obj | Add-Member -NotePropertyName architecture -NotePropertyValue (Get-Architecture $obj.cc)
  $obj
}

function Get-ComfyCapabilities {
  $attentionText = if (Test-Path $ComfyAttention) { Get-Content -LiteralPath $ComfyAttention -Raw } else { '' }
  $cliText = if (Test-Path $ComfyCliArgs) { Get-Content -LiteralPath $ComfyCliArgs -Raw } else { '' }
  $customNodes = Join-Path $Root 'ComfyUI\custom_nodes'
  $kj = $false
  if (Test-Path $customNodes) {
    $kj = @(Get-ChildItem -LiteralPath $customNodes -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)KJNodes' }).Count -gt 0
  }
  [pscustomobject]@{
    Sage3Import = $attentionText -match 'SAGE_ATTENTION3_IS_AVAILABLE'
    Sage3Registered = $attentionText -match 'register_attention_function\(["'']sage3["'']'
    Sage3Cli = $cliText -match '--use-sage-attention3'
    Sage2Cli = $cliText -match '--use-sage-attention'
    KJNodes = $kj
  }
}

function Assert-PortableRoot {
  if (-not $IsWindows) { throw 'This installer supports Windows only.' }
  if (-not (Test-Path -LiteralPath $Py -PathType Leaf)) { throw 'python_embeded\python.exe was not found. Run this script from the ComfyUI Windows Portable root.' }
  if (-not (Test-Path -LiteralPath $ComfyMain -PathType Leaf)) { throw 'ComfyUI\main.py was not found. Run this script from the ComfyUI Windows Portable root.' }

  $pyHome = Split-Path $Py -Parent
  $vc140 = @((Join-Path $pyHome 'vcruntime140.dll'), (Join-Path $env:SystemRoot 'System32\vcruntime140.dll'))
  $vc140_1 = @((Join-Path $pyHome 'vcruntime140_1.dll'), (Join-Path $env:SystemRoot 'System32\vcruntime140_1.dll'))
  if (-not ($vc140 | Where-Object { Test-Path $_ }) -or -not ($vc140_1 | Where-Object { Test-Path $_ })) {
    throw 'Microsoft Visual C++ 2015-2022 Redistributable (x64) was not detected.'
  }

  try {
    $running = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
      Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq [IO.Path]::GetFullPath($Py)) }
  }
  catch { throw "Could not safely check whether ComfyUI is running: $($_.Exception.Message)" }
  if ($running) { throw 'ComfyUI embedded Python is currently running. Close ComfyUI and try again.' }
}

function Assert-BaseEnvironment([object]$EnvInfo) {
  if ($EnvInfo.python_bits -ne 64) { throw '64-bit embedded Python is required.' }
  if (-not $EnvInfo.cuda_ok -or -not $EnvInfo.cuda) { throw 'The bundled PyTorch has no usable NVIDIA CUDA runtime.' }
  if ($EnvInfo.architecture.Family -eq 'Unknown') { throw "GPU compute capability $($EnvInfo.cc) is not supported by this installer." }
}

function Show-Environment([object]$E, [object]$C) {
  Write-Host ("  {0,-15} {1}" -f 'GPU', $E.gpu)
  Write-Host ("  {0,-15} {1} (sm_{2})" -f 'Architecture', $E.architecture.Name, ($E.cc -replace '\.',''))
  Write-Host ("  {0,-15} {1} GB" -f 'VRAM', $E.vram_gb)
  Write-Host ("  {0,-15} {1}" -f 'Python', $E.python)
  Write-Host ("  {0,-15} {1}  [READ-ONLY]" -f 'PyTorch', $E.torch)
  Write-Host ("  {0,-15} {1}" -f 'CUDA runtime', $E.cuda)
  Write-Host ("  {0,-15} {1}" -f 'Triton-Windows', $(if ($E.triton_windows) {$E.triton_windows} else {'not installed'}))
  Write-Host ("  {0,-15} {1}" -f 'SageAttention 2', $(if ($E.sageattention) {$E.sageattention} else {'not installed'}))
  Write-Host ("  {0,-15} {1}" -f 'SageAttention 3', $(if ($E.sageattn3) {$E.sageattn3} else {'not installed'}))
  if ($C.Sage3Registered) { Info 'ComfyUI: native "sage3" backend registration detected.' }
  elseif ($C.Sage3Import) { Info 'ComfyUI: SageAttention 3 import support detected.' }
}

function Test-PythonWheelTag([string]$FileName, [string]$PythonMM) {
  $digits = $PythonMM -replace '\.',''
  if ($FileName -match '-cp(\d+)-cp\1-win_amd64\.whl$') { return ($Matches[1] -eq $digits) }
  if ($FileName -match '-cp(\d+)-abi3-win_amd64\.whl$') { return ([int]$digits -ge [int]$Matches[1]) }
  return $false
}

function Get-WheelVersion([string]$FileName, [string]$PackageName) {
  $escaped = [regex]::Escape($PackageName)
  if ($FileName -match "(?i)^${escaped}-(.+?)-cp\d+") { return $Matches[1] }
  return $null
}

function Get-VersionRank([string]$Value) {
  if ($Value -match '^(\d+)\.(\d+)\.(\d+)(?:\.post(\d+))?') {
    $post = if ($Matches[4]) { [long]$Matches[4] } else { 0L }
    return ([long]$Matches[1]*1000000000L)+([long]$Matches[2]*1000000L)+([long]$Matches[3]*1000L)+$post
  }
  return 0L
}

function Get-ComfyWheelArchList([string]$PackageName, [object]$EnvInfo) {
  $cacheKey = "$PackageName|$($EnvInfo.cuda)|$(Get-MajorMinor $EnvInfo.torch)"
  if ($script:ComfySpecCache.ContainsKey($cacheKey)) { return @($script:ComfySpecCache[$cacheKey]) }

  $url = "https://raw.githubusercontent.com/Comfy-Org/wheels/main/packages/$PackageName.yml"
  try { $text = (Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent'=$UserAgent } -TimeoutSec 30).Content }
  catch { return @() }

  $beforeMatrix = ($text -split '(?m)^build_matrix:')[0]
  $defaultArch = @()
  $mDefault = [regex]::Match($beforeMatrix, '(?m)^arch_list:\s*["''](?<a>[^"'']+)["'']')
  if ($mDefault.Success) { $defaultArch = @($mDefault.Groups['a'].Value -split '\s+' | Where-Object { $_ }) }

  $matches = [regex]::Matches($text, '(?ms)^\s*-\s*cuda:\s*["''](?<cuda>[^"'']+)["'']\s*\r?\n\s*pytorch:\s*["''](?<torch>[^"'']+)["''](?<body>.*?)(?=^\s*-\s*cuda:|^\s*platforms:)')
  foreach ($m in $matches) {
    if ($m.Groups['cuda'].Value -ne [string]$EnvInfo.cuda) { continue }
    if ((Get-MajorMinor $m.Groups['torch'].Value) -ne (Get-MajorMinor $EnvInfo.torch)) { continue }
    $body = $m.Groups['body'].Value
    $pyToken = '"' + $EnvInfo.python_mm + '"'
    if ($body -notmatch [regex]::Escape($pyToken)) { continue }
    $arch = $defaultArch
    $ma = [regex]::Match($body, '(?m)^\s*arch_list:\s*["''](?<a>[^"'']+)["'']')
    if ($ma.Success) { $arch = @($ma.Groups['a'].Value -split '\s+' | Where-Object { $_ }) }
    $script:ComfySpecCache[$cacheKey] = @($arch)
    return @($arch)
  }
  $script:ComfySpecCache[$cacheKey] = @()
  return @()
}

function Test-ArchListSupports([string[]]$ArchList, [string]$CC, [switch]$StrictMinor) {
  if (-not $ArchList -or $ArchList.Count -eq 0) { return $false }
  if ($CC -in $ArchList) { return $true }
  if (-not $StrictMinor -and $CC -match '^8\.' -and '8.0' -in $ArchList) { return $true }
  return $false
}

function Resolve-OfficialWheel([string]$PackageName, [object]$EnvInfo, [switch]$StrictArch) {
  $indexUrl = "https://comfy-org.github.io/wheels/$PackageName/"
  $torch = Get-BaseVersion $EnvInfo.torch
  $torchTag = "$($torch.Major)$($torch.Minor)"
  $cuTag = 'cu' + ($EnvInfo.cuda -replace '\.','')
  try { $html = (Invoke-WebRequest -Uri $indexUrl -Headers @{ 'User-Agent'=$UserAgent } -TimeoutSec 30).Content }
  catch { return $null }

  $archList = Get-ComfyWheelArchList $PackageName $EnvInfo
  if (-not (Test-ArchListSupports $archList $EnvInfo.cc -StrictMinor:$StrictArch)) { return $null }

  $urls = foreach ($m in [regex]::Matches($html, 'href=["''](?<u>[^"'']+\.whl[^"'']*)["'']', 'IgnoreCase')) {
    $href = [System.Net.WebUtility]::HtmlDecode($m.Groups['u'].Value)
    ([uri]::new([uri]$indexUrl, $href)).AbsoluteUri
  }
  $matches = foreach ($url in $urls) {
    $name = [uri]::UnescapeDataString((Split-Path ([uri]$url).AbsolutePath -Leaf))
    if ($name -notmatch "(?i)^$([regex]::Escape($PackageName))-") { continue }
    if ($PackageName -eq 'sageattention' -and $name -notmatch '(?i)^sageattention-2\.2') { continue }
    if ($name -notmatch [regex]::Escape("+${cuTag}torch${torchTag}")) { continue }
    if (-not (Test-PythonWheelTag $name $EnvInfo.python_mm)) { continue }
    [pscustomobject]@{
      Url=$url; Name=$name; Version=(Get-WheelVersion $name $PackageName)
      Source='Comfy-Org/wheels'; Community=$false; ArchList=@($archList)
    }
  }
  @($matches | Sort-Object Name -Descending)[0]
}

function Get-CommunityIndex {
  if ($script:CommunityIndexData) { return $script:CommunityIndexData }
  $script:CommunityIndexData = (Invoke-WebRequest -Uri $CommunityIndexUrl -Headers @{ 'User-Agent'=$UserAgent } -TimeoutSec 30).Content | ConvertFrom-Json
  $script:CommunityIndexData
}

function Resolve-CommunityWheel([string]$PackageName, [object]$EnvInfo) {
  $index = Get-CommunityIndex
  $needle = ($PackageName -replace '[^a-zA-Z0-9]','').ToLowerInvariant()
  $pkg = @($index.packages | Where-Object {
    (([string]$_.id -replace '[^a-zA-Z0-9]','').ToLowerInvariant() -eq $needle) -or
    (([string]$_.name -replace '[^a-zA-Z0-9]','').ToLowerInvariant() -eq $needle)
  })[0]
  if (-not $pkg) { return $null }

  $matches = foreach ($w in @($pkg.wheels)) {
    if (-not $w.url -or $w.url -notmatch '(?i)win_amd64\.whl') { continue }
    if ($PackageName -eq 'sageattention' -and [string]$w.package_version -notmatch '^2\.2') { continue }
    $wheelUri = [uri][string]$w.url
    if ($wheelUri.Scheme -ne 'https' -or $wheelUri.Host -notin @('github.com','huggingface.co')) { continue }
    if (-not (Test-Range $EnvInfo.torch $w.torch_version)) { continue }
    if (-not (Test-Range $EnvInfo.python_mm $w.python_version)) { continue }
    if (-not (Test-Range $EnvInfo.cuda $w.cuda_version)) { continue }

    $name = [uri]::UnescapeDataString((Split-Path $wheelUri.AbsolutePath -Leaf))
    if ($name -notmatch "(?i)^$([regex]::Escape($PackageName))-") { continue }
    if (-not (Test-PythonWheelTag $name $EnvInfo.python_mm)) { continue }

    # Compiled CUDA wheels must match the embedded CUDA minor tag exactly when the filename declares one.
    if ($name -match '(?i)\+cu(?<cu>\d+)') {
      if ($Matches['cu'] -ne ($EnvInfo.cuda -replace '\.','')) { continue }
    }
    # If the wheel declares a Torch build tag, require the same Torch major/minor.
    if ($name -match '(?i)torch(?<t>\d+(?:\.\d+){0,2})') {
      $tag = $Matches['t']
      if ($tag.Contains('.')) {
        if ((Get-MajorMinor $tag) -ne (Get-MajorMinor $EnvInfo.torch)) { continue }
      }
      else {
        $digits = ((Get-MajorMinor $EnvInfo.torch) -replace '\.','')
        if ($tag -ne $digits) { continue }
      }
    }

    [pscustomobject]@{
      Url=[string]$w.url; Name=$name; Version=(Get-WheelVersion $name $PackageName)
      PackageVersion=[string]$w.package_version; Source='wildminder/AI-windows-whl'
      Community=$true; Rank=(Get-VersionRank ([string]$w.package_version)); ArchList=@()
    }
  }
  @($matches | Sort-Object Rank,Name -Descending)[0]
}

function Resolve-BackendWheel([string]$PackageName, [object]$EnvInfo, [switch]$Sage3) {
  $official = Resolve-OfficialWheel $PackageName $EnvInfo -StrictArch:$Sage3
  if ($official) { return $official }

  if ($Sage3 -and $EnvInfo.cc -notin $CommunitySage3VerifiedArchs) { return $null }
  Resolve-CommunityWheel $PackageName $EnvInfo
}

function Resolve-PyDevAsset([string]$PythonMM) {
  try {
    $release = Invoke-RestMethod -Uri $PyDevReleaseApi -Headers @{ 'User-Agent'=$UserAgent } -TimeoutSec 30
  }
  catch { return $null }
  $escaped = [regex]::Escape($PythonMM)
  $asset = @($release.assets | Where-Object { $_.name -match "^python_${escaped}\.\d+_include_libs\.zip$" })[0]
  if (-not $asset) { return $null }
  [pscustomobject]@{ Name=$asset.name; Url=$asset.browser_download_url }
}

function Get-PythonDevState([string]$PythonMM) {
  $includeOk = Test-Path (Join-Path $Root 'python_embeded\include\Python.h')
  $libsDir = Join-Path $Root 'python_embeded\libs'
  $libsOk = (Test-Path $libsDir) -and (@(Get-ChildItem $libsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue).Count -gt 0)
  if ($includeOk -and $libsOk) { return [pscustomobject]@{ Ready=$true; Asset=$null; Reason=$null } }
  $asset = Resolve-PyDevAsset $PythonMM
  if (-not $asset) { return [pscustomobject]@{ Ready=$false; Asset=$null; Reason="Python developer include/libs are missing and no documented asset was found for Python $PythonMM." } }
  [pscustomobject]@{ Ready=$true; Asset=$asset; Reason=$null }
}

function Test-Sage2Hardware([object]$EnvInfo) {
  $cc = $EnvInfo.cc
  if ($cc -notin @('8.0','8.6','8.9','9.0','10.0','12.0','12.1')) { return "Upstream SageAttention 2 does not support compute capability $cc." }
  $minCuda = switch ($EnvInfo.architecture.Family) {
    'Ampere' { '12.0' }
    'Ada' { '12.4' }
    'Hopper' { '12.3' }
    'Blackwell' { '12.8' }
    default { $null }
  }
  if ($minCuda -and -not (Test-MinVersion $EnvInfo.cuda $minCuda)) { return "SageAttention 2 on $($EnvInfo.architecture.Name) requires CUDA $minCuda or newer." }
  return $null
}

function Test-Sage3Hardware([object]$EnvInfo) {
  if ($EnvInfo.architecture.Family -ne 'Blackwell') { return 'SageAttention 3 is currently a Blackwell-specific backend.' }
  if ($EnvInfo.cc -notin $Sage3RuntimeArchs) {
    return "Current SageAttention 3 runtime kernels do not accept sm_$($EnvInfo.cc -replace '\.','')."
  }
  if (-not (Test-MinVersion $EnvInfo.cuda '12.8')) { return 'SageAttention 3 requires CUDA 12.8 or newer.' }
  if (-not (Test-MinVersion $EnvInfo.torch '2.8')) { return 'SageAttention 3 upstream requires PyTorch 2.8 or newer.' }
  return $null
}

function Evaluate-Sage2([object]$EnvInfo) {
  $reason = Test-Sage2Hardware $EnvInfo
  if ($reason) { return [pscustomobject]@{ Supported=$false; Reason=$reason; Wheel=$null; TritonMinor=$null; PyDev=$null } }

  $tritonMinor = Get-TritonMinor $EnvInfo.torch
  if (-not $tritonMinor) { return [pscustomobject]@{ Supported=$false; Reason="PyTorch $(Get-MajorMinor $EnvInfo.torch) is outside the current triton-windows compatibility matrix."; Wheel=$null; TritonMinor=$null; PyDev=$null } }

  $pyDev = Get-PythonDevState $EnvInfo.python_mm
  if (-not $pyDev.Ready) { return [pscustomobject]@{ Supported=$false; Reason=$pyDev.Reason; Wheel=$null; TritonMinor=$tritonMinor; PyDev=$pyDev } }

  $wheel = Resolve-BackendWheel 'sageattention' $EnvInfo
  if (-not $wheel) {
    return [pscustomobject]@{ Supported=$false; Reason="No compatible SageAttention 2.2 Windows wheel was found for Python $($EnvInfo.python_mm), PyTorch $(Get-MajorMinor $EnvInfo.torch), CUDA $($EnvInfo.cuda) and sm_$($EnvInfo.cc -replace '\.','')."; Wheel=$null; TritonMinor=$tritonMinor; PyDev=$pyDev }
  }
  [pscustomobject]@{ Supported=$true; Reason=$null; Wheel=$wheel; TritonMinor=$tritonMinor; PyDev=$pyDev }
}

function Evaluate-Sage3([object]$EnvInfo) {
  $reason = Test-Sage3Hardware $EnvInfo
  if ($reason) { return [pscustomobject]@{ Supported=$false; Reason=$reason; Wheel=$null; TritonMinor=$null; PyDev=$null } }

  # Current sageattn3/api.py imports Triton and uses @triton.jit for preprocessing.
  $tritonMinor = Get-TritonMinor $EnvInfo.torch
  if (-not $tritonMinor) { return [pscustomobject]@{ Supported=$false; Reason="PyTorch $(Get-MajorMinor $EnvInfo.torch) is outside the current triton-windows compatibility matrix required by SageAttention 3."; Wheel=$null; TritonMinor=$null; PyDev=$null } }

  $pyDev = Get-PythonDevState $EnvInfo.python_mm
  if (-not $pyDev.Ready) { return [pscustomobject]@{ Supported=$false; Reason=$pyDev.Reason; Wheel=$null; TritonMinor=$tritonMinor; PyDev=$pyDev } }

  $wheel = Resolve-BackendWheel 'sageattn3' $EnvInfo -Sage3
  if (-not $wheel) {
    return [pscustomobject]@{ Supported=$false; Reason="No architecture-verified SageAttention 3 Windows wheel was found for Python $($EnvInfo.python_mm), PyTorch $(Get-MajorMinor $EnvInfo.torch), CUDA $($EnvInfo.cuda) and sm_$($EnvInfo.cc -replace '\.','')."; Wheel=$null; TritonMinor=$tritonMinor; PyDev=$pyDev }
  }
  [pscustomobject]@{ Supported=$true; Reason=$null; Wheel=$wheel; TritonMinor=$tritonMinor; PyDev=$pyDev }
}

function Show-BackendStatus([string]$Name, [object]$Eval) {
  if ($Eval.Supported) {
    Write-Host ("  [OK] {0,-20} supported" -f $Name) -ForegroundColor Green
    if ($Eval.Wheel.Community) { Write-Host "       Community fallback wheel will be used." -ForegroundColor Yellow }
  }
  else {
    Write-Host ("  [--] {0,-20} unavailable" -f $Name) -ForegroundColor DarkGray
    Write-Host "       $($Eval.Reason)" -ForegroundColor DarkGray
  }
}

function Get-Recommendation([object]$EnvInfo, [object]$Sage2, [object]$Sage3) {
  if ($EnvInfo.architecture.Family -ne 'Blackwell') {
    if ($Sage2.Supported) { return 'Sage2' }
    return $null
  }
  if ($Sage2.Supported -and $Sage3.Supported) { return 'Both' }
  if ($Sage3.Supported) { return 'Sage3' }
  if ($Sage2.Supported) { return 'Sage2' }
  return $null
}

function Assert-BackendAvailable([string]$Choice, [object]$Sage2, [object]$Sage3) {
  switch ($Choice) {
    'Sage2' { if (-not $Sage2.Supported) { throw "SageAttention 2 is not available: $($Sage2.Reason)" } }
    'Sage3' { if (-not $Sage3.Supported) { throw "SageAttention 3 is not available: $($Sage3.Reason)" } }
    'Both' {
      if (-not $Sage2.Supported) { throw "Both cannot be selected because SageAttention 2 is unavailable: $($Sage2.Reason)" }
      if (-not $Sage3.Supported) { throw "Both cannot be selected because SageAttention 3 is unavailable: $($Sage3.Reason)" }
    }
  }
}

function Select-Backend([string]$Requested, [string]$Recommended, [object]$Sage2, [object]$Sage3, [object]$EnvInfo) {
  if ($Requested) {
    $choice = if ($Requested -eq 'Auto') { $Recommended } else { $Requested }
    if (-not $choice) { throw 'No supported SageAttention backend was found for this environment.' }
    Assert-BackendAvailable $choice $Sage2 $Sage3
    Info "Selected: $choice$(if ($Requested -eq 'Auto') {' (automatic recommendation)'} else {''})"
    return $choice
  }

  Write-Host ''
  if ($EnvInfo.architecture.Family -eq 'Blackwell' -and $Sage2.Supported -and $Sage3.Supported) {
    Info 'SageAttention 3 can be faster on Blackwell; SageAttention 2 is the more conservative compatibility/accuracy option.'
    Info 'Installing both lets compatible workflows choose the backend that fits the model.'
  }

  $bothOk = $Sage2.Supported -and $Sage3.Supported
  $rows = @(
    [pscustomobject]@{ Key='1'; Value='Both'; Label='Both'; Available=$bothOk; Note=$(if ($bothOk) {'Sage2 compatibility + Sage3 Blackwell speed'} else {'Unavailable: requires both supported backends'}) },
    [pscustomobject]@{ Key='2'; Value='Sage3'; Label='SageAttention 3'; Available=$Sage3.Supported; Note=$(if ($Sage3.Supported) {'Blackwell FP4 backend'} else {$Sage3.Reason}) },
    [pscustomobject]@{ Key='3'; Value='Sage2'; Label='SageAttention 2.2'; Available=$Sage2.Supported; Note=$(if ($Sage2.Supported) {'Compatibility / accuracy'} else {$Sage2.Reason}) }
  )

  foreach ($row in $rows) {
    $rec = if ($row.Value -eq $Recommended) { '  <- Recommended' } else { '' }
    if ($row.Available) {
      Write-Host ("  [{0}] {1,-20} {2}{3}" -f $row.Key, $row.Label, $row.Note, $rec)
    }
    else {
      Write-Host ("  [{0}] {1,-20} unavailable" -f $row.Key, $row.Label) -ForegroundColor DarkGray
      Write-Host ("      {0}" -f $row.Note) -ForegroundColor DarkGray
    }
  }
  Write-Host '  [4] Cancel'

  $default = @($rows | Where-Object { $_.Value -eq $Recommended -and $_.Available })[0]
  if (-not $default) { $default = @($rows | Where-Object { $_.Available })[0] }
  while ($true) {
    $answer = Read-Host "Choice [$($default.Key)]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default.Value }
    if ($answer -eq '4') { return $null }
    $hit = @($rows | Where-Object { $_.Key -eq $answer })[0]
    if (-not $hit) { Warn 'Please choose 1, 2, 3 or 4.'; continue }
    if (-not $hit.Available) { Warn "$($hit.Label) is not available on this system: $($hit.Note)"; continue }
    return $hit.Value
  }
}

function New-Plan([string]$Selected, [object]$EnvInfo, [object]$Sage2, [object]$Sage3) {
  $usesSage2 = $Selected -in @('Sage2','Both')
  $usesSage3 = $Selected -in @('Sage3','Both')
  # Both current backends use Triton: SA2 directly; SA3 imports Triton for preprocessing.
  $usesTriton = $usesSage2 -or $usesSage3
  $eval = if ($usesSage2) { $Sage2 } else { $Sage3 }
  $tritonMinor = if ($usesTriton) { $eval.TritonMinor } else { $null }
  $tm = if ($tritonMinor) { $tritonMinor.Split('.') } else { @() }
  $upper = if ($tritonMinor) { "$($tm[0]).$([int]$tm[1] + 1)" } else { $null }
  $constraint = if ($tritonMinor) { "triton-windows>=$tritonMinor,<$upper" } else { $null }

  $tritonAction = 'SKIP'
  $legacyAction = 'SKIP'
  $devAction = 'SKIP'
  $pyDevAsset = $null
  if ($usesTriton) {
    # Legacy `triton` and `triton-windows` both own parts of the `triton` import tree.
    # If legacy Triton is present, remove it and always reinstall the compatible
    # triton-windows wheel afterwards so shared files cannot be left missing.
    $legacyAction = if ($EnvInfo.legacy_triton) { 'REMOVE' } else { 'SKIP' }
    $tritonCompatible = $EnvInfo.triton_windows -and $EnvInfo.triton_windows -match "^$([regex]::Escape($tritonMinor))(\.|$)"
    $tritonAction = if ($tritonCompatible -and $legacyAction -ne 'REMOVE') { 'KEEP' } else { 'INSTALL' }
    $pyDev = $eval.PyDev
    $devAction = if ($pyDev.Asset) { 'INSTALL' } else { 'KEEP' }
    $pyDevAsset = $pyDev.Asset
  }

  $sage2Action = 'SKIP'
  if ($usesSage2) {
    $target = $Sage2.Wheel.Version
    $sage2Action = if ($EnvInfo.sageattention -and $target -and ((Normalize-PackageVersion $EnvInfo.sageattention) -eq (Normalize-PackageVersion $target))) { 'KEEP' } else { 'INSTALL' }
  }

  $sage3Action = 'SKIP'
  if ($usesSage3) {
    $target = $Sage3.Wheel.Version
    $sage3Action = if ($EnvInfo.sageattn3 -and $target -and ((Normalize-PackageVersion $EnvInfo.sageattn3) -eq (Normalize-PackageVersion $target))) { 'KEEP' } else { 'INSTALL' }
  }

  [pscustomobject]@{
    Backend=$Selected; Torch='KEEP'; PythonDev=$devAction; PythonDevAsset=$pyDevAsset
    LegacyTriton=$legacyAction; Triton=$tritonAction; TritonConstraint=$constraint
    Sage2=$sage2Action; Sage2Wheel=$(if ($usesSage2) {$Sage2.Wheel} else {$null})
    Sage3=$sage3Action; Sage3Wheel=$(if ($usesSage3) {$Sage3.Wheel} else {$null})
  }
}

function Show-Plan([object]$P) {
  Write-Host ''
  Write-Host ("  {0,-20} {1}" -f 'Selected backend', $P.Backend)
  Write-Host ("  {0,-20} {1}" -f 'PyTorch', 'KEEP (read-only)')
  Write-Host ("  {0,-20} {1}" -f 'Python include/libs', $P.PythonDev)
  Write-Host ("  {0,-20} {1}" -f 'Legacy triton', $P.LegacyTriton)
  Write-Host ("  {0,-20} {1}{2}" -f 'Triton-Windows', $P.Triton, $(if ($P.TritonConstraint) {"  $($P.TritonConstraint)"} else {''}))
  if ($P.Sage2 -ne 'SKIP') {
    Write-Host ("  {0,-20} {1}" -f 'SageAttention 2', $P.Sage2)
    Write-Host ("  {0,-20} {1}" -f 'Source SA2', $P.Sage2Wheel.Source)
    Write-Host ("  {0,-20} {1}" -f 'Wheel SA2', $P.Sage2Wheel.Name)
  }
  if ($P.Sage3 -ne 'SKIP') {
    Write-Host ("  {0,-20} {1}" -f 'SageAttention 3', $P.Sage3)
    Write-Host ("  {0,-20} {1}" -f 'Source SA3', $P.Sage3Wheel.Source)
    Write-Host ("  {0,-20} {1}" -f 'Wheel SA3', $P.Sage3Wheel.Name)
  }
  if (($P.Sage2Wheel -and $P.Sage2Wheel.Community) -or ($P.Sage3Wheel -and $P.Sage3Wheel.Community)) {
    Warn 'A community fallback wheel is selected because no compatible Comfy-Org wheel was available.'
  }
}

function Get-HasChanges([object]$P) {
  @($P.PythonDev,$P.LegacyTriton,$P.Triton,$P.Sage2,$P.Sage3) | Where-Object { $_ -in @('INSTALL','REMOVE') } | Select-Object -First 1
}

function Get-MutatedPackages([object]$Plan) {
  $p = @()
  if ($Plan.LegacyTriton -eq 'REMOVE') { $p += 'triton' }
  if ($Plan.Triton -eq 'INSTALL') { $p += 'triton-windows' }
  if ($Plan.Sage2 -eq 'INSTALL') { $p += 'sageattention' }
  if ($Plan.Sage3 -eq 'INSTALL') { $p += 'sageattn3' }
  @($p | Select-Object -Unique)
}

function Get-PackagePatterns([string]$PackageName) {
  switch ($PackageName) {
    'triton' { @('triton','triton-*.dist-info') }
    'triton-windows' { @('triton','triton_windows-*.dist-info','triton_windows.libs') }
    'sageattention' { @('sageattention','sageattention-*.dist-info','sageattention.libs','sageattention*.pyd') }
    'sageattn3' { @('sageattn3','sageattn3-*.dist-info','fp4attn_cuda*.pyd','fp4quant_cuda*.pyd') }
    default { @() }
  }
}

function Backup-PackageManifestFiles([string]$PackageName, [string]$ManifestText, [string]$SitePackages, [string]$SnapshotRoot) {
  if (-not $ManifestText) { return }
  $lines = $ManifestText -split '\r?\n'
  $locationLine = @($lines | Where-Object { $_ -match '^Location:\s+' })[0]
  if (-not $locationLine) { return }
  $location = ($locationLine -replace '^Location:\s+','').Trim()
  $filesIndex = [Array]::IndexOf($lines, 'Files:')
  if ($filesIndex -lt 0) { return }

  $siteRoot = [IO.Path]::GetFullPath($SitePackages).TrimEnd('\') + '\'
  for ($i=$filesIndex+1; $i -lt $lines.Count; $i++) {
    $rel = $lines[$i].Trim()
    if (-not $rel) { continue }
    try { $src = [IO.Path]::GetFullPath((Join-Path $location $rel)) } catch { continue }
    if (-not $src.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
    $relative = $src.Substring($siteRoot.Length)
    $dst = Join-Path $SnapshotRoot $relative
    $parent = Split-Path $dst -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}

function Backup-State([object]$EnvInfo, [object]$Plan) {
  $script:BackupDir = Join-Path $Root ("backup\Install-SageAttention-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
  New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
  $EnvInfo | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:BackupDir 'environment.json') -Encoding UTF8
  $Plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:BackupDir 'plan.json') -Encoding UTF8
  (Invoke-Proc $Py @('-m','pip','freeze') 120).Out | Set-Content (Join-Path $script:BackupDir 'pip-freeze.txt') -Encoding UTF8

  $packagesDir = Join-Path $script:BackupDir 'packages'
  New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
  $snapshot = Join-Path $script:BackupDir 'site-packages'
  New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
  foreach ($pkg in (Get-MutatedPackages $Plan)) {
    $show = Invoke-Proc $Py @('-m','pip','show','-f',$pkg) 120 -AllowFailure
    if ($show.ExitCode -eq 0 -and $show.Out) {
      $show.Out | Set-Content (Join-Path $packagesDir ("$($pkg -replace '[^a-zA-Z0-9_.-]','_').manifest.txt")) -Encoding UTF8
      Backup-PackageManifestFiles $pkg $show.Out $EnvInfo.site_packages $snapshot
    }
  }

  # Pattern snapshot is retained as a narrow fallback for package metadata edge cases.
  $patterns = foreach ($pkg in (Get-MutatedPackages $Plan)) { Get-PackagePatterns $pkg }
  foreach ($pattern in @($patterns | Select-Object -Unique)) {
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

function Download-File([string]$Url, [string]$Destination, [string]$Label) {
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $true
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
  try {
    $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode()
    $total = $response.Content.Headers.ContentLength
    $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $buffer = New-Object byte[] (1024 * 1024)
      [long]$readTotal = 0
      while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
        $output.Write($buffer,0,$read)
        $readTotal += $read
        if ($total -and $total -gt 0) {
          $pct = [Math]::Min(100,[int](($readTotal * 100) / $total))
          Write-Progress -Activity $Label -Status ("{0:N1} / {1:N1} MB" -f ($readTotal/1MB),($total/1MB)) -PercentComplete $pct
        }
        else { Write-Progress -Activity $Label -Status ("{0:N1} MB downloaded" -f ($readTotal/1MB)) }
      }
    }
    finally { $output.Dispose(); $input.Dispose() }
  }
  finally { Write-Progress -Activity $Label -Completed; $client.Dispose(); $handler.Dispose() }
}

function Stage-Files([object]$Plan) {
  $stage = Join-Path $script:BackupDir 'stage'
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  $result = [ordered]@{ Stage=$stage; Triton=$null; Sage2=$null; Sage3=$null; PythonDev=$null }

  if ($Plan.Triton -eq 'INSTALL') {
    Write-Progress -Activity 'Preparing installation' -Status 'Downloading Triton-Windows from PyPI' -PercentComplete 15
    Invoke-Proc $Py @('-m','pip','download','--index-url','https://pypi.org/simple','--only-binary=:all:','--no-deps','--dest',$stage,$Plan.TritonConstraint) 900 | Out-Null
    Write-Progress -Activity 'Preparing installation' -Completed
    $wheel = @(Get-ChildItem $stage -Filter 'triton_windows-*.whl' | Sort-Object Name -Descending)[0]
    if (-not $wheel) { throw 'Triton-Windows wheel could not be staged.' }
    $result.Triton = $wheel.FullName
    Info "Staged $($wheel.Name)"
    Write-LogLine "SHA256 $($wheel.Name) $((Get-FileHash $wheel.FullName -Algorithm SHA256).Hash)"
  }

  foreach ($item in @(@{Action=$Plan.Sage2; Wheel=$Plan.Sage2Wheel; Key='Sage2'; Label='SageAttention 2'}, @{Action=$Plan.Sage3; Wheel=$Plan.Sage3Wheel; Key='Sage3'; Label='SageAttention 3'})) {
    if ($item.Action -ne 'INSTALL') { continue }
    $path = Join-Path $stage $item.Wheel.Name
    Download-File $item.Wheel.Url $path ("Downloading $($item.Label)")
    if ((Get-Item $path).Length -lt 100KB) { throw "Downloaded $($item.Label) wheel is unexpectedly small." }
    $result[$item.Key] = $path
    Info "Staged $($item.Wheel.Name)"
    Write-LogLine "SHA256 $($item.Wheel.Name) $((Get-FileHash $path -Algorithm SHA256).Hash)"
  }

  if ($Plan.PythonDev -eq 'INSTALL') {
    $path = Join-Path $stage $Plan.PythonDevAsset.Name
    Download-File $Plan.PythonDevAsset.Url $path 'Downloading embedded Python developer files'
    if ((Get-Item $path).Length -lt 10KB) { throw 'Downloaded Python developer archive is unexpectedly small.' }
    $result.PythonDev = $path
    Info "Staged $($Plan.PythonDevAsset.Name)"
    Write-LogLine "SHA256 $($Plan.PythonDevAsset.Name) $((Get-FileHash $path -Algorithm SHA256).Hash)"
  }
  [pscustomobject]$result
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

function Remove-Package([string]$PackageName) {
  Invoke-Proc $Py @('-m','pip','uninstall','-y',$PackageName) 300 -AllowFailure | Out-Null
}

function Recover([object]$EnvInfo, [object]$Plan) {
  Write-Host "`nRecovery" -ForegroundColor Cyan
  Write-LogLine 'RECOVERY START'
  try {
    $mutated = Get-MutatedPackages $Plan
    foreach ($pkg in $mutated) { Remove-Package $pkg }

    $patterns = foreach ($pkg in $mutated) { Get-PackagePatterns $pkg }
    foreach ($pattern in @($patterns | Select-Object -Unique)) {
      Get-ChildItem -LiteralPath $EnvInfo.site_packages -Filter $pattern -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    $snapshot = Join-Path $script:BackupDir 'site-packages'
    if (Test-Path $snapshot) { Get-ChildItem $snapshot | Copy-Item -Destination $EnvInfo.site_packages -Recurse -Force }

    if ($Plan.PythonDev -eq 'INSTALL') {
      foreach ($name in @('include','libs')) {
        $dst = Join-Path (Join-Path $Root 'python_embeded') $name
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        $saved = Join-Path (Join-Path $script:BackupDir 'python-dev') $name
        if (Test-Path $saved) { Copy-Item $saved $dst -Recurse -Force }
      }
    }
    Ok 'Previous managed-package state restored.'
  }
  catch {
    Warn "Automatic recovery was incomplete: $($_.Exception.Message)"
    Warn "Backup is preserved at $script:BackupDir"
  }
}

function Write-VerifyScript([string]$Path, [string]$Selected) {
  $testSage2 = $Selected -in @('Sage2','Both')
  $testSage3 = $Selected -in @('Sage3','Both')
  $code = @"
import torch
import torch.nn.functional as F
import triton
import triton.language as tl

assert torch.cuda.is_available(), "CUDA is not available"

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
assert torch.allclose(z, x + y, rtol=1e-4, atol=1e-4), "Triton JIT result mismatch"
print(f"TRITON_OK {triton.__version__}")
"@
  if ($testSage2) {
    $code += @'

from sageattention import sageattn
q = torch.randn(1, 2, 256, 64, device="cuda", dtype=torch.float16)
k = torch.randn_like(q)
v = torch.randn_like(q)
ref = F.scaled_dot_product_attention(q, k, v, is_causal=False)
out = sageattn(q, k, v, tensor_layout="HND", is_causal=False)
torch.cuda.synchronize()
assert out.shape == ref.shape, "SageAttention 2 output shape mismatch"
assert torch.isfinite(out).all(), "SageAttention 2 produced non-finite values"
cos = F.cosine_similarity(out.float().flatten(), ref.float().flatten(), dim=0).item()
assert cos > 0.98, f"SageAttention 2 differs too much from SDPA (cosine={cos:.6f})"
print(f"SAGE2_OK cosine={cos:.6f}")
'@
  }
  if ($testSage3) {
    $code += @'

from sageattn3 import sageattn3_blackwell
q = torch.randn(1, 2, 256, 64, device="cuda", dtype=torch.float16)
k = torch.randn_like(q)
v = torch.randn_like(q)
ref = F.scaled_dot_product_attention(q, k, v, is_causal=False)
out = sageattn3_blackwell(q.clone(), k.clone(), v.clone(), is_causal=False)
torch.cuda.synchronize()
assert out.shape == ref.shape, "SageAttention 3 output shape mismatch"
assert torch.isfinite(out).all(), "SageAttention 3 produced non-finite values"
cos = F.cosine_similarity(out.float().flatten(), ref.float().flatten(), dim=0).item()
assert cos > 0.90, f"SageAttention 3 FP4 result is implausibly far from SDPA (cosine={cos:.6f})"
print(f"SAGE3_OK cosine={cos:.6f}")
'@
  }
  $code | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Verify-Install([object]$EnvInfo, [object]$Plan) {
  $base = if ($script:BackupDir) { Join-Path $script:BackupDir 'stage' } else { $env:TEMP }
  if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
  $verify = Join-Path $base ("verify_sageattention_{0}.py" -f ([guid]::NewGuid().ToString('N')))
  try {
    Write-VerifyScript $verify $Plan.Backend
    $result = Invoke-Proc $Py @($verify) 300
    foreach ($line in ($result.Out -split '\r?\n')) { if ($line) { Ok $line } }
    $after = Get-EnvironmentInfo
    if ($after.torch -ne $EnvInfo.torch) { throw "Safety check failed: PyTorch changed from $($EnvInfo.torch) to $($after.torch)." }
    Ok 'PyTorch remained unchanged.'
  }
  finally { Remove-Item -LiteralPath $verify -Force -ErrorAction SilentlyContinue }
}

function New-RunnerFile([string]$Name, [string]$Argument) {
  $path = Join-Path $Root $Name
  if (Test-Path $path) { Warn "$Name already exists; it was not overwritten."; return }
  "@echo off`r`n.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build $Argument`r`npause`r`n" |
    Set-Content -LiteralPath $path -Encoding ASCII
  Ok "Created $Name"
}

function Create-Runners([object]$Plan, [object]$Caps) {
  if ($Plan.Backend -in @('Sage2','Both')) {
    if ($Caps.Sage2Cli) { New-RunnerFile 'run_nvidia_gpu_sageattention.bat' '--use-sage-attention' }
    else { Warn 'This ComfyUI build does not expose --use-sage-attention; no Sage2 runner was created.' }
  }
  if ($Plan.Backend -in @('Sage3','Both')) {
    if ($Caps.Sage3Cli) { New-RunnerFile 'run_nvidia_gpu_sageattention3.bat' '--use-sage-attention3' }
    else { Warn 'This ComfyUI build has no global --use-sage-attention3 switch, so no Sage3 runner was created.' }
  }
}

function Show-Sage3Usage([object]$Caps) {
  if ($Caps.Sage3Cli) {
    Info 'SageAttention 3 can be enabled globally by this ComfyUI build with --use-sage-attention3.'
  }
  elseif ($Caps.Sage3Registered) {
    Info 'ComfyUI registers the internal "sage3" backend, but this build has no global SA3 CLI switch.'
    if ($Caps.KJNodes) { Info 'KJNodes detected: its Sage Attention patch node can select sageattn3.' }
    else { Info 'Use a workflow/node that can select the registered sage3 backend; see README for details.' }
  }
  else {
    Warn 'SageAttention 3 is installed and verified, but this ComfyUI build does not expose native sage3 registration. Use a compatible custom node/workflow.'
    if ($Caps.KJNodes) { Info 'KJNodes detected and can provide SageAttention3 selection.' }
  }
  Info 'SA3 smoke testing proves that the kernel works on this system; it does not guarantee optimal quality for every model.'
}

Set-Location $Root
$envInfo = $null
$plan = $null
$staged = $null
try {
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host '  ComfyUI SageAttention Installer' -ForegroundColor Cyan
  Write-Host '  SageAttention 2.2 / 2++ + SageAttention 3' -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
  Info 'PyTorch is read-only. The installer will adapt to your existing ComfyUI Portable environment.'

  Phase 1 'Checking ComfyUI'
  Assert-PortableRoot
  $caps = Get-ComfyCapabilities
  Ok 'ComfyUI Windows Portable layout detected.'

  Phase 2 'Detecting your hardware'
  $envInfo = Get-EnvironmentInfo
  Assert-BaseEnvironment $envInfo
  Show-Environment $envInfo $caps

  Phase 3 'Checking compatible SageAttention versions'
  $sage2Eval = Evaluate-Sage2 $envInfo
  $sage3Eval = Evaluate-Sage3 $envInfo
  Show-BackendStatus 'SageAttention 2.2' $sage2Eval
  Show-BackendStatus 'SageAttention 3' $sage3Eval
  $recommended = Get-Recommendation $envInfo $sage2Eval $sage3Eval
  if (-not $recommended) {
    throw "No compatible backend was found.`nSage2: $($sage2Eval.Reason)`nSage3: $($sage3Eval.Reason)"
  }
  Info "Recommendation: $recommended"

  Phase 4 'Choose what to install'
  $selected = Select-Backend $Backend $recommended $sage2Eval $sage3Eval $envInfo
  if (-not $selected) { Info 'Cancelled. Nothing was changed.'; return }
  Assert-BackendAvailable $selected $sage2Eval $sage3Eval

  $plan = New-Plan $selected $envInfo $sage2Eval $sage3Eval

  Phase 5 'Preparing installation'
  Show-Plan $plan
  $hasChanges = [bool](Get-HasChanges $plan)

  if ($DryRun) {
    Write-Host ''
    Ok 'Dry run complete. No files, logs, backups or packages were changed.'
    return
  }

  if (-not $Yes) {
    $answer = Read-Host 'Proceed with this installation? [Y/n]'
    if ($answer -and $answer -notmatch '^(?i)y(?:es)?$') { Info 'Cancelled. Nothing was changed.'; return }
  }

  Start-Log
  Write-LogLine "Environment: $($envInfo | ConvertTo-Json -Depth 8 -Compress)"
  Write-LogLine "ComfyUI capabilities: $($caps | ConvertTo-Json -Depth 8 -Compress)"
  Write-LogLine "Recommendation: $recommended"
  Write-LogLine "Selected backend: $selected"
  Write-LogLine "Plan: $($plan | ConvertTo-Json -Depth 8 -Compress)"

  if ($hasChanges) {
    Backup-State $envInfo $plan
    $staged = Stage-Files $plan
  }
  else { Ok 'All selected components are already installed at compatible versions.' }

  Phase 6 'Installing'
  if ($hasChanges) {
    $script:MutationStarted = $true
    if ($plan.PythonDev -eq 'INSTALL') {
      Write-Progress -Activity 'Installing' -Status 'Embedded Python developer files' -PercentComplete 15
      Install-PythonDev $staged.PythonDev
    }
    if ($plan.LegacyTriton -eq 'REMOVE') {
      Write-Progress -Activity 'Installing' -Status 'Removing conflicting legacy triton package' -PercentComplete 30
      Remove-Package 'triton'
    }
    if ($plan.Triton -eq 'INSTALL') {
      Write-Progress -Activity 'Installing' -Status 'Triton-Windows' -PercentComplete 50
      Install-Wheel $staged.Triton
    }
    if ($plan.Sage2 -eq 'INSTALL') {
      Write-Progress -Activity 'Installing' -Status 'SageAttention 2.2' -PercentComplete 70
      Install-Wheel $staged.Sage2
    }
    if ($plan.Sage3 -eq 'INSTALL') {
      Write-Progress -Activity 'Installing' -Status 'SageAttention 3' -PercentComplete 85
      Install-Wheel $staged.Sage3
    }
    Write-Progress -Activity 'Installing' -Completed
    Ok 'Selected package changes installed.'
  }
  else { Info 'No package changes required.' }

  Phase 7 'Testing GPU acceleration'
  Verify-Install $envInfo $plan
  if ($CreateRunner) {
    try { Create-Runners $plan $caps }
    catch { Warn "Optional runner creation failed: $($_.Exception.Message)" }
  }

  Phase 8 'Done'
  Ok 'Installation completed and GPU verification passed.'
  if ($plan.Backend -in @('Sage3','Both')) { Show-Sage3Usage $caps }
  if ($script:BackupDir) { Info "Backup: $script:BackupDir" }
  if ($script:LogPath) { Info "Log: $script:LogPath" }
}
catch {
  Write-Progress -Activity 'Installing' -Completed -ErrorAction SilentlyContinue
  Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
  Write-LogLine "FATAL $($_.Exception.ToString())"
  if (-not $DryRun -and $script:MutationStarted -and $script:BackupDir -and $envInfo -and $plan) {
    Recover $envInfo $plan
  }
  throw
}
