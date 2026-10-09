# Install SageAttention on ComfyUI Windows Portable

A beginner-friendly installer for **SageAttention 2.2 / SageAttention2++** and **SageAttention 3** on the official **ComfyUI Windows Portable** build.

Two installer frontends are provided:

- **Recommended for most users (Beta): Python installer** — uses the `python_embeded\python.exe` already included with ComfyUI Portable. No separate Python or PowerShell 7 installation is required.
- **Alternative: PowerShell installer** — the existing PowerShell 7 implementation remains supported.

> **Safety rule:** `torch`, `torchvision`, and `torchaudio` are read-only. Neither installer installs, removes, upgrades, or downgrades them.

Both installers adapt SageAttention to the PyTorch/CUDA stack already shipped with ComfyUI Portable — never the other way around — and follow the same conservative flow:

**Detect → Evaluate Backends → Recommend → Select → Resolve → Plan → Backup → Stage → Install → Verify → Commit or Recover**

## Which installer should I use?

### Python installer — recommended for most users (Beta)

Use this if you want the simplest start on ComfyUI Windows Portable.

Double-click:

```text
Install-SageAttention-Python.bat
```

The launcher only starts the Python application. It contains no resolver or installation logic.

Equivalent terminal command from the ComfyUI Portable root:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py
```

The Python version is currently marked **Beta** because its resolver/security logic has static and unit-test coverage, but it still needs broader real-world Windows/NVIDIA testing across the supported GPU/Python/PyTorch/CUDA combinations.

### PowerShell installer — alternative

The existing installer remains available and is not replaced:

```powershell
.\Install-SageAttention.ps1
```

It requires **PowerShell 7+**.

## What can be installed?

- **SageAttention 2.2 / SageAttention2++** (`sageattention`)
- **SageAttention 3** (`sageattn3`)
- **Both**, when the current system has compatible wheels for both backends

SageAttention 3 is treated as a separate backend, not as a version upgrade of SageAttention 2.

| | SageAttention 2.2 / 2++ | SageAttention 3 |
|---|---|---|
| Package | `sageattention` | `sageattn3` |
| Main role | General high-performance backend | Blackwell FP4 backend |
| Typical default | Ampere / Ada / Hopper | Blackwell when a compatible wheel exists |
| Quality profile | More conservative | More aggressive FP4 quantization |
| Can both be installed? | Yes | Yes |

On Blackwell, SageAttention 3 can be faster. SageAttention 2 can still be the more conservative choice for model compatibility and output quality, so the installer recommends `Both` when both are actually available.

## Quick start — Python

Place these files in the **ComfyUI Windows Portable root folder**:

```text
ComfyUI_windows_portable\
├─ ComfyUI\
├─ python_embeded\
├─ Install-SageAttention.py
└─ Install-SageAttention-Python.bat
```

Close ComfyUI, then double-click:

```text
Install-SageAttention-Python.bat
```

The guided installer shows phases such as:

```text
Checking ComfyUI
Detecting your hardware
Checking compatible SageAttention versions
Choose what to install
Preparing installation
Installing
Testing GPU acceleration
Done
```

It also shows a compact environment summary, for example:

```text
GPU             NVIDIA GeForce RTX 5090
Architecture    Blackwell (sm_120)
Python          3.13.x
PyTorch         2.x.x + CUDA 12.x  [READ-ONLY]
```

Then it reports whether SageAttention 2 and SageAttention 3 are available, explains the recommendation, and lets you choose any compatible option.

## Python CLI

Guided mode:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py
```

Automatic recommendation:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py --backend auto
```

Select explicitly:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py --backend sage2
python_embeded\python.exe -S -B Install-SageAttention.py --backend sage3
python_embeded\python.exe -S -B Install-SageAttention.py --backend both
```

Skip the final confirmation prompt:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py --backend auto --yes
```

Create supported ComfyUI runner files after a successful install:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py --backend auto --create-runner
```

An explicitly requested unsupported backend causes a safe error. The installer does not silently substitute a different backend.

## Python dry run

Recommended before the first real installation:

```bat
python_embeded\python.exe -S -B Install-SageAttention.py --backend auto --dry-run
```

Dry run uses the same hardware evaluation, wheel resolver, recommendation engine and plan builder as a real run, but it does **not**:

- create logs
- create backups
- download files to disk
- install or uninstall packages
- alter Python developer files
- create runner files
- create `__pycache__` / `.pyc` files

Resolver metadata may still be downloaded into memory so that the plan reflects the current upstream wheel availability.

## Why the Python main process is deliberately minimal

The Python installer is launched with:

```text
python_embeded\python.exe -S -B Install-SageAttention.py
```

Its long-lived main process uses only the Python standard library. It does **not** import:

- `torch`
- `triton`
- `sageattention`
- `sageattn3`

or other native packages that may be replaced during installation.

Environment/GPU checks and verification run in short-lived child processes using the **same** `python_embeded\python.exe`. Those child processes use normal ComfyUI site-packages while disabling user-site packages and bytecode writes. `pip` is also always invoked through that exact embedded interpreter.

This avoids keeping Torch/Triton/SageAttention DLLs loaded in the installer process while files are being changed.

## Requirements

For both installers:

- Windows 10/11 x64
- official ComfyUI Windows Portable structure:
  - `ComfyUI\main.py`
  - `python_embeded\python.exe`
- NVIDIA GPU with CUDA-enabled PyTorch
- Microsoft Visual C++ 2015-2022 Redistributable (x64)
- internet access for resolver metadata and required wheels
- ComfyUI must be closed during a real installation

Additional PowerShell requirement:

- PowerShell 7+

The Python installer does **not** use system Python, Conda, a virtual environment, or install another Python runtime.

## Running-ComfyUI safety check

The Python installer enumerates Windows processes through Win32 APIs using `ctypes`; it does not require `psutil`.

It checks for additional `python.exe` / `pythonw.exe` processes whose executable path is the target ComfyUI `python_embeded\python.exe`.

The installer explicitly excludes its **own PID**, so launching the Python installer with the embedded interpreter does not make it falsely detect itself as ComfyUI. If process enumeration cannot be performed safely, the installer fails closed rather than guessing.

## Installation sources and resolver priority

Both installers use the same source policy.

### Triton

Compatibility ground truth:

- `triton-lang/triton-windows`

Installation package:

- `triton-windows` from official PyPI only

Current PyTorch ↔ Triton minor matrix used by the installers:

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

The matching Triton minor range is pinned. The newest Triton is never installed blindly.

The legacy package named `triton` is treated as a conflict because it can overlap the same import tree. When legacy Triton must be removed, the compatible `triton-windows` package is reinstalled so shared files cannot remain incomplete.

### SageAttention 2

Priority:

1. `Comfy-Org/wheels`
2. `wildminder/AI-windows-whl` as an explicit community fallback
3. `thu-ml/SageAttention` as upstream runtime/hardware requirements ground truth

Only SageAttention 2.2 / SageAttention2++ wheels are selected.

### SageAttention 3

Priority:

1. `Comfy-Org/wheels` / `sageattn3`
2. `wildminder/AI-windows-whl` / `sageattn3` as an explicit community fallback
3. `thu-ml/SageAttention/sageattention3_blackwell` as upstream runtime/hardware ground truth

The current SageAttention 3 implementation still uses Triton during preprocessing, so Sage3-only plans also resolve a compatible `triton-windows` path.

Community fallback is always displayed in the installation plan before mutation.

No source builds are performed automatically, and no additional unconfigured third-party wheel sources are used.

## Resolver rules

The resolver keeps **hardware capability** and **actual wheel availability** as separate checks.

It handles:

- exact CPython wheel tags
- `abi3` for SageAttention 2 where valid
- compressed Torch tags such as `torch210`
- dotted Torch tags such as `torch2.10`
- exact CUDA minor tags such as `cu128`
- current Wildminder range fields for PyTorch, Python and CUDA
- Comfy-Org build-matrix architecture coverage

It does not invent CUDA aliases or assume that a theoretically supported GPU automatically has a compatible Windows wheel.

## Automatic recommendation

Typical behavior after resolver evaluation:

- **Ampere / Ada / Hopper + Sage2 available** → `Sage2`
- **Blackwell + only Sage2 available** → `Sage2`
- **Blackwell + only Sage3 available** → `Sage3`
- **Blackwell + both available** → `Both`
- **no compatible backend** → stop safely

Unsupported choices remain visibly unavailable in the guided menu, including the reason.

## Wheel and download security

The Python implementation uses only standard-library facilities for download and archive validation.

Before installation it checks, as applicable:

- HTTPS only
- allowed source/redirect hosts
- SHA-256 of every staged download, recorded in the log
- wheel is a valid ZIP archive
- no archive path traversal
- wheel filename package/version/platform/Python tags
- `.dist-info/METADATA` package name and version
- `.dist-info/WHEEL` compatibility tags
- exact CUDA/Torch tags required by the resolver

The installer does not invent a custom signing or cryptography scheme.

## Torch safety

`torch`, `torchvision`, and `torchaudio` are absolutely read-only.

The Python installer:

- never targets them with mutating pip commands
- installs resolved wheels with `--no-deps`
- records their versions before mutation
- probes them again after installation/verification
- treats any version change as an installation failure

Torch is not part of rollback because Torch must never be changed in the first place.

## Embedded Python `include` / `libs`

Current Triton-Windows guidance for embedded Python still requires Python developer files in some ComfyUI Portable environments.

The installers add them only when actually missing and required. The matching **Python minor version** must be available from the documented Triton-Windows asset source.

The archive is validated before extraction. Only expected `include` and `libs` content is accepted.

The installers never modify:

```text
python_embeded\Lib
```

## Backup and recovery

Before the first mutation, the Python installer creates a targeted backup under:

```text
backup\Install-SageAttention-Python-YYYYMMDD-HHMMSS-<PID>\
```

It includes:

- environment snapshot
- installation plan
- installed managed-package versions
- `pip freeze`
- `pip show -f` manifests for affected existing packages
- targeted copies of affected package files
- Python `include` / `libs` when they will be changed
- all staged downloads

`Both` is one transaction. If a later install or verification step fails, the entire managed change set is rolled back to the pre-run snapshot.

The recovery code uses filesystem/pip metadata operations and never imports Torch, Triton, SageAttention or SageAttention 3, so recovery remains usable even when one of those packages is broken.

## Verification

A real installation is considered successful only after separate child-process checks.

### Shared checks

- PyTorch import
- CUDA available
- compatible Triton import
- real Triton JIT GPU kernel
- PyTorch / torchvision / torchaudio versions unchanged afterward

### SageAttention 2

- `sageattention` import
- real CUDA `sageattn()` execution with FP16 input
- output shape
- finite values
- sanity comparison against PyTorch SDPA

### SageAttention 3

- `sageattn3` import
- `sageattn3_blackwell` execution on Blackwell
- FP16 and BF16 inputs
- output shape
- finite values
- CUDA synchronization
- deliberately tolerant sanity comparison against PyTorch SDPA appropriate for FP4

A successful SA3 smoke test confirms that the kernel works on that system. It does **not** guarantee that SageAttention 3 is the best-quality backend for every model.

## ComfyUI integration

The installers inspect the **local ComfyUI files** instead of guessing from a version number.

They detect:

- `SAGE_ATTENTION3_IS_AVAILABLE`
- internal backend registration named `sage3`
- standard `--use-sage-attention`
- a future `--use-sage-attention3` only if it actually exists locally
- KJNodes, if already installed

No custom node is installed automatically.

### Runner files

For Sage2, `--create-runner` can create:

```text
run_nvidia_gpu_sageattention.bat
```

but only when the local ComfyUI exposes `--use-sage-attention`.

For Sage3, a separate runner is created only if the local ComfyUI actually exposes a corresponding CLI switch. The installer never invents a nonexistent command-line option.

Existing runner files are never overwritten.

## Logs and errors

Normal Python installs create a log such as:

```text
logs\Install-SageAttention-Python-YYYYMMDD-HHMMSS-<PID>.log
```

The console stays concise. Full subprocess output and Python tracebacks are written to the log when available instead of dumping large tracebacks on normal users.

Example user-facing failure:

```text
Installation could not be completed.

Reason:
  No compatible SageAttention 3 Windows wheel exists for this environment.

Nothing was changed.
```

Dry runs do not create logs.

## PowerShell usage

Guided mode:

```powershell
.\Install-SageAttention.ps1
```

Automatic recommendation:

```powershell
.\Install-SageAttention.ps1 -Backend Auto
```

Explicit backend:

```powershell
.\Install-SageAttention.ps1 -Backend Sage2
.\Install-SageAttention.ps1 -Backend Sage3
.\Install-SageAttention.ps1 -Backend Both
```

Skip confirmation:

```powershell
.\Install-SageAttention.ps1 -Backend Auto -Yes
```

Dry run:

```powershell
.\Install-SageAttention.ps1 -Backend Auto -DryRun
```

Optional runner creation:

```powershell
.\Install-SageAttention.ps1 -Backend Sage2 -CreateRunner
```

## Tests

The Python implementation intentionally uses `unittest`; no third-party test framework is required.

From a normal Python environment used only for static/unit testing:

```text
python -B -m unittest discover -s tests -v
```

Central resolver/recommendation expectations are stored in:

```text
tests\resolver_fixtures.json
```

The same fixtures are also consumed by the non-destructive PowerShell parity smoke test:

```powershell
pwsh -NoProfile -File .\tests\Test-ResolverParity.ps1
```

These tests cover recommendation matrices, Triton mapping, exact/ABI3 wheel tags, exact CUDA matching, compressed/dotted Torch tags, community fallback, legacy Triton, partial preinstallation, process self-exclusion, second embedded-Python detection, dry-run mutation guards, runner no-overwrite behavior, Torch mutation guards and archive traversal checks.

They do **not** pretend to replace real Windows/NVIDIA GPU verification.

## What the installers do NOT do

They do **not**:

- change PyTorch, torchvision or torchaudio
- install a second Python
- create a venv
- use Conda
- install a CUDA Toolkit
- compile SageAttention from source automatically
- install unknown wheel sources
- install custom nodes
- overwrite existing runner files
- guess unsupported CUDA substitutions
- silently install a different SageAttention backend from the selected one

## Troubleshooting

### Another embedded Python process is running

Close ComfyUI completely and retry. The Python installer ignores its own PID but blocks if another `python.exe` / `pythonw.exe` from the same `python_embeded` is still active.

### SageAttention 3 is unavailable on Blackwell

Possible reasons include:

- current upstream runtime support does not include the exact compute capability
- no official Comfy-Org wheel covers the detected Python/PyTorch/CUDA/architecture combination
- the community fallback cannot prove a safe compatible wheel

The installer prefers a safe stop over an unverified compiled wheel.

### No matching wheel

The current Python/PyTorch/CUDA combination is not covered by the configured official/community wheel sources.

Torch will not be upgraded or downgraded to make a wheel fit.

### Missing `include` / `libs`

The installer follows the current Triton-Windows embedded-Python guidance. If no documented archive exists for the current Python minor, it stops safely.

### Installation failed

Read the timestamped file under `logs\`. If mutation had already started, the installer attempts targeted recovery and preserves the backup directory for inspection.

## Upstream projects

- ComfyUI: https://github.com/Comfy-Org/ComfyUI
- Comfy wheels: https://github.com/Comfy-Org/wheels
- Triton Windows: https://github.com/triton-lang/triton-windows
- SageAttention: https://github.com/thu-ml/SageAttention
- Community Windows wheel index: https://github.com/wildminder/AI-windows-whl
- KJNodes: https://github.com/kijai/ComfyUI-KJNodes

## License

MIT — see [LICENSE](LICENSE).
