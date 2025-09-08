# Triton & SageAttention Installer for ComfyUI (PowerShell 7)

This repo contains a **purely vibe-coded** single PowerShell script that installs **Triton** and **SageAttention** for the **ComfyUI Windows portable** build. It detects your environment, installs a matching CUDA build of PyTorch (or uses the one you already have), fetches the correct SageAttention wheel from the community wheel index, and—when needed—adds the **Python `include/` and `libs/`** folders required by Triton on Python 3.13.

---

## ✨ What the script does

* **Preflight**: Prints your Python version/CP tag, Torch version, CUDA runtime, and GPU/driver (via `nvidia-smi`).
* **Torch auto-install**: If Torch is missing, installs it automatically (prefers CUDA builds; CPU fallback only when requested—SageAttention needs CUDA).
* **Torch-first mode**: Optionally force a specific Torch + CUDA combo (e.g., `torch==2.8.0` + `cu128`).
* **Triton**: Installs `triton-windows` and (on Python 3.13) downloads & places **only** the `include/` and `libs/` folders into `python_embeded/`.
  *Caution: It **never** touches `Lib/`.*
* **SageAttention**: Picks a compatible wheel for **SageAttention 2.2 (SageAttention2++)** from (https://github.com/wildminder/AI-windows-whl) by parsing its README → JSON, with fallbacks:

  * CUDA minor fallback (e.g., 12.9 → 12.8)
  * Optional ABI3 fallback (when Python column is missing)
* **Optional extras** (if you opt in): `FlashAttention`, `NATTEN`, `xformers`, `bitsandbytes`
* **Post-install checks**: Verifies imports for `torch` and `sageattention`, prints CUDA availability.
* **Quality of life**: Creates runners, saves an environment snapshot and the parsed README JSON.

---

## 🧰 Requirements

* **Windows 10/11, 64-bit**
* **PowerShell 7+**
* **NVIDIA GPU** with a working **NVIDIA driver** (`nvidia-smi` should run)
* **ComfyUI Windows portable** root (this script must run from that folder), e.g.:

  ```
  .\ComfyUI\main.py
  .\python_embeded\python.exe
  ```
* Internet access (to download wheels and the AI-windows-whl README)

> **Note:** `nvcc` (CUDA Toolkit) is **optional**. The script checks for it only to inform you; it’s not required to run ComfyUI.

---

## 📦 Files the script may create

* `.\logs\Install-SageAttention-*.log` (transcript)
* `.\logs\requirements.before.txt` and `.\logs\requirements.after.txt`
* `.\aiwheels_tables.json` (parsed tables from AI-windows-whl README)
* `.\run_nvidia_gpu_sageattention.bat` and/or `.\Run-ComfyUI-Sage.ps1` (runners)
* `.\python_embeded\include\` and `.\python_embeded\libs\` (for Triton on Python 3.13)

---

## 🚀 Quick start

1. Place `Install-SageAttention.ps1` into your **ComfyUI portable root** (same folder as `python_embeded` and `ComfyUI`).
2. Open **PowerShell 7** in that folder.
3. Run:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Install-SageAttention.ps1 -CreateBatRunner
   ```
4. After success, launch ComfyUI with SageAttention:

   ```bat
   .\run_nvidia_gpu_sageattention.bat
   ```

   or

   ```powershell
   .\python_embeded\python.exe -s .\ComfyUI\main.py --windows-standalone-build --use-sage-attention
   ```

---

## 🔧 Common options

| Category         | Parameter                                                            | What it does                                                                                                         |
| ---------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Execution        | `-DryRun`                                                            | Show what would happen, don’t change anything.                                                                       |
| Output           | `-DebugLog`                                                          | Print detailed timings/stdout/stderr snippets.                                                                       |
| Torch (force)    | `-TorchVersion 2.8.0 -CudaTag cu128`                                 | Install exactly this Torch + CUDA before SageAttention.                                                              |
| Torch (auto)     | *(default)*                                                          | If Torch is missing, tries CUDA builds that fit your GPU/driver; CPU only as last resort (SageAttention needs CUDA). |
| Pip control      | `-PipIndexUrl` / `-PipExtraIndexUrl`                                 | Point pip at custom indexes, e.g., PyTorch wheels.                                                                   |
| Caching          | `-NoCache`                                                           | Use `--no-cache-dir` for pip installs.                                                                               |
| Triton dev files | `-SkipTritonPyDev`, `-ForceTritonPyDev`, `-TritonPyDevZipUrl <url>`  | Control the Python 3.13 headers/libs step.                                                                           |
| Extras           | `-AutoFetchFromAIWheels -InstallFlashAttention -InstallXFormers ...` | Install extra packages from the same wheel index.                                                                    |
| Runners          | `-CreateBatRunner`, `-CreatePsRunner`                                | Create handy launchers for ComfyUI + SageAttention.                                                                  |

---

## 🧪 Examples

Force a specific Torch + CUDA, then install SageAttention 2.2:

```powershell
.\Install-SageAttention.ps1 -TorchVersion 2.8.0 -CudaTag cu128 -CreateBatRunner
```

Let the script auto-detect Torch (prefer CUDA), install Triton & SageAttention, and create runners:

```powershell
.\Install-SageAttention.ps1 -CreateBatRunner -CreatePsRunner
```

Verbose diagnostics (network issues? pip errors?):

```powershell
.\Install-SageAttention.ps1 -DebugLog
```

Use the official PyTorch extra index explicitly (when forcing versions):

```powershell
.\Install-SageAttention.ps1 -TorchVersion 2.8.0 -CudaTag cu129 -PipExtraIndexUrl https://download.pytorch.org/whl/cu129
```

Install extras from the wheel index too:

```powershell
.\Install-SageAttention.ps1 -AutoFetchFromAIWheels -InstallFlashAttention -InstallXFormers
```

Dry run (no changes):

```powershell
.\Install-SageAttention.ps1 -DryRun
```

---

## 🖥️ Sample output (condensed)

```
▶ Preflight
  ✓ Python: 3.13.6  (cp313)
  ✓ Torch: 2.8.0+cu129 (CUDA 12.9, available=True)
  • CUDA Toolkit (nvcc): not found
  ✓ GPU/Driver: NVIDIA GeForce RTX 4060 Ti, 551.xx

▶ Triton prerequisites
  ✓ Triton prerequisite: installed include/ and libs/ into python_embeded (never touched 'Lib').

▶ Install plan
  • Installing Triton …
  ✓ Triton ready.

▶ SageAttention
  • Selecting a compatible wheel (Torch 2.8.0, CUDA cu128, Python 3.13) …
  ✓ Wheel selected: sageattention-2.2.0+cu128torch2.8.0-cp313-cp313-win_amd64.whl
  • Installing SageAttention …
  ✓ SageAttention installed.

▶ Verify
  ✓ torch import OK (2.8.0+cu129)
  ✓ sageattention import OK (2.2.0)
  • CUDA runtime: 12.9, available: True

▶ Done
  ✓ Installation finished.
  Start ComfyUI with SageAttention:
    .\run_nvidia_gpu_sageattention.bat
```

---

## 📝 Notes on Python 3.13 (Triton)

Triton’s Windows wheels expect the Python **developer files** to exist alongside the embedded interpreter.
The script **automatically** downloads a ZIP that contains **two folders**:

* `include/`
* `libs/`

It copies them into `python_embeded\`.
**Do not** confuse `libs/` with `Lib/` — the script never touches `Lib/`.

You can override the download URL with `-TritonPyDevZipUrl`.

---

## 🧯 Troubleshooting

**SageAttention requires a CUDA build of Torch**

* If you see *“Installed Torch build is CPU-only”*, reinstall with a CUDA tag:

  ```powershell
  .\Install-SageAttention.ps1 -TorchVersion 2.8.0 -CudaTag cu128
  ```

**Wheel not found for your combo**

* Try allowing ABI3 fallback:

  ```powershell
  .\Install-SageAttention.ps1 -AllowAbi3Fallback
  ```
* Or adjust your Torch/CUDA pair to a commonly available one (e.g., `2.8.0 + cu128`).

**Pip cannot connect / corporate networks**

* Set `-PipIndexUrl` / `-PipExtraIndexUrl` to mirrors you can access.
* Configure proxy env vars if needed: `HTTP_PROXY`, `HTTPS_PROXY`.

**Execution policy blocks the script**

* Launch with:

  ```powershell
  pwsh -ExecutionPolicy Bypass -File .\Install-SageAttention.ps1
  ```

**`nvcc` not found**

* That’s OK; only the driver and CUDA runtime within the Torch wheel are needed. `nvcc` is optional.

---

## 🔍 How it selects the right SageAttention wheel

1. Downloads the **AI-windows-whl** README.
2. Parses all Markdown tables → JSON.
3. Searches **SageAttention 2.2** tables first; then the whole SageAttention section.
4. Matches on:

   * **Torch** (exact or same major.minor),
   * **CUDA** (e.g., 12.9 or fallback to 12.8),
   * **Python** (major.minor; can be relaxed with ABI3 fallback).
5. Installs the selected wheel via pip.

A copy of the parsed tables is saved as `aiwheels_tables.json` for transparency.

---

## 🙌 Credits

* Community wheel index: **wildminder/AI-windows-whl**
* Windows wheels: **woct0rdho** (SageAttention, Triton Windows)
* PyTorch, Triton, and SageAttention maintainers & contributors
* ComfyUI project & community

---

## 🛡️ License

This repository is released under the **MIT License**. See [LICENSE](./LICENSE) for details.
