# Static parity smoke test. This does not execute the installer or mutate Python.
$ErrorActionPreference = 'Stop'
$fixturePath = Join-Path $PSScriptRoot 'resolver_fixtures.json'
$data = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

$triton = @{
  '2.4'='3.1'; '2.5'='3.1'; '2.6'='3.2'; '2.7'='3.3'; '2.8'='3.4'
  '2.9'='3.5'; '2.10'='3.6'; '2.11'='3.6'; '2.12'='3.7'; '2.13'='3.7'; '2.14'='3.8'
}

function Get-Family([string]$CC) {
  if ($CC -in @('8.0','8.6')) { return 'Ampere' }
  if ($CC -eq '8.9') { return 'Ada' }
  if ($CC -eq '9.0') { return 'Hopper' }
  if ($CC -in @('10.0','12.0','12.1')) { return 'Blackwell' }
  return 'Unknown'
}
function Recommend($Row) {
  $family = Get-Family $Row.cc
  if ($family -in @('Ampere','Ada','Hopper')) {
    if ($Row.sage2_available) { return 'Sage2' }
    return $null
  }
  if ($family -eq 'Blackwell') {
    if ($Row.sage2_available -and $Row.sage3_available) { return 'Both' }
    if ($Row.sage3_available) { return 'Sage3' }
    if ($Row.sage2_available) { return 'Sage2' }
  }
  return $null
}

foreach ($row in $data.scenarios) {
  $got = Recommend $row
  if ($got -ne $row.powershell_expected) { throw "Recommendation mismatch: $($row.name): got '$got' expected '$($row.powershell_expected)'" }
  $torchMM = ([regex]::Match([string]$row.torch, '(\d+\.\d+)')).Groups[1].Value
  if ($triton[$torchMM] -ne $row.triton_minor) { throw "Triton mismatch: $($row.name)" }
  if ($row.powershell_expected -ne $row.python_expected) { throw "Cross-installer fixture mismatch: $($row.name)" }
}
Write-Host "Resolver parity fixtures passed: $($data.scenarios.Count) scenarios"
