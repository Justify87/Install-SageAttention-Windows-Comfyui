# Install SageAttention on ComfyUI Windows Portable

A small PowerShell installer for **Triton + SageAttention** on the official **ComfyUI Windows Portable** build.

This is a complete rewrite of the old installer. The new version deliberately does **not** manage your PyTorch stack.

> **Safety rule:** `torch`, `torchvision`, and `torchaudio` are read-only. The installer never installs, removes, upgrades, or downgrades them.

## What it does

The installer follows one simple flow:

**Detect → Resolve → Plan → Backup → Stage → Install → Verify → Recover if needed**

It:

- detects the embedded Python, PyTorch, CUDA, GPU, compute capability, Triton and SageAttention
- checks that ComfyUI's embedded Python is not currently running
- selects the Triton minor release from the maintained `triton-windows` PyTorch compatibility matrix
- keeps an already compatible Triton installation
- installs `triton-windows` from **PyPI**
- adds the embedded-Python `include/` and `libs/` folders only when they are missing
- looks for an exact SageAttention wheel from **Comfy-Org/wheels** first
- falls back to **wildminder/AI-windows-whl** only when Comfy-Org has no exact wheel
- supports CPython ABI3 SageAttention wheels
- stages all required downloads before package changes begin
- creates a small timestamped backup
- runs a real Triton GPU kernel and a real SageAttention GPU smoke test
- compares the SageAttention result with PyTorch SDPA
- automatically restores the previous Triton/SageAttention state if installation or verification fails
- can optionally create `run_nvidia_gpu_sageattention.bat`

## What it does NOT do

It does **not**:

- change PyTorch
- change torchvision or torchaudio
- install a CUDA Toolkit
- compile SageAttention from source
- install xformers, FlashAttention, NATTEN, bitsandbytes, or other extras
- modify `python_embeded\Lib`
- overwrite an existing SageAttention runner
- guess unsupported CUDA minor-version substitutions

If no exact supported SageAttention wheel can be resolved, the installer stops without changing the environment.

## Requirements

- Windows 10/11 x64
- PowerShell 7+
- official ComfyUI Windows Portable layout:
  - `ComfyUI\main.py`
  - `python_embeded\python.exe`
- NVIDIA GPU supported by current SageAttention 2.x upstream kernels
- working CUDA-enabled PyTorch already included in ComfyUI Portable
- Microsoft Visual C++ 2015-2022 Redistributable (x64)
- internet access

Close ComfyUI before running the installer.

## Installation

Copy `Install-SageAttention.ps1` into the **ComfyUI Windows Portable root folder**.

Example:

```text
ComfyUI_windows_portable\
├─ ComfyUI\
├─ python_embeded\
└─ Install-SageAttention.ps1
```

Open PowerShell 7 in that folder and first run a dry run:

```powershell
.\Install-SageAttention.ps1 -DryRun
```

If the plan looks correct:

```powershell
.\Install-SageAttention.ps1
```

To also create a separate SageAttention launcher:

```powershell
.\Install-SageAttention.ps1 -CreateRunner
```

The launcher starts ComfyUI with:

```text
--use-sage-attention
```

SageAttention is optional optimization. Some models/workflows can behave better with ComfyUI's default attention, so the installer does not force the flag into your existing launch files.

## Dry run

`-DryRun` performs the real environment detection and online resolver checks, then prints the exact plan.

It does **not**:

- create logs
- create backups
- download wheels to disk
- install/uninstall packages
- alter Python developer files
- create a runner

Example:

```powershell
.\Install-SageAttention.ps1 -DryRun
```

## Sources and priority

### Triton

Triton is resolved from the maintained Windows project:

- `triton-lang/triton-windows`
- `triton-windows` on PyPI

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

The installer pins the matching Triton **minor** range rather than blindly installing the newest release.

### SageAttention

Resolution order:

1. **Comfy-Org/wheels** — preferred first-party ComfyUI ecosystem source
2. **wildminder/AI-windows-whl** — community fallback
3. **thu-ml/SageAttention** — upstream requirements/hardware behavior used as Ground Truth, not an automatic source-build fallback

The community fallback is clearly shown in the console and log.

The fallback resolver reads the current `wheels.json` range fields for:

- PyTorch
- Python
- CUDA

It also understands ABI3 wheel tags.

No undocumented CUDA alias is applied. For example, a CUDA 13.2 environment is not silently given a CUDA 13.0 wheel.

## Backup and recovery

Before the first package mutation the installer creates:

```text
backup\Install-SageAttention-YYYYMMDD-HHMMSS\
```

It contains:

- detected environment
- install plan
- `pip freeze`
- copies of existing SageAttention/Triton package files
- copies of `python_embeded\include` / `libs` only when those folders must be changed
- staged download files

If installation or GPU verification fails, the installer removes only the Triton/SageAttention changes it made and restores the previous snapshot.

PyTorch is never part of recovery because PyTorch is never changed.

## Logs

Normal installs create:

```text
logs\Install-SageAttention-YYYYMMDD-HHMMSS.log
```

Dry runs do not write a log.

## Verification

A successful install requires more than an import.

The script verifies:

1. CUDA is available through the existing PyTorch
2. Triton imports
3. a tiny Triton JIT GPU kernel executes correctly
4. SageAttention imports
5. a tiny SageAttention CUDA attention operation executes
6. output contains finite values
7. output has high cosine similarity to PyTorch SDPA
8. the PyTorch version is exactly unchanged after installation

Only then is the installation reported as successful.

## Troubleshooting

### ComfyUI is running

Close ComfyUI completely and run the installer again. The installer refuses to modify the embedded Python while it is in use.

### No matching SageAttention wheel

Your Python/PyTorch/CUDA combination is not currently covered by either Comfy-Org or the configured community fallback.

The installer intentionally stops rather than changing Torch or guessing a CUDA wheel.

Try again after the wheel repositories have added support.

### Missing `include` / `libs`

Embedded Python needs developer headers for Triton. The installer follows the current `triton-windows` documentation and resolves the matching `python_X.Y.Z_include_libs.zip` asset referenced there.

It never modifies `python_embeded\Lib`.

If no documented asset exists for your Python minor version, the installer stops safely.

### Visual C++ runtime not detected

Install the current **Microsoft Visual C++ Redistributable for Visual Studio 2015-2022 (x64)**, then retry.

### Installation failed

Check the timestamped log under `logs\`.

If mutation had already started, the script automatically attempts recovery and preserves the backup folder for manual inspection.

## Why Torch is read-only

ComfyUI Portable already ships a selected Python/PyTorch/CUDA stack. Replacing that stack just to install SageAttention can break ComfyUI, custom nodes, and compiled extensions.

This installer therefore adapts **Triton and SageAttention to ComfyUI**, never the other way around.

## Upstream projects

- ComfyUI: https://github.com/Comfy-Org/ComfyUI
- Comfy wheels: https://github.com/Comfy-Org/wheels
- Triton Windows: https://github.com/triton-lang/triton-windows
- SageAttention: https://github.com/thu-ml/SageAttention
- Community Windows wheel index: https://github.com/wildminder/AI-windows-whl

## License

MIT — see [LICENSE](LICENSE).
