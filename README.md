# Install SageAttention on ComfyUI Windows Portable

A beginner-friendly PowerShell installer for **SageAttention 2.2 / SageAttention2++** and **SageAttention 3** on the official **ComfyUI Windows Portable** build.

> **Safety rule:** `torch`, `torchvision`, and `torchaudio` are read-only. This installer never installs, removes, upgrades, or downgrades them.

The installer adapts SageAttention to the PyTorch/CUDA stack already shipped with ComfyUI Portable — never the other way around.

## What this installer does

The flow is intentionally conservative:

**Detect → Evaluate Backends → Recommend → Select → Resolve → Plan → Backup → Stage → Install → Verify → Recover if needed**

It can install:

- **SageAttention 2.2 / SageAttention2++** (`sageattention`)
- **SageAttention 3** (`sageattn3`)
- **Both**, when the current machine supports both backends

It also:

- detects Python, PyTorch, CUDA, GPU model, VRAM and compute capability
- classifies Ampere / Ada / Hopper / Blackwell from compute capability
- checks the local ComfyUI files for native SageAttention 3 support
- detects KJNodes and provides a usage hint if present
- recommends the best install mode for the current machine
- still lets the user override the recommendation when another supported option is available
- resolves the correct `triton-windows` minor version from the maintained PyTorch↔Triton matrix
- keeps compatible existing components instead of reinstalling them
- stages every required download before package mutation begins
- prefers official Comfy-Org wheels
- uses `wildminder/AI-windows-whl` only as an explicit community fallback
- creates a targeted backup before changes
- verifies Triton and the selected SageAttention backend(s) with real GPU kernels
- automatically attempts rollback if installation or verification fails

## SageAttention 2 vs SageAttention 3

SageAttention 3 is **not simply a replacement for SageAttention 2**.

| | SageAttention 2.2 / 2++ | SageAttention 3 |
|---|---|---|
| Package | `sageattention` | `sageattn3` |
| Main role | General high-performance backend | Blackwell FP4 backend |
| Accuracy | More conservative | More aggressive quantization |
| GPUs | Ampere, Ada, Hopper, supported Blackwell | Current upstream runtime is Blackwell-specific |
| Best default | Non-Blackwell GPUs | Blackwell when a verified wheel exists |
| Can both be installed? | Yes | Yes |

The SageAttention authors still recommend SageAttention 2 for precision-sensitive use cases. Some workloads can benefit from using SA2 and SA3 selectively.

### Important: SageAttention 3 currently uses Triton too

The current upstream `sageattn3/api.py` imports Triton and uses a Triton JIT kernel during preprocessing. Therefore the current installer also prepares a compatible `triton-windows` installation for **Sage3-only** installs.

This is intentional and based on the current upstream implementation, not an assumption.

## Automatic recommendation

The installer evaluates hardware **and** actual wheel availability before recommending a backend.

Typical behavior:

- **Ampere / Ada / Hopper** → recommend `Sage2`
- **Blackwell + only SA2 available** → recommend `Sage2`
- **Blackwell + only SA3 available** → recommend `Sage3`
- **Blackwell + both available** → recommend `Both`
- **no compatible wheel** → stop safely without changing anything

A recommendation is never treated as permission to install an unsupported wheel.

## Supported GPU logic

The installer uses `torch.cuda.get_device_capability()` rather than guessing from the GPU name.

Current SageAttention 2 upstream architectures considered by the installer:

- `sm_80`, `sm_86` — Ampere
- `sm_89` — Ada
- `sm_90` — Hopper
- `sm_100`, `sm_120`, `sm_121` — Blackwell, subject to actual wheel coverage

Current SageAttention 3 handling is more conservative:

- the current upstream runtime code explicitly accepts `sm_120` / `sm_121`
- the installer additionally requires that the selected prebuilt wheel source proves or safely covers the detected architecture
- the current Comfy-Org Windows build matrix covers `sm_120`, but does not currently prove `sm_121` coverage
- community SA3 fallback is currently restricted to architecture coverage that can be safely established

This means a GPU can be theoretically supported by upstream source code but still be rejected by this installer when no trustworthy matching **prebuilt Windows wheel** is available.

No source builds are performed automatically.

## Requirements

- Windows 10/11 x64
- PowerShell 7+
- official ComfyUI Windows Portable layout:
  - `ComfyUI\main.py`
  - `python_embeded\python.exe`
- NVIDIA GPU with CUDA-enabled PyTorch
- Microsoft Visual C++ 2015-2022 Redistributable (x64)
- internet access

Close ComfyUI before running the installer.

## Installation

Put `Install-SageAttention.ps1` in the **ComfyUI Windows Portable root folder**:

```text
ComfyUI_windows_portable\
├─ ComfyUI\
├─ python_embeded\
└─ Install-SageAttention.ps1
```

Run it from PowerShell 7:

```powershell
.\Install-SageAttention.ps1
```

The installer will:

1. inspect the machine
2. show which SageAttention backends are supported
3. recommend one option
4. let you choose
5. show the complete installation plan
6. ask before changing anything

## Interactive mode

Running without `-Backend` opens the guided menu:

```powershell
.\Install-SageAttention.ps1
```

Example on a compatible Blackwell system:

```text
[OK] SageAttention 2.2  supported
[OK] SageAttention 3    supported

Recommendation: Both

[1] Both                 Sage2 compatibility + Sage3 Blackwell speed  <- Recommended
[2] SageAttention 3      Blackwell FP4 backend
[3] SageAttention 2.2    Compatibility / accuracy
[4] Cancel
```

Unsupported choices are not offered as installable options, and the reason is shown.

## Automatic / scripted mode

Use the recommendation automatically:

```powershell
.\Install-SageAttention.ps1 -Backend Auto
```

Select a backend explicitly:

```powershell
.\Install-SageAttention.ps1 -Backend Sage2
.\Install-SageAttention.ps1 -Backend Sage3
.\Install-SageAttention.ps1 -Backend Both
```

Skip the final confirmation prompt:

```powershell
.\Install-SageAttention.ps1 -Backend Auto -Yes
```

An explicitly requested unsupported backend causes a safe error. The installer does not silently substitute another backend.

## Dry run

Recommended before the first install:

```powershell
.\Install-SageAttention.ps1 -Backend Auto -DryRun
```

`-DryRun` performs the same detection, compatibility checks, recommendation and wheel resolution as a real run.

It does **not**:

- create logs
- create backups
- download wheels to disk
- install/uninstall packages
- alter Python developer files
- create runner files

## Installation sources

### Triton

The installer uses:

- `triton-lang/triton-windows` as the compatibility ground truth
- `triton-windows` from official PyPI for installation

Current matrix used by the installer:

| PyTorch | Triton |
|---|---|
| 2.4–2.5 | 3.1 |
| 2.6 | 3.2 |
| 2.7 | 3.3 |
| 2.8 | 3.4 |
| 2.9 | 3.5 |
| 2.10–2.11 | 3.6 |
| 2.12–2.13 | 3.7 |
| 2.14 | 3.8 |

The matching Triton **minor range** is pinned. The newest Triton is never installed blindly.

### SageAttention 2

Priority:

1. **Comfy-Org/wheels**
2. **wildminder/AI-windows-whl** only when the official source has no compatible wheel
3. **thu-ml/SageAttention** as upstream requirements/hardware ground truth

### SageAttention 3

Priority:

1. **Comfy-Org/wheels / `sageattn3`**
2. **wildminder/AI-windows-whl / `sageattn3`** only when the official source has no compatible wheel
3. **thu-ml/SageAttention / `sageattention3_blackwell`** as upstream requirements/runtime ground truth

The community fallback is always displayed explicitly before installation.

The Wildminder resolver reads its current structured `wheels.json` fields for:

- PyTorch range
- Python range
- CUDA range
- wheel URL

Wheel filename tags are also checked. The installer does not invent CUDA minor aliases.

## Why the installer checks the Comfy-Org build specification

A wheel filename proves Python/Torch/CUDA compatibility, but compiled CUDA architecture coverage may differ between build combinations.

The installer therefore also checks the current Comfy-Org package build specification before accepting an official wheel for the detected GPU architecture.

This is particularly important for Blackwell.

## Embedded Python `include` / `libs`

Current `triton-windows` documentation still requires embedded Python installations such as ComfyUI Portable to provide:

```text
python_embeded\include
python_embeded\libs
```

The installer adds them only when missing and only from the documented Python developer archive source.

It never modifies:

```text
python_embeded\Lib
```

## Backup and recovery

Before the first mutation the installer creates:

```text
backup\Install-SageAttention-YYYYMMDD-HHMMSS\
```

It contains:

- `environment.json`
- `plan.json`
- `pip-freeze.txt`
- `pip show -f` manifests for managed packages that existed before the run
- targeted copies of package files that may be changed
- Python `include/libs` backup when those folders must be changed
- all newly staged wheels/downloads

`Both` is treated as one transaction.

If a later installation step or GPU verification fails, the installer attempts to restore the state from before the run, including components that had already installed successfully earlier in that same run.

PyTorch is not part of recovery because PyTorch is never changed.

## Logs

Normal installs create a timestamped log:

```text
logs\Install-SageAttention-YYYYMMDD-HHMMSS.log
```

The terminal output stays compact, while the log includes command output, resolver decisions, source URLs, hashes, verification and recovery details.

Dry runs do not write a log.

## Verification

A successful install requires real GPU execution.

### Shared Triton test

The installer:

- imports Triton
- JIT-compiles a small Triton kernel
- executes it on the GPU
- validates its numerical result

### SageAttention 2 test

The installer:

- imports `sageattention`
- calls `sageattn()` on CUDA FP16 tensors
- checks shape and finite values
- compares output to PyTorch SDPA with a strict cosine-similarity sanity threshold

### SageAttention 3 test

The installer:

- imports `sageattn3_blackwell`
- executes the actual SA3 FP4 path on Blackwell
- uses a sequence length/head dimension that exercises the real kernel
- synchronizes CUDA
- checks output shape and finite values
- compares against PyTorch SDPA using a deliberately more tolerant FP4 sanity threshold

The SA3 smoke test proves the kernel works on the machine. It **does not** guarantee that SA3 is the best-quality backend for every model.

After all tests, the script verifies again that the PyTorch version is unchanged.

## How to use SageAttention 2

ComfyUI currently provides the standard global flag:

```text
--use-sage-attention
```

Optional runner creation:

```powershell
.\Install-SageAttention.ps1 -Backend Sage2 -CreateRunner
```

When supported by the installed ComfyUI build this creates:

```text
run_nvidia_gpu_sageattention.bat
```

Existing runner files are never overwritten.

## How to use SageAttention 3

Current ComfyUI source can import `sageattn3` and register an internal attention backend named:

```text
sage3
```

However, at the time of writing, the normal ComfyUI CLI still does **not** expose a standard global:

```text
--use-sage-attention3
```

The installer checks the **local ComfyUI files at runtime** instead of assuming this will always remain true.

If a future ComfyUI version adds that CLI option, `-CreateRunner` can create a corresponding runner automatically.

If the local build has no SA3 CLI flag, the installer does not invent one.

### KJNodes

If `ComfyUI-KJNodes` is already installed, the installer detects it and points out that KJNodes provides SageAttention3-capable attention patch modes.

The installer never installs KJNodes or any other custom node automatically.

## What this installer does NOT do

It does **not**:

- change PyTorch
- change torchvision or torchaudio
- install a CUDA Toolkit
- compile SageAttention from source
- install FlashAttention
- install xformers
- install NATTEN
- install bitsandbytes
- install custom nodes
- overwrite existing runner files
- guess unsupported CUDA substitutions
- silently install a different SageAttention backend than the one selected

## Troubleshooting

### ComfyUI is running

Close ComfyUI completely. The installer refuses to modify the embedded Python while that exact `python_embeded\python.exe` is active.

### SageAttention 3 is unavailable on a Blackwell GPU

Possible reasons include:

- the current upstream SA3 runtime does not support that exact compute capability
- no official Comfy-Org wheel covers the detected architecture
- the community index has a Python/Torch/CUDA wheel but does not provide enough architecture evidence for the installer to use it safely

The installer intentionally prefers a safe stop over an unverified compiled wheel.

### No matching wheel

The detected Python/PyTorch/CUDA combination is not covered by the configured official or community wheel sources.

Torch will not be downgraded or upgraded to make a wheel fit.

### Missing `include` / `libs`

The installer follows current `triton-windows` embedded-Python guidance and looks for the documented matching Python developer archive.

If none exists for the current Python minor version, it stops safely.

### Visual C++ runtime not detected

Install the current **Microsoft Visual C++ Redistributable for Visual Studio 2015-2022 (x64)** and retry.

### Installation failed

Read the timestamped file in `logs\`.

If mutation had already started, the script automatically attempts targeted recovery and preserves the backup directory for inspection.

## Upstream projects

- ComfyUI: https://github.com/Comfy-Org/ComfyUI
- Comfy wheels: https://github.com/Comfy-Org/wheels
- Triton Windows: https://github.com/triton-lang/triton-windows
- SageAttention: https://github.com/thu-ml/SageAttention
- Community Windows wheel index: https://github.com/wildminder/AI-windows-whl
- KJNodes: https://github.com/kijai/ComfyUI-KJNodes

## License

MIT — see [LICENSE](LICENSE).
