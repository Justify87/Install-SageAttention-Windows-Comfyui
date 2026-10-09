#!/usr/bin/env python3
"""Safe SageAttention 2/3 installer for ComfyUI Windows Portable.

Architecture:
Detect -> Evaluate Backends -> Recommend -> User Selects -> Resolve -> Plan ->
Backup -> Stage -> Execute -> Verify -> Commit or Recover

The installer main process intentionally uses only the Python standard library and
never imports torch, triton, sageattention, sageattn3, or other native packages.
All native-package and GPU checks run in short-lived child processes using the
same ComfyUI ``python_embeded\\python.exe`` interpreter.
"""
from __future__ import annotations

import argparse
import ctypes
import dataclasses
from dataclasses import dataclass, field
import email.parser
import hashlib
from html.parser import HTMLParser
import json
import logging
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import textwrap
import time
import traceback
from typing import Callable, Iterable, Iterator, Mapping, Sequence
import urllib.error
import urllib.parse
import urllib.request
import zipfile

# Never create __pycache__, even when a user runs the .py file without -B.
sys.dont_write_bytecode = True
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

APP_NAME = "ComfyUI SageAttention Installer (Python Beta)"
USER_AGENT = "ComfyUI-SageAttention-Python-Installer/1.0-beta"
COMMUNITY_INDEX_URL = "https://raw.githubusercontent.com/wildminder/AI-windows-whl/refs/heads/main/wheels.json"
COMFY_WHEEL_BASE = "https://comfy-org.github.io/wheels"
COMFY_SPEC_BASE = "https://raw.githubusercontent.com/Comfy-Org/wheels/main/packages"
PYPI_TRITON_JSON = "https://pypi.org/pypi/triton-windows/json"
# Current triton-windows documentation still points embedded-Python users to this
# release for matching include/libs archives. Patch versions may differ; the
# Python *minor* version must match.
PYDEV_RELEASE_API = "https://api.github.com/repos/woct0rdho/triton-windows/releases/tags/v3.0.0-windows.post1"

SAGE3_RUNTIME_ARCHS = frozenset({"10.0", "12.0", "12.1"})
COMMUNITY_SAGE3_VERIFIED_ARCHS = frozenset({"12.0"})
MANAGED_PACKAGES = ("triton", "triton-windows", "sageattention", "sageattn3")
TORCH_READ_ONLY_PACKAGES = ("torch", "torchvision", "torchaudio")

# Ground truth: triton-lang/triton-windows README compatibility matrix.
TRITON_BY_TORCH_MINOR: dict[str, str] = {
    "2.4": "3.1",
    "2.5": "3.1",
    "2.6": "3.2",
    "2.7": "3.3",
    "2.8": "3.4",
    "2.9": "3.5",
    "2.10": "3.6",
    "2.11": "3.6",
    "2.12": "3.7",
    "2.13": "3.7",
    "2.14": "3.8",
}


class InstallerError(RuntimeError):
    """Expected user-facing installer failure."""


@dataclass(frozen=True)
class Architecture:
    name: str
    family: str
    cc: str


@dataclass
class EnvironmentInfo:
    python: str
    python_mm: str
    python_bits: int
    cp: str
    executable: str
    site_packages: str
    torch: str
    torchvision: str | None
    torchaudio: str | None
    cuda: str
    cuda_ok: bool
    gpu: str
    cc: str
    vram_gb: float
    triton_windows: str | None
    legacy_triton: str | None
    sageattention: str | None
    sageattn3: str | None
    architecture: Architecture | None = None

    def torch_snapshot(self) -> dict[str, str | None]:
        return {
            "torch": self.torch,
            "torchvision": self.torchvision,
            "torchaudio": self.torchaudio,
        }


@dataclass(frozen=True)
class ComfyCapabilities:
    sage3_import: bool
    sage3_registered: bool
    sage3_cli: bool
    sage2_cli: bool
    kjnodes: bool


@dataclass
class WheelCandidate:
    url: str
    name: str
    version: str
    source: str
    community: bool = False
    arch_list: list[str] = field(default_factory=list)
    sha256: str | None = None


@dataclass
class PythonDevState:
    ready: bool
    asset_name: str | None = None
    asset_url: str | None = None
    reason: str | None = None


@dataclass
class BackendEvaluation:
    supported: bool
    reason: str | None
    wheel: WheelCandidate | None
    triton_minor: str | None
    pydev: PythonDevState | None


@dataclass
class InstallPlan:
    backend: str
    torch: str = "KEEP"
    python_dev: str = "SKIP"
    python_dev_asset_name: str | None = None
    python_dev_asset_url: str | None = None
    legacy_triton: str = "SKIP"
    triton: str = "SKIP"
    triton_constraint: str | None = None
    triton_wheel: WheelCandidate | None = None
    sage2: str = "SKIP"
    sage2_wheel: WheelCandidate | None = None
    sage3: str = "SKIP"
    sage3_wheel: WheelCandidate | None = None

    def has_changes(self) -> bool:
        return any(
            action in {"INSTALL", "REMOVE"}
            for action in (self.python_dev, self.legacy_triton, self.triton, self.sage2, self.sage3)
        )


@dataclass
class StagedFiles:
    triton: Path | None = None
    sage2: Path | None = None
    sage3: Path | None = None
    python_dev: Path | None = None


@dataclass(frozen=True)
class ProcessInfo:
    pid: int
    executable: str


class Console:
    CSI = "\033["

    def __init__(self) -> None:
        self.ansi = self._enable_ansi()

    def _enable_ansi(self) -> bool:
        if not getattr(sys.stdout, "isatty", lambda: False)():
            return False
        if os.name != "nt":
            return True
        try:
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                return False
            return bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
        except Exception:
            return False

    def _style(self, text: str, code: str) -> str:
        return f"{self.CSI}{code}m{text}{self.CSI}0m" if self.ansi else text

    def banner(self) -> None:
        line = "=" * 64
        print(self._style(line, "36"))
        print(self._style(f"  {APP_NAME}", "36"))
        print(self._style("  SageAttention 2.2 / 2++ + SageAttention 3", "36"))
        print(self._style(line, "36"))
        self.info("PyTorch, torchvision and torchaudio are read-only.")

    def phase(self, number: int, text: str) -> None:
        print("\n" + self._style(f"[{number}/8] {text}", "36"))

    def ok(self, text: str) -> None:
        print(self._style(f"  [OK] {text}", "32"))

    def info(self, text: str) -> None:
        print(f"  {text}")

    def warn(self, text: str) -> None:
        print(self._style(f"  [!] {text}", "33"))

    def fail(self, text: str) -> None:
        print(self._style(f"  [X] {text}", "31"))


CONSOLE = Console()
LOGGER: logging.Logger | None = None


def log(message: str, *args: object) -> None:
    if LOGGER is not None:
        LOGGER.info(message, *args)


def normalize_dist_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def version_parts(value: str) -> tuple[int, ...]:
    """Loose numeric version tuple suitable for current upstream version strings."""
    base = value.split("+", 1)[0]
    nums = [int(x) for x in re.findall(r"\d+", base)]
    return tuple(nums or [0])


def base_version3(value: str) -> tuple[int, int, int]:
    nums = version_parts(value)
    return tuple((list(nums) + [0, 0, 0])[:3])  # type: ignore[return-value]


def major_minor(value: str) -> str:
    nums = version_parts(value)
    if len(nums) < 2:
        raise InstallerError(f"Cannot parse major/minor version from {value!r}.")
    return f"{nums[0]}.{nums[1]}"


def version_at_least(current: str, minimum: str) -> bool:
    return base_version3(current) >= base_version3(minimum)


def version_in_range(current: str, bounds: object) -> bool:
    if bounds is None:
        return True
    if not isinstance(bounds, list) or not bounds:
        return True
    cur = base_version3(current)
    lo = base_version3(str(bounds[0])) if len(bounds) >= 1 and bounds[0] else None
    hi = base_version3(str(bounds[1])) if len(bounds) >= 2 and bounds[1] else None
    return (lo is None or cur >= lo) and (hi is None or cur <= hi)


def normalize_package_version(value: str | None) -> str:
    if not value:
        return ""
    return value.lower().replace("-", ".").replace("_", ".")


def version_rank(value: str) -> tuple[int, ...]:
    # Handles e.g. 3.8.0.post28 and local versions without adding packaging.
    return tuple(list(version_parts(value)) + [0] * 6)[:6]


def get_triton_minor(torch_version: str) -> str | None:
    return TRITON_BY_TORCH_MINOR.get(major_minor(torch_version))


def get_architecture(cc: str) -> Architecture:
    mapping = {
        "8.0": ("Ampere", "Ampere"),
        "8.6": ("Ampere", "Ampere"),
        "8.9": ("Ada", "Ada"),
        "9.0": ("Hopper", "Hopper"),
        "10.0": ("Blackwell (datacenter)", "Blackwell"),
        "12.0": ("Blackwell", "Blackwell"),
        "12.1": ("Blackwell", "Blackwell"),
    }
    name, family = mapping.get(cc, ("Unknown", "Unknown"))
    return Architecture(name=name, family=family, cc=cc)


def safe_json(obj: object) -> str:
    return json.dumps(obj, indent=2, sort_keys=True, default=lambda x: dataclasses.asdict(x) if dataclasses.is_dataclass(x) else str(x))


# ---------------------------- subprocess safety ----------------------------

def run_process(
    executable: Path | str,
    args: Sequence[str],
    *,
    cwd: Path,
    timeout: int = 900,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    cmd = [str(executable), *map(str, args)]
    log("COMMAND: %s", subprocess.list2cmdline(cmd))
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise InstallerError(f"A required command timed out after {timeout} seconds.") from exc
    log("EXIT: %s", proc.returncode)
    if proc.stdout:
        log("STDOUT:\n%s", proc.stdout.rstrip())
    if proc.stderr:
        log("STDERR:\n%s", proc.stderr.rstrip())
    if proc.returncode != 0 and not allow_failure:
        raise InstallerError("A required command failed. See the log for full output.")
    return proc


def run_python_code(py: Path, root: Path, code: str, *, timeout: int = 180) -> str:
    proc = run_process(py, ["-s", "-B", "-c", code], cwd=root, timeout=timeout)
    return proc.stdout.strip()


ENVIRONMENT_PROBE = r'''
import importlib.metadata as m
import json, struct, sys, sysconfig

def dist(name):
    try:
        return m.version(name)
    except m.PackageNotFoundError:
        return None

try:
    import torch
except Exception as e:
    print(json.dumps({"error": "PyTorch import failed: " + str(e)}))
    raise SystemExit(0)

gpu = None
cc = None
vram = 0.0
cuda_ok = bool(torch.cuda.is_available())
if cuda_ok:
    gpu = torch.cuda.get_device_name(0)
    cc = ".".join(map(str, torch.cuda.get_device_capability(0)))
    vram = round(torch.cuda.get_device_properties(0).total_memory / (1024 ** 3), 1)

print(json.dumps({
    "error": None,
    "python": ".".join(map(str, sys.version_info[:3])),
    "python_mm": ".".join(map(str, sys.version_info[:2])),
    "python_bits": struct.calcsize("P") * 8,
    "cp": f"cp{sys.version_info.major}{sys.version_info.minor}",
    "executable": sys.executable,
    "site_packages": sysconfig.get_paths()["purelib"],
    "torch": torch.__version__,
    "torchvision": dist("torchvision"),
    "torchaudio": dist("torchaudio"),
    "cuda": torch.version.cuda,
    "cuda_ok": cuda_ok,
    "gpu": gpu,
    "cc": cc,
    "vram_gb": vram,
    "triton_windows": dist("triton-windows"),
    "legacy_triton": dist("triton"),
    "sageattention": dist("sageattention"),
    "sageattn3": dist("sageattn3"),
}))
'''


def get_environment_info(py: Path, root: Path) -> EnvironmentInfo:
    raw = run_python_code(py, root, ENVIRONMENT_PROBE, timeout=180)
    try:
        data = json.loads(raw.splitlines()[-1])
    except Exception as exc:
        raise InstallerError("Could not read the environment probe result.") from exc
    if data.get("error"):
        raise InstallerError(str(data["error"]))
    required = ("python", "python_mm", "python_bits", "cp", "site_packages", "torch", "cuda", "cuda_ok", "gpu", "cc")
    missing = [k for k in required if data.get(k) is None]
    if missing:
        raise InstallerError("Environment probe did not return: " + ", ".join(missing))
    env = EnvironmentInfo(**{k: data.get(k) for k in EnvironmentInfo.__dataclass_fields__ if k != "architecture"})
    env.architecture = get_architecture(env.cc)
    return env


# ----------------------------- Windows processes -----------------------------

def _iter_windows_processes() -> Iterator[ProcessInfo]:
    if os.name != "nt":
        return iter(())

    TH32CS_SNAPPROCESS = 0x00000002
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_ulong),
            ("cntUsage", ctypes.c_ulong),
            ("th32ProcessID", ctypes.c_ulong),
            ("th32DefaultHeapID", ctypes.c_void_p),
            ("th32ModuleID", ctypes.c_ulong),
            ("cntThreads", ctypes.c_ulong),
            ("th32ParentProcessID", ctypes.c_ulong),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", ctypes.c_ulong),
            ("szExeFile", ctypes.c_wchar * 260),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    # Explicit signatures are important on 64-bit Windows: HANDLE values must not
    # be truncated to ctypes' default C int return type.
    kernel32.CreateToolhelp32Snapshot.argtypes = [ctypes.c_ulong, ctypes.c_ulong]
    kernel32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    kernel32.Process32FirstW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PROCESSENTRY32W)]
    kernel32.Process32FirstW.restype = ctypes.c_int
    kernel32.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PROCESSENTRY32W)]
    kernel32.Process32NextW.restype = ctypes.c_int
    kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_ulong)]
    kernel32.QueryFullProcessImageNameW.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int

    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == INVALID_HANDLE_VALUE:
        raise InstallerError("Could not safely enumerate running Windows processes.")

    result: list[ProcessInfo] = []
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        ok = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            pid = int(entry.th32ProcessID)
            if entry.szExeFile.lower() in {"python.exe", "pythonw.exe"}:
                handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
                if not handle:
                    # A Python process whose executable path cannot be inspected is
                    # an ambiguous state. Fail closed rather than potentially modify
                    # the same embedded environment while it is in use.
                    raise InstallerError(
                        f"Could not safely inspect running {entry.szExeFile} process PID {pid}. "
                        "Close other Python/ComfyUI processes or run with sufficient permission."
                    )
                try:
                    size = ctypes.c_ulong(32768)
                    buf = ctypes.create_unicode_buffer(size.value)
                    if not kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                        raise InstallerError(
                            f"Could not safely determine the executable path of {entry.szExeFile} process PID {pid}."
                        )
                    result.append(ProcessInfo(pid=pid, executable=buf.value))
                finally:
                    kernel32.CloseHandle(handle)
            ok = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return iter(result)


def find_conflicting_embedded_python_processes(
    target_python: Path | str,
    current_pid: int | None = None,
    process_iter: Iterable[ProcessInfo] | None = None,
) -> list[ProcessInfo]:
    current_pid = os.getpid() if current_pid is None else current_pid
    target = os.path.normcase(os.path.abspath(str(target_python)))
    processes = list(_iter_windows_processes() if process_iter is None else process_iter)
    conflicts: list[ProcessInfo] = []
    for item in processes:
        if item.pid == current_pid:
            continue
        try:
            exe = os.path.normcase(os.path.abspath(item.executable))
        except Exception:
            continue
        if exe == target:
            conflicts.append(item)
    return conflicts


def assert_portable_root(root: Path, py: Path) -> None:
    if os.name != "nt":
        raise InstallerError("This installer supports Windows only.")
    if not py.is_file():
        raise InstallerError(r"python_embeded\python.exe was not found. Run this installer from the ComfyUI Windows Portable root.")
    if not (root / "ComfyUI" / "main.py").is_file():
        raise InstallerError(r"ComfyUI\main.py was not found. Run this installer from the ComfyUI Windows Portable root.")
    if os.path.normcase(os.path.abspath(sys.executable)) != os.path.normcase(os.path.abspath(py)):
        raise InstallerError(r"This installer must be run with this ComfyUI Portable's python_embeded\python.exe, not a system Python.")
    if struct.calcsize("P") * 8 != 64:
        raise InstallerError("64-bit embedded Python is required.")

    system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    local_vc = py.parent
    vc140 = (local_vc / "vcruntime140.dll", system_root / "System32" / "vcruntime140.dll")
    vc140_1 = (local_vc / "vcruntime140_1.dll", system_root / "System32" / "vcruntime140_1.dll")
    if not any(x.exists() for x in vc140) or not any(x.exists() for x in vc140_1):
        raise InstallerError("Microsoft Visual C++ 2015-2022 Redistributable (x64) was not detected.")

    try:
        conflicts = find_conflicting_embedded_python_processes(py)
    except InstallerError:
        raise
    except Exception as exc:
        raise InstallerError("Could not safely check whether another ComfyUI embedded-Python process is running.") from exc
    if conflicts:
        pids = ", ".join(str(p.pid) for p in conflicts[:6])
        raise InstallerError(f"Another process from this python_embeded is running (PID {pids}). Close ComfyUI and try again.")


def assert_base_environment(env: EnvironmentInfo) -> None:
    if env.python_bits != 64:
        raise InstallerError("64-bit embedded Python is required.")
    if not env.cuda_ok or not env.cuda:
        raise InstallerError("The bundled PyTorch has no usable NVIDIA CUDA runtime.")
    if not env.architecture or env.architecture.family == "Unknown":
        raise InstallerError(f"GPU compute capability {env.cc} is not supported by this installer.")


# ----------------------------- Comfy capabilities ----------------------------

def get_comfy_capabilities(root: Path) -> ComfyCapabilities:
    attention = root / "ComfyUI" / "comfy" / "ldm" / "modules" / "attention.py"
    cli = root / "ComfyUI" / "comfy" / "cli_args.py"
    attention_text = attention.read_text("utf-8", errors="replace") if attention.exists() else ""
    cli_text = cli.read_text("utf-8", errors="replace") if cli.exists() else ""
    custom_nodes = root / "ComfyUI" / "custom_nodes"
    kjnodes = False
    if custom_nodes.is_dir():
        try:
            kjnodes = any(p.is_dir() and "kjnodes" in p.name.lower() for p in custom_nodes.iterdir())
        except OSError:
            pass
    return ComfyCapabilities(
        sage3_import="SAGE_ATTENTION3_IS_AVAILABLE" in attention_text,
        sage3_registered=bool(re.search(r"register_attention_function\(\s*[\"']sage3[\"']", attention_text)),
        sage3_cli="--use-sage-attention3" in cli_text,
        sage2_cli="--use-sage-attention" in cli_text,
        kjnodes=kjnodes,
    )


# -------------------------------- HTTP layer --------------------------------
ALLOWED_SOURCE_HOSTS = {
    "comfy-org.github.io",
    "raw.githubusercontent.com",
    "github.com",
    "api.github.com",
    "pypi.org",
    "files.pythonhosted.org",
    "huggingface.co",
}


def allowed_redirect_host(host: str) -> bool:
    host = host.lower().strip(".")
    return (
        host in ALLOWED_SOURCE_HOSTS
        or host.endswith(".githubusercontent.com")
        or host.endswith(".pythonhosted.org")
        or host.endswith(".huggingface.co")
        or host.endswith(".hf.co")
    )


def validate_https_url(url: str, *, allowed_hosts: set[str] | None = None) -> urllib.parse.ParseResult:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() != "https":
        raise InstallerError(f"Refusing non-HTTPS URL: {url}")
    host = (parsed.hostname or "").lower()
    if not host:
        raise InstallerError(f"URL has no host: {url}")
    if allowed_hosts is not None and host not in allowed_hosts:
        raise InstallerError(f"Unexpected source host {host!r}.")
    if allowed_hosts is None and not allowed_redirect_host(host):
        raise InstallerError(f"Unexpected source host {host!r}.")
    return parsed


def _request(url: str, timeout: int = 45) -> urllib.response.addinfourl:
    validate_https_url(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    try:
        response = urllib.request.urlopen(req, timeout=timeout)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise InstallerError(f"Could not reach {urllib.parse.urlparse(url).hostname}.") from exc
    validate_https_url(response.geturl())
    return response


def fetch_bytes(url: str, *, timeout: int = 45, max_bytes: int = 8 * 1024 * 1024) -> bytes:
    with _request(url, timeout=timeout) as response:
        data = response.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise InstallerError("A resolver metadata response was unexpectedly large.")
    return data


def fetch_text(url: str, *, timeout: int = 45, max_bytes: int = 8 * 1024 * 1024) -> str:
    return fetch_bytes(url, timeout=timeout, max_bytes=max_bytes).decode("utf-8", errors="strict")


def fetch_json(url: str, *, timeout: int = 45, max_bytes: int = 8 * 1024 * 1024) -> object:
    try:
        return json.loads(fetch_text(url, timeout=timeout, max_bytes=max_bytes))
    except json.JSONDecodeError as exc:
        raise InstallerError(f"Invalid JSON received from {urllib.parse.urlparse(url).hostname}.") from exc


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        for key, value in attrs:
            if key.lower() == "href" and value:
                self.hrefs.append(value)


# ------------------------------ wheel matching -------------------------------
@dataclass(frozen=True)
class WheelName:
    distribution: str
    version: str
    python_tag: str
    abi_tag: str
    platform_tag: str


def parse_wheel_name(filename: str) -> WheelName | None:
    if not filename.lower().endswith(".whl"):
        return None
    stem = filename[:-4]
    parts = stem.split("-")
    if len(parts) < 5:
        return None
    platform_tag, abi_tag, python_tag = parts[-1], parts[-2], parts[-3]
    prefix = parts[:-3]
    # Wheel distribution names are escaped with underscores; build tag is uncommon
    # in our configured sources. Treat the first two fields as dist/version and allow
    # one optional build field afterwards.
    if len(prefix) < 2:
        return None
    distribution = prefix[0]
    version = prefix[1]
    return WheelName(distribution, version, python_tag, abi_tag, platform_tag)


def python_tag_matches(filename: str, python_mm: str, *, allow_abi3: bool) -> bool:
    parsed = parse_wheel_name(filename)
    if not parsed or parsed.platform_tag.lower() != "win_amd64":
        return False
    digits = python_mm.replace(".", "")
    exact = f"cp{digits}"
    py_tags = parsed.python_tag.split(".")
    abi_tags = parsed.abi_tag.split(".")
    if exact in py_tags and exact in abi_tags:
        return True
    if allow_abi3 and "abi3" in abi_tags:
        for tag in py_tags:
            m = re.fullmatch(r"cp(\d+)", tag)
            if m and int(digits) >= int(m.group(1)):
                return True
    return False


def declared_cuda_tag(filename: str) -> str | None:
    m = re.search(r"(?i)\+cu(?P<cu>\d+)", filename)
    return m.group("cu") if m else None


def declared_torch_tag(filename: str) -> str | None:
    m = re.search(r"(?i)torch(?P<tag>\d+(?:\.\d+){0,2})", filename)
    return m.group("tag") if m else None


def torch_tag_matches(filename: str, torch_version: str) -> bool:
    tag = declared_torch_tag(filename)
    if not tag:
        return False
    mm = major_minor(torch_version)
    if "." in tag:
        return major_minor(tag) == mm
    return tag == mm.replace(".", "")


def cuda_tag_matches(filename: str, cuda_version: str) -> bool:
    tag = declared_cuda_tag(filename)
    return bool(tag and tag == cuda_version.replace(".", ""))


def arch_list_supports(arch_list: Sequence[str], cc: str, *, strict_minor: bool) -> bool:
    if cc in arch_list:
        return True
    # Preserve existing V3 PowerShell behavior for the Sage2 Comfy build matrix:
    # an 8.0 family entry is accepted for Ampere/Ada-style 8.x coverage only when
    # the caller did not request strict architecture proof.
    if not strict_minor and cc.startswith("8.") and "8.0" in arch_list:
        return True
    return False


def parse_comfy_build_spec(text: str, env: EnvironmentInfo) -> list[str]:
    before_matrix = re.split(r"(?m)^build_matrix:\s*$", text, maxsplit=1)[0]
    default_match = re.search(r"(?m)^arch_list:\s*[\"'](?P<a>[^\"']+)[\"']", before_matrix)
    default_arch = default_match.group("a").split() if default_match else []
    block_re = re.compile(
        r"(?ms)^\s*-\s*cuda:\s*[\"'](?P<cuda>[^\"']+)[\"']\s*\r?\n"
        r"\s*pytorch:\s*[\"'](?P<torch>[^\"']+)[\"'](?P<body>.*?)(?=^\s*-\s*cuda:|^\s*platforms:)"
    )
    for match in block_re.finditer(text):
        if match.group("cuda") != env.cuda:
            continue
        if major_minor(match.group("torch")) != major_minor(env.torch):
            continue
        body = match.group("body")
        py_match = re.search(r"(?m)^\s*python_versions:\s*\[(?P<v>[^\]]*)\]", body)
        if not py_match:
            continue
        py_versions = re.findall(r"[\"']([^\"']+)[\"']", py_match.group("v"))
        if env.python_mm not in py_versions:
            continue
        arch_match = re.search(r"(?m)^\s*arch_list:\s*[\"'](?P<a>[^\"']+)[\"']", body)
        return arch_match.group("a").split() if arch_match else list(default_arch)
    return []


def resolve_official_wheel(
    package_name: str,
    env: EnvironmentInfo,
    *,
    strict_arch: bool,
    fetcher: Callable[[str], str] = fetch_text,
) -> WheelCandidate | None:
    spec_text = fetcher(f"{COMFY_SPEC_BASE}/{package_name}.yml")
    arch_list = parse_comfy_build_spec(spec_text, env)
    if not arch_list_supports(arch_list, env.cc, strict_minor=strict_arch):
        return None

    index_url = f"{COMFY_WHEEL_BASE}/{package_name}/"
    html = fetcher(index_url)
    parser = LinkParser()
    parser.feed(html)
    candidates: list[WheelCandidate] = []
    for href in parser.hrefs:
        url = urllib.parse.urljoin(index_url, href)
        try:
            validate_https_url(url)
        except InstallerError:
            continue
        filename = urllib.parse.unquote(Path(urllib.parse.urlparse(url).path).name)
        parsed = parse_wheel_name(filename)
        if not parsed or normalize_dist_name(parsed.distribution) != normalize_dist_name(package_name):
            continue
        if package_name == "sageattention" and not parsed.version.startswith("2.2"):
            continue
        if not python_tag_matches(filename, env.python_mm, allow_abi3=(package_name == "sageattention")):
            continue
        if not cuda_tag_matches(filename, env.cuda):
            continue
        if not torch_tag_matches(filename, env.torch):
            continue
        candidates.append(
            WheelCandidate(
                url=url,
                name=filename,
                version=parsed.version,
                source="Comfy-Org/wheels",
                community=False,
                arch_list=list(arch_list),
            )
        )
    if not candidates:
        return None
    return sorted(candidates, key=lambda c: (version_rank(c.version), c.name), reverse=True)[0]


def _community_package(index: Mapping[str, object], package_name: str) -> Mapping[str, object] | None:
    needle = re.sub(r"[^a-z0-9]", "", package_name.lower())
    packages = index.get("packages", [])
    if not isinstance(packages, list):
        return None
    for item in packages:
        if not isinstance(item, Mapping):
            continue
        identifiers = (str(item.get("id", "")), str(item.get("name", "")))
        if any(re.sub(r"[^a-z0-9]", "", x.lower()) == needle for x in identifiers):
            return item
    return None


def resolve_community_wheel(
    package_name: str,
    env: EnvironmentInfo,
    *,
    index_data: Mapping[str, object] | None = None,
) -> WheelCandidate | None:
    if index_data is None:
        raw = fetch_json(COMMUNITY_INDEX_URL, max_bytes=4 * 1024 * 1024)
        if not isinstance(raw, Mapping):
            return None
        index_data = raw
    pkg = _community_package(index_data, package_name)
    if not pkg:
        return None
    wheels = pkg.get("wheels", [])
    if not isinstance(wheels, list):
        return None
    candidates: list[WheelCandidate] = []
    for item in wheels:
        if not isinstance(item, Mapping):
            continue
        url = str(item.get("url") or "")
        if not url:
            continue
        try:
            parsed_url = validate_https_url(url)
        except InstallerError:
            continue
        if parsed_url.hostname not in {"github.com", "huggingface.co"}:
            continue
        filename = urllib.parse.unquote(Path(parsed_url.path).name)
        parsed = parse_wheel_name(filename)
        if not parsed or normalize_dist_name(parsed.distribution) != normalize_dist_name(package_name):
            continue
        package_version = str(item.get("package_version") or parsed.version)
        if package_name == "sageattention" and not package_version.startswith("2.2"):
            continue
        if not version_in_range(env.torch, item.get("torch_version")):
            continue
        if not version_in_range(env.python_mm, item.get("python_version")):
            continue
        if not version_in_range(env.cuda, item.get("cuda_version")):
            continue
        if not python_tag_matches(filename, env.python_mm, allow_abi3=(package_name == "sageattention")):
            continue
        declared_cuda = declared_cuda_tag(filename)
        if declared_cuda and declared_cuda != env.cuda.replace(".", ""):
            continue
        declared_torch = declared_torch_tag(filename)
        if declared_torch and not torch_tag_matches(filename, env.torch):
            continue
        candidates.append(
            WheelCandidate(
                url=url,
                name=filename,
                version=parsed.version,
                source="wildminder/AI-windows-whl",
                community=True,
                arch_list=[],
            )
        )
    if not candidates:
        return None
    return sorted(candidates, key=lambda c: (version_rank(c.version), c.name), reverse=True)[0]


def resolve_backend_wheel(
    package_name: str,
    env: EnvironmentInfo,
    *,
    sage3: bool = False,
    official_fetcher: Callable[[str], str] = fetch_text,
    community_index: Mapping[str, object] | None = None,
) -> WheelCandidate | None:
    try:
        official = resolve_official_wheel(package_name, env, strict_arch=sage3, fetcher=official_fetcher)
    except InstallerError as exc:
        log("Official %s resolver metadata failed: %s", package_name, exc)
        official = None
    if official:
        return official
    if sage3 and env.cc not in COMMUNITY_SAGE3_VERIFIED_ARCHS:
        return None
    return resolve_community_wheel(package_name, env, index_data=community_index)


def resolve_triton_wheel(
    env: EnvironmentInfo,
    triton_minor: str,
    *,
    pypi_data: Mapping[str, object] | None = None,
) -> WheelCandidate | None:
    if pypi_data is None:
        raw = fetch_json(PYPI_TRITON_JSON, max_bytes=16 * 1024 * 1024)
        if not isinstance(raw, Mapping):
            return None
        pypi_data = raw
    releases = pypi_data.get("releases", {})
    if not isinstance(releases, Mapping):
        return None
    results: list[WheelCandidate] = []
    prefix = triton_minor + "."
    for version, files in releases.items():
        version = str(version)
        if not (version == triton_minor or version.startswith(prefix)):
            continue
        if not isinstance(files, list):
            continue
        for item in files:
            if not isinstance(item, Mapping) or item.get("packagetype") != "bdist_wheel" or item.get("yanked"):
                continue
            filename = str(item.get("filename") or "")
            url = str(item.get("url") or "")
            if not filename or not url:
                continue
            parsed = parse_wheel_name(filename)
            if not parsed or normalize_dist_name(parsed.distribution) != "triton-windows":
                continue
            if not python_tag_matches(filename, env.python_mm, allow_abi3=True):
                continue
            try:
                parsed_url = validate_https_url(url)
            except InstallerError:
                continue
            if parsed_url.hostname != "files.pythonhosted.org":
                continue
            results.append(
                WheelCandidate(
                    url=url,
                    name=filename,
                    version=version,
                    source="PyPI/triton-windows",
                    community=False,
                    arch_list=[],
                )
            )
    if not results:
        return None
    return sorted(results, key=lambda c: (version_rank(c.version), c.name), reverse=True)[0]


# -------------------------- hardware/backend evaluation ----------------------
def get_python_dev_state(root: Path, python_mm: str) -> PythonDevState:
    pyhome = root / "python_embeded"
    expected_lib = "python" + python_mm.replace(".", "") + ".lib"
    include_ok = (pyhome / "include" / "Python.h").is_file()
    libs_ok = (pyhome / "libs" / expected_lib).is_file()
    if include_ok and libs_ok:
        return PythonDevState(ready=True)

    try:
        release = fetch_json(PYDEV_RELEASE_API, max_bytes=2 * 1024 * 1024)
    except InstallerError as exc:
        return PythonDevState(ready=False, reason=f"Python developer include/libs are missing and the documented asset list could not be checked: {exc}")
    if not isinstance(release, Mapping):
        return PythonDevState(ready=False, reason="Python developer include/libs are missing and the documented asset list was invalid.")
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        assets = []
    pattern = re.compile(rf"^python_{re.escape(python_mm)}\.\d+_include_libs\.zip$")
    for asset in assets:
        if not isinstance(asset, Mapping):
            continue
        name = str(asset.get("name") or "")
        url = str(asset.get("browser_download_url") or "")
        if pattern.match(name) and url:
            try:
                validate_https_url(url, allowed_hosts={"github.com"})
            except InstallerError:
                continue
            return PythonDevState(ready=True, asset_name=name, asset_url=url)
    return PythonDevState(
        ready=False,
        reason=f"Python developer include/libs are missing and no documented matching asset was found for Python {python_mm}.",
    )


def test_sage2_hardware(env: EnvironmentInfo) -> str | None:
    if env.cc not in {"8.0", "8.6", "8.9", "9.0", "10.0", "12.0", "12.1"}:
        return f"Upstream SageAttention 2 does not support compute capability {env.cc}."
    family = env.architecture.family if env.architecture else "Unknown"
    minimum_cuda = {"Ampere": "12.0", "Ada": "12.4", "Hopper": "12.3", "Blackwell": "12.8"}.get(family)
    if minimum_cuda and not version_at_least(env.cuda, minimum_cuda):
        return f"SageAttention 2 on {env.architecture.name} requires CUDA {minimum_cuda} or newer."
    return None


def test_sage3_hardware(env: EnvironmentInfo) -> str | None:
    if not env.architecture or env.architecture.family != "Blackwell":
        return "SageAttention 3 is currently a Blackwell-specific backend."
    if env.cc not in SAGE3_RUNTIME_ARCHS:
        return f"Current SageAttention 3 runtime kernels do not accept sm_{env.cc.replace('.', '')}."
    if not version_at_least(env.cuda, "12.8"):
        return "SageAttention 3 requires CUDA 12.8 or newer."
    if not version_at_least(env.torch, "2.8"):
        return "SageAttention 3 upstream requires PyTorch 2.8 or newer."
    if not version_at_least(env.python_mm, "3.13"):
        return "SageAttention 3 upstream currently requires Python 3.13 or newer."
    return None


def evaluate_sage2(
    env: EnvironmentInfo,
    root: Path,
    *,
    wheel_resolver: Callable[[str, EnvironmentInfo], WheelCandidate | None] | None = None,
    pydev_state: PythonDevState | None = None,
) -> BackendEvaluation:
    reason = test_sage2_hardware(env)
    if reason:
        return BackendEvaluation(False, reason, None, None, None)
    triton_minor = get_triton_minor(env.torch)
    if not triton_minor:
        return BackendEvaluation(False, f"PyTorch {major_minor(env.torch)} is outside the current triton-windows compatibility matrix.", None, None, None)
    pydev = pydev_state or get_python_dev_state(root, env.python_mm)
    if not pydev.ready:
        return BackendEvaluation(False, pydev.reason, None, triton_minor, pydev)
    resolver = wheel_resolver or (lambda name, e: resolve_backend_wheel(name, e, sage3=False))
    wheel = resolver("sageattention", env)
    if not wheel:
        return BackendEvaluation(
            False,
            f"No compatible SageAttention 2.2 Windows wheel exists for Python {env.python_mm}, PyTorch {major_minor(env.torch)}, CUDA {env.cuda} and sm_{env.cc.replace('.', '')}.",
            None,
            triton_minor,
            pydev,
        )
    return BackendEvaluation(True, None, wheel, triton_minor, pydev)


def evaluate_sage3(
    env: EnvironmentInfo,
    root: Path,
    *,
    wheel_resolver: Callable[[str, EnvironmentInfo], WheelCandidate | None] | None = None,
    pydev_state: PythonDevState | None = None,
) -> BackendEvaluation:
    reason = test_sage3_hardware(env)
    if reason:
        return BackendEvaluation(False, reason, None, None, None)
    triton_minor = get_triton_minor(env.torch)
    if not triton_minor:
        return BackendEvaluation(False, f"PyTorch {major_minor(env.torch)} is outside the current triton-windows compatibility matrix.", None, None, None)
    pydev = pydev_state or get_python_dev_state(root, env.python_mm)
    if not pydev.ready:
        return BackendEvaluation(False, pydev.reason, None, triton_minor, pydev)
    resolver = wheel_resolver or (lambda name, e: resolve_backend_wheel(name, e, sage3=True))
    wheel = resolver("sageattn3", env)
    if not wheel:
        return BackendEvaluation(
            False,
            f"No compatible SageAttention 3 Windows wheel exists for Python {env.python_mm}, PyTorch {major_minor(env.torch)}, CUDA {env.cuda} and sm_{env.cc.replace('.', '')}.",
            None,
            triton_minor,
            pydev,
        )
    return BackendEvaluation(True, None, wheel, triton_minor, pydev)


def get_recommendation(env: EnvironmentInfo, sage2: BackendEvaluation, sage3: BackendEvaluation) -> str | None:
    family = env.architecture.family if env.architecture else "Unknown"
    if family in {"Ampere", "Ada", "Hopper"}:
        return "Sage2" if sage2.supported else None
    if family == "Blackwell":
        if sage2.supported and sage3.supported:
            return "Both"
        if sage3.supported:
            return "Sage3"
        if sage2.supported:
            return "Sage2"
    return None


def assert_backend_available(choice: str, sage2: BackendEvaluation, sage3: BackendEvaluation) -> None:
    if choice == "Sage2" and not sage2.supported:
        raise InstallerError(f"SageAttention 2 is not available: {sage2.reason}")
    if choice == "Sage3" and not sage3.supported:
        raise InstallerError(f"SageAttention 3 is not available: {sage3.reason}")
    if choice == "Both":
        if not sage2.supported:
            raise InstallerError(f"Both cannot be selected because SageAttention 2 is unavailable: {sage2.reason}")
        if not sage3.supported:
            raise InstallerError(f"Both cannot be selected because SageAttention 3 is unavailable: {sage3.reason}")


def select_backend(
    requested: str | None,
    recommended: str,
    sage2: BackendEvaluation,
    sage3: BackendEvaluation,
    env: EnvironmentInfo,
) -> str | None:
    if requested:
        requested_norm = {"auto": "Auto", "sage2": "Sage2", "sage3": "Sage3", "both": "Both"}[requested.lower()]
        choice = recommended if requested_norm == "Auto" else requested_norm
        assert_backend_available(choice, sage2, sage3)
        CONSOLE.info(f"Selected: {choice}" + (" (automatic recommendation)" if requested_norm == "Auto" else ""))
        return choice

    if env.architecture and env.architecture.family == "Blackwell" and sage2.supported and sage3.supported:
        CONSOLE.info("SageAttention 3 can be faster on Blackwell; SageAttention 2 is the more conservative compatibility/quality option.")
        CONSOLE.info("Installing both lets compatible workflows choose the backend that fits the model.")
    rows = [
        ("1", "Both", "Both", sage2.supported and sage3.supported, "Sage2 compatibility + Sage3 Blackwell speed"),
        ("2", "Sage3", "SageAttention 3", sage3.supported, "Blackwell FP4 backend" if sage3.supported else str(sage3.reason)),
        ("3", "Sage2", "SageAttention 2.2", sage2.supported, "Compatibility / quality" if sage2.supported else str(sage2.reason)),
    ]
    print()
    for key, value, label, available, note in rows:
        rec = "  <- Recommended" if value == recommended else ""
        if available:
            print(f"  [{key}] {label:<20} {note}{rec}")
        else:
            print(f"  [{key}] {label:<20} unavailable")
            print(f"      {note}")
    print("  [4] Cancel")
    default = next((row for row in rows if row[1] == recommended and row[3]), next(row for row in rows if row[3]))
    while True:
        try:
            answer = input(f"Choice [{default[0]}]: ").strip()
        except EOFError:
            raise InstallerError("Interactive input is unavailable; use --backend auto/sage2/sage3/both.")
        if not answer:
            return default[1]
        if answer == "4":
            return None
        hit = next((row for row in rows if row[0] == answer), None)
        if not hit:
            CONSOLE.warn("Please choose 1, 2, 3 or 4.")
            continue
        if not hit[3]:
            CONSOLE.warn(f"{hit[2]} is not available on this system: {hit[4]}")
            continue
        return hit[1]


# ---------------------------------- plan -------------------------------------
def new_plan(
    selected: str,
    env: EnvironmentInfo,
    sage2: BackendEvaluation,
    sage3: BackendEvaluation,
    *,
    triton_resolver: Callable[[EnvironmentInfo, str], WheelCandidate | None] = resolve_triton_wheel,
) -> InstallPlan:
    uses_sage2 = selected in {"Sage2", "Both"}
    uses_sage3 = selected in {"Sage3", "Both"}
    evaluation = sage2 if uses_sage2 else sage3
    triton_minor = evaluation.triton_minor
    if not triton_minor:
        raise InstallerError("A compatible Triton version could not be resolved.")
    major, minor = [int(x) for x in triton_minor.split(".")]
    upper = f"{major}.{minor + 1}"
    constraint = f"triton-windows>={triton_minor},<{upper}"

    legacy_action = "REMOVE" if env.legacy_triton else "SKIP"
    triton_compatible = bool(env.triton_windows and major_minor(env.triton_windows) == triton_minor)
    triton_action = "KEEP" if triton_compatible and legacy_action != "REMOVE" else "INSTALL"
    triton_wheel = None
    if triton_action == "INSTALL":
        triton_wheel = triton_resolver(env, triton_minor)
        if not triton_wheel:
            raise InstallerError(f"No compatible triton-windows {triton_minor}.x wheel was found on official PyPI for Python {env.python_mm}.")

    pydev = evaluation.pydev or PythonDevState(False, reason="Missing Python developer state.")
    if not pydev.ready:
        raise InstallerError(pydev.reason or "Python developer include/libs are unavailable.")
    python_dev = "INSTALL" if pydev.asset_url else "KEEP"

    plan = InstallPlan(
        backend=selected,
        python_dev=python_dev,
        python_dev_asset_name=pydev.asset_name,
        python_dev_asset_url=pydev.asset_url,
        legacy_triton=legacy_action,
        triton=triton_action,
        triton_constraint=constraint,
        triton_wheel=triton_wheel,
    )
    if uses_sage2:
        assert sage2.wheel is not None
        plan.sage2_wheel = sage2.wheel
        plan.sage2 = "KEEP" if env.sageattention and normalize_package_version(env.sageattention) == normalize_package_version(sage2.wheel.version) else "INSTALL"
    if uses_sage3:
        assert sage3.wheel is not None
        plan.sage3_wheel = sage3.wheel
        plan.sage3 = "KEEP" if env.sageattn3 and normalize_package_version(env.sageattn3) == normalize_package_version(sage3.wheel.version) else "INSTALL"
    return plan


def show_environment(env: EnvironmentInfo, caps: ComfyCapabilities) -> None:
    assert env.architecture is not None
    rows = [
        ("GPU", env.gpu),
        ("Architecture", f"{env.architecture.name} (sm_{env.cc.replace('.', '')})"),
        ("VRAM", f"{env.vram_gb} GB"),
        ("Python", env.python),
        ("PyTorch", f"{env.torch}  [READ-ONLY]"),
        ("CUDA runtime", env.cuda),
        ("Triton-Windows", env.triton_windows or "not installed"),
        ("SageAttention 2", env.sageattention or "not installed"),
        ("SageAttention 3", env.sageattn3 or "not installed"),
    ]
    for key, value in rows:
        print(f"  {key:<15} {value}")
    if caps.sage3_registered:
        CONSOLE.info('ComfyUI: native "sage3" backend registration detected.')
    elif caps.sage3_import:
        CONSOLE.info("ComfyUI: SageAttention 3 import support detected.")


def show_backend_status(label: str, result: BackendEvaluation) -> None:
    if result.supported:
        source = f" via {result.wheel.source}" if result.wheel else ""
        CONSOLE.ok(f"{label:<20} supported{source}")
    else:
        CONSOLE.fail(f"{label:<20} unavailable")
        CONSOLE.info(str(result.reason))


def show_plan(plan: InstallPlan) -> None:
    print()
    print(f"  {'Selected backend':<20} {plan.backend}")
    print(f"  {'PyTorch':<20} KEEP / read-only")
    print(f"  {'Python include/libs':<20} {plan.python_dev}")
    print(f"  {'Legacy triton':<20} {plan.legacy_triton}")
    suffix = f"  {plan.triton_constraint}" if plan.triton_constraint else ""
    print(f"  {'Triton-Windows':<20} {plan.triton}{suffix}")
    if plan.sage2 != "SKIP" and plan.sage2_wheel:
        print(f"  {'SageAttention 2':<20} {plan.sage2}")
        print(f"  {'Source SA2':<20} {plan.sage2_wheel.source}")
        print(f"  {'Wheel SA2':<20} {plan.sage2_wheel.name}")
    if plan.sage3 != "SKIP" and plan.sage3_wheel:
        print(f"  {'SageAttention 3':<20} {plan.sage3}")
        print(f"  {'Source SA3':<20} {plan.sage3_wheel.source}")
        print(f"  {'Wheel SA3':<20} {plan.sage3_wheel.name}")
    if (plan.sage2_wheel and plan.sage2_wheel.community) or (plan.sage3_wheel and plan.sage3_wheel.community):
        CONSOLE.warn("Community fallback selected because no compatible Comfy-Org wheel was available.")


# ------------------------------- log/backup ---------------------------------
def start_log(root: Path) -> Path:
    global LOGGER
    logs = root / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    path = logs / f"Install-SageAttention-Python-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.log"
    logger = logging.getLogger("sageattention_installer")
    logger.handlers.clear()
    logger.setLevel(logging.INFO)
    handler = logging.FileHandler(path, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    LOGGER = logger
    CONSOLE.info(f"Log: {path}")
    return path


def mutated_packages(plan: InstallPlan) -> list[str]:
    result: list[str] = []
    if plan.legacy_triton == "REMOVE":
        result.append("triton")
    if plan.triton == "INSTALL":
        result.append("triton-windows")
    if plan.sage2 == "INSTALL":
        result.append("sageattention")
    if plan.sage3 == "INSTALL":
        result.append("sageattn3")
    return list(dict.fromkeys(result))


def package_patterns(package_name: str) -> tuple[str, ...]:
    return {
        "triton": ("triton", "triton-*.dist-info"),
        "triton-windows": ("triton", "triton_windows-*.dist-info", "triton_windows.libs"),
        "sageattention": ("sageattention", "sageattention-*.dist-info", "sageattention.libs", "sageattention*.pyd"),
        "sageattn3": ("sageattn3", "sageattn3-*.dist-info", "fp4attn_cuda*.pyd", "fp4quant_cuda*.pyd"),
    }.get(package_name, ())


def pip_show_files(py: Path, root: Path, package_name: str) -> tuple[str, list[Path]]:
    proc = run_process(py, ["-s", "-B", "-m", "pip", "show", "-f", package_name], cwd=root, timeout=120, allow_failure=True)
    if proc.returncode != 0 or not proc.stdout:
        return "", []
    lines = proc.stdout.splitlines()
    location = None
    files_index = None
    for idx, line in enumerate(lines):
        if line.startswith("Location:"):
            location = Path(line.split(":", 1)[1].strip())
        elif line.strip() == "Files:":
            files_index = idx
    files: list[Path] = []
    if location and files_index is not None:
        for line in lines[files_index + 1 :]:
            rel = line.strip()
            if not rel:
                continue
            try:
                files.append((location / rel).resolve())
            except OSError:
                continue
    return proc.stdout, files


def copy_file_preserving_relative(src: Path, site_root: Path, snapshot_root: Path) -> None:
    try:
        rel = src.resolve().relative_to(site_root.resolve())
    except (ValueError, OSError):
        return
    if not src.is_file():
        return
    dst = snapshot_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def backup_state(root: Path, py: Path, env: EnvironmentInfo, plan: InstallPlan) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = root / "backup" / f"Install-SageAttention-Python-{stamp}-{os.getpid()}"
    backup.mkdir(parents=True, exist_ok=False)
    (backup / "environment.json").write_text(safe_json(dataclasses.asdict(env)), encoding="utf-8")
    (backup / "plan.json").write_text(safe_json(dataclasses.asdict(plan)), encoding="utf-8")
    (backup / "installed-versions.json").write_text(safe_json({
        "triton-windows": env.triton_windows,
        "triton": env.legacy_triton,
        "sageattention": env.sageattention,
        "sageattn3": env.sageattn3,
        **env.torch_snapshot(),
    }), encoding="utf-8")

    freeze = run_process(py, ["-s", "-B", "-m", "pip", "freeze"], cwd=root, timeout=120, allow_failure=True)
    (backup / "pip-freeze.txt").write_text(freeze.stdout, encoding="utf-8")

    packages_dir = backup / "packages"
    snapshot = backup / "site-packages"
    packages_dir.mkdir()
    snapshot.mkdir()
    site_root = Path(env.site_packages)
    for package in mutated_packages(plan):
        manifest, files = pip_show_files(py, root, package)
        if manifest:
            safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", package)
            (packages_dir / f"{safe_name}.manifest.txt").write_text(manifest, encoding="utf-8")
            for src in files:
                copy_file_preserving_relative(src, site_root, snapshot)

    # Narrow pattern fallback for metadata/shared-file edge cases.
    for package in mutated_packages(plan):
        for pattern in package_patterns(package):
            for src in site_root.glob(pattern):
                try:
                    rel = src.resolve().relative_to(site_root.resolve())
                except (ValueError, OSError):
                    continue
                dst = snapshot / rel
                if src.is_dir():
                    if dst.exists():
                        shutil.rmtree(dst)
                    shutil.copytree(src, dst)
                elif src.is_file():
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)

    if plan.python_dev == "INSTALL":
        dev = backup / "python-dev"
        dev.mkdir()
        for name in ("include", "libs"):
            src = root / "python_embeded" / name
            if src.exists():
                shutil.copytree(src, dev / name)

    (backup / "stage").mkdir()
    CONSOLE.ok(f"Backup created: {backup}")
    log("Backup created: %s", backup)
    return backup


# ----------------------------- download/security -----------------------------
def human_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} GB"


def download_file(url: str, destination: Path, label: str) -> str:
    validate_https_url(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        response = urllib.request.urlopen(req, timeout=60)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise InstallerError(f"Download failed: {label}") from exc
    with response:
        validate_https_url(response.geturl())
        total_header = response.headers.get("Content-Length")
        total = int(total_header) if total_header and total_header.isdigit() else None
        digest = hashlib.sha256()
        written = 0
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("wb") as out:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                digest.update(chunk)
                written += len(chunk)
                if total:
                    pct = min(100, int(written * 100 / total))
                    width = 20
                    filled = int(width * pct / 100)
                    bar = "#" * filled + "-" * (width - filled)
                    print(f"\r  [{bar}] {pct:3d}%  {human_bytes(written)} / {human_bytes(total)}  {label}", end="", flush=True)
        if total:
            print()
        else:
            CONSOLE.info(f"Downloaded {label}: {human_bytes(written)}")
    sha = digest.hexdigest()
    log("SHA256 %s %s", destination.name, sha)
    return sha


def _safe_zip_member(name: str) -> PurePosixPath:
    if "\\" in name:
        raise InstallerError(f"Archive contains an unsafe path: {name}")
    pure = PurePosixPath(name)
    if pure.is_absolute() or any(part in {"..", ""} for part in pure.parts):
        raise InstallerError(f"Archive contains an unsafe path: {name}")
    if pure.parts and re.match(r"^[A-Za-z]:", pure.parts[0]):
        raise InstallerError(f"Archive contains an unsafe path: {name}")
    return pure


def validate_zip_paths(zf: zipfile.ZipFile) -> None:
    for info in zf.infolist():
        _safe_zip_member(info.filename.rstrip("/")) if info.filename.rstrip("/") else None


def _metadata_headers(zf: zipfile.ZipFile, suffix: str) -> Mapping[str, str]:
    members = [n for n in zf.namelist() if n.endswith(suffix)]
    if len(members) != 1:
        raise InstallerError(f"Wheel must contain exactly one {suffix} file.")
    raw = zf.read(members[0]).decode("utf-8", errors="strict")
    msg = email.parser.Parser().parsestr(raw)
    return {key: value for key, value in msg.items()}


def validate_wheel(
    path: Path,
    expected_distribution: str,
    expected_version: str,
    env: EnvironmentInfo,
    *,
    allow_abi3: bool,
) -> None:
    parsed = parse_wheel_name(path.name)
    if not parsed:
        raise InstallerError(f"Invalid wheel filename: {path.name}")
    if normalize_dist_name(parsed.distribution) != normalize_dist_name(expected_distribution):
        raise InstallerError(f"Wheel package name mismatch for {path.name}.")
    if normalize_package_version(parsed.version) != normalize_package_version(expected_version):
        raise InstallerError(f"Wheel version mismatch for {path.name}.")
    if not python_tag_matches(path.name, env.python_mm, allow_abi3=allow_abi3):
        raise InstallerError(f"Wheel Python/ABI tag is incompatible: {path.name}")
    if parsed.platform_tag.lower() != "win_amd64":
        raise InstallerError(f"Wheel platform is not win_amd64: {path.name}")
    if not zipfile.is_zipfile(path):
        raise InstallerError(f"Downloaded file is not a valid wheel ZIP: {path.name}")

    with zipfile.ZipFile(path, "r") as zf:
        validate_zip_paths(zf)
        metadata = _metadata_headers(zf, ".dist-info/METADATA")
        wheel = _metadata_headers(zf, ".dist-info/WHEEL")
        if normalize_dist_name(metadata.get("Name", "")) != normalize_dist_name(expected_distribution):
            raise InstallerError(f"METADATA package name mismatch in {path.name}.")
        if normalize_package_version(metadata.get("Version")) != normalize_package_version(expected_version):
            raise InstallerError(f"METADATA version mismatch in {path.name}.")
        # WHEEL can contain multiple Tag lines. Parser mapping only preserves the
        # last one, so inspect raw text for all tags as well.
        wheel_member = next(n for n in zf.namelist() if n.endswith(".dist-info/WHEEL"))
        wheel_text = zf.read(wheel_member).decode("utf-8", errors="strict")
        tags = [line.split(":", 1)[1].strip() for line in wheel_text.splitlines() if line.startswith("Tag:")]
        if tags:
            compatible = False
            digits = env.python_mm.replace(".", "")
            for tag in tags:
                parts = tag.split("-")
                if len(parts) != 3 or parts[2] != "win_amd64":
                    continue
                py_tag, abi_tag, _ = parts
                if py_tag == f"cp{digits}" and abi_tag == f"cp{digits}":
                    compatible = True
                elif allow_abi3 and abi_tag == "abi3":
                    m = re.fullmatch(r"cp(\d+)", py_tag)
                    compatible = bool(m and int(digits) >= int(m.group(1)))
                if compatible:
                    break
            if not compatible:
                raise InstallerError(f"WHEEL metadata tags are incompatible: {path.name}")


def validate_python_dev_archive(path: Path, python_mm: str) -> None:
    if not zipfile.is_zipfile(path):
        raise InstallerError("Python developer asset is not a valid ZIP archive.")
    expected_lib = f"libs/python{python_mm.replace('.', '')}.lib".lower()
    with zipfile.ZipFile(path, "r") as zf:
        validate_zip_paths(zf)
        files = [n.rstrip("/") for n in zf.namelist() if n.rstrip("/")]
        for name in files:
            pure = _safe_zip_member(name)
            if pure.parts[0].lower() not in {"include", "libs"}:
                raise InstallerError(f"Python developer archive contains unexpected top-level content: {name}")
            if pure.parts[0].lower() == "lib":
                raise InstallerError("Python developer archive attempted to target python_embeded\\Lib.")
        lower = {n.lower() for n in files}
        if "include/python.h" not in lower or expected_lib not in lower:
            raise InstallerError(f"Python developer archive does not match Python {python_mm}.")


def stage_files(plan: InstallPlan, env: EnvironmentInfo, backup_dir: Path) -> StagedFiles:
    stage = backup_dir / "stage"
    result = StagedFiles()
    items = [
        ("triton", "Triton-Windows", plan.triton, plan.triton_wheel, "triton-windows", True),
        ("sage2", "SageAttention 2.2", plan.sage2, plan.sage2_wheel, "sageattention", True),
        ("sage3", "SageAttention 3", plan.sage3, plan.sage3_wheel, "sageattn3", False),
    ]
    for key, label, action, wheel, package, allow_abi3 in items:
        if action != "INSTALL":
            continue
        if not wheel:
            raise InstallerError(f"Resolver did not provide a wheel for {label}.")
        path = stage / wheel.name
        sha = download_file(wheel.url, path, f"Downloading {label}")
        if path.stat().st_size < 100 * 1024:
            raise InstallerError(f"Downloaded {label} wheel is unexpectedly small.")
        validate_wheel(path, package, wheel.version, env, allow_abi3=allow_abi3)
        wheel.sha256 = sha
        setattr(result, key, path)
        CONSOLE.info(f"Staged and validated {wheel.name}")

    if plan.python_dev == "INSTALL":
        if not plan.python_dev_asset_name or not plan.python_dev_asset_url:
            raise InstallerError("Python developer asset was not resolved.")
        path = stage / plan.python_dev_asset_name
        download_file(plan.python_dev_asset_url, path, "Downloading embedded Python developer files")
        if path.stat().st_size < 10 * 1024:
            raise InstallerError("Downloaded Python developer archive is unexpectedly small.")
        validate_python_dev_archive(path, env.python_mm)
        result.python_dev = path
        CONSOLE.info(f"Staged and validated {path.name}")
    return result


# ------------------------------ mutation/recovery ----------------------------
def pip_target_is_torch_spec(token: str) -> bool:
    base = token.strip().lower()
    if base.startswith("-"):
        return False
    # Local wheel paths can contain a torch build tag (e.g. sageattention...torch210)
    # and are safe. Reject only a package/spec whose distribution itself is Torch.
    name = re.split(r"[<>=!~\[\s]", base, maxsplit=1)[0]
    name = Path(name).name
    if name.endswith(".whl"):
        parsed = parse_wheel_name(name)
        name = parsed.distribution if parsed else name
    return normalize_dist_name(name) in TORCH_READ_ONLY_PACKAGES


def assert_safe_pip_mutation(pip_args: Sequence[str]) -> None:
    if not pip_args:
        return
    command = pip_args[0]
    if command not in {"install", "uninstall"}:
        return
    for token in pip_args[1:]:
        if pip_target_is_torch_spec(str(token)):
            raise InstallerError("Safety rule: torch/torchvision/torchaudio may not be changed.")


def build_pip_install_args(wheel: Path) -> list[str]:
    args = ["install", "--no-deps", "--force-reinstall", str(wheel)]
    assert_safe_pip_mutation(args)
    return args


def install_wheel(py: Path, root: Path, wheel: Path) -> None:
    pip_args = build_pip_install_args(wheel)
    run_process(py, ["-s", "-B", "-m", "pip", *pip_args], cwd=root, timeout=900)


def remove_package(py: Path, root: Path, package: str, *, allow_failure: bool = False) -> None:
    pip_args = ["uninstall", "-y", package]
    assert_safe_pip_mutation(pip_args)
    run_process(
        py,
        ["-s", "-B", "-m", "pip", *pip_args],
        cwd=root,
        timeout=300,
        allow_failure=allow_failure,
    )


def install_python_dev(root: Path, archive: Path, python_mm: str) -> None:
    validate_python_dev_archive(archive, python_mm)
    temp = Path(tempfile.mkdtemp(prefix="pydev-", dir=str(archive.parent)))
    try:
        with zipfile.ZipFile(archive, "r") as zf:
            for info in zf.infolist():
                name = info.filename.rstrip("/")
                if not name:
                    continue
                pure = _safe_zip_member(name)
                if pure.parts[0].lower() not in {"include", "libs"}:
                    raise InstallerError(f"Unexpected Python developer archive content: {name}")
                dst = temp.joinpath(*pure.parts)
                if info.is_dir():
                    dst.mkdir(parents=True, exist_ok=True)
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info, "r") as src, dst.open("wb") as out:
                    shutil.copyfileobj(src, out)
        for name in ("include", "libs"):
            src = temp / name
            if not src.is_dir():
                raise InstallerError(f"Python developer archive is missing {name!r}.")
            dst = root / "python_embeded" / name
            dst.mkdir(parents=True, exist_ok=True)
            for item in src.rglob("*"):
                if item.is_file():
                    rel = item.relative_to(src)
                    target = dst / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(item, target)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def _remove_package_patterns(site_packages: Path, packages: Sequence[str]) -> None:
    for package in packages:
        for pattern in package_patterns(package):
            for path in site_packages.glob(pattern):
                try:
                    if path.is_dir():
                        shutil.rmtree(path, ignore_errors=True)
                    elif path.exists():
                        path.unlink(missing_ok=True)
                except OSError:
                    pass


def recover(root: Path, py: Path, env: EnvironmentInfo, plan: InstallPlan, backup_dir: Path) -> bool:
    print("\nRecovery")
    log("RECOVERY START")
    try:
        packages = mutated_packages(plan)
        for package in packages:
            remove_package(py, root, package, allow_failure=True)
        site_packages = Path(env.site_packages)
        _remove_package_patterns(site_packages, packages)

        snapshot = backup_dir / "site-packages"
        if snapshot.is_dir():
            for src in snapshot.iterdir():
                dst = site_packages / src.name
                if src.is_dir():
                    if dst.exists():
                        shutil.rmtree(dst, ignore_errors=True)
                    shutil.copytree(src, dst)
                else:
                    shutil.copy2(src, dst)

        if plan.python_dev == "INSTALL":
            saved_root = backup_dir / "python-dev"
            for name in ("include", "libs"):
                dst = root / "python_embeded" / name
                if dst.exists():
                    shutil.rmtree(dst, ignore_errors=True)
                saved = saved_root / name
                if saved.exists():
                    shutil.copytree(saved, dst)
        CONSOLE.ok("Previous managed-package state restored.")
        log("RECOVERY COMPLETE")
        return True
    except Exception:
        log("RECOVERY FAILED\n%s", traceback.format_exc())
        CONSOLE.warn(f"Automatic recovery was incomplete. Backup is preserved at {backup_dir}")
        return False


# -------------------------------- verification -------------------------------
TRITON_VERIFY = r'''
import torch
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
'''

SAGE2_VERIFY = r'''
import torch
import torch.nn.functional as F
from sageattention import sageattn
assert torch.cuda.is_available(), "CUDA is not available"
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
'''

SAGE3_VERIFY = r'''
import torch
import torch.nn.functional as F
from sageattn3 import sageattn3_blackwell
assert torch.cuda.is_available(), "CUDA is not available"
results = []
for dtype in (torch.float16, torch.bfloat16):
    q = torch.randn(1, 2, 256, 64, device="cuda", dtype=dtype)
    k = torch.randn_like(q)
    v = torch.randn_like(q)
    ref = F.scaled_dot_product_attention(q, k, v, is_causal=False)
    out = sageattn3_blackwell(q.clone(), k.clone(), v.clone(), is_causal=False)
    torch.cuda.synchronize()
    assert out.shape == ref.shape, f"SageAttention 3 {dtype} output shape mismatch"
    assert torch.isfinite(out).all(), f"SageAttention 3 {dtype} produced non-finite values"
    cos = F.cosine_similarity(out.float().flatten(), ref.float().flatten(), dim=0).item()
    assert cos > 0.90, f"SageAttention 3 {dtype} FP4 result is implausibly far from SDPA (cosine={cos:.6f})"
    results.append(f"{dtype} cosine={cos:.6f}")
print("SAGE3_OK " + "; ".join(results))
'''


def _show_child_output(proc: subprocess.CompletedProcess[str]) -> None:
    for line in proc.stdout.splitlines():
        if line.strip():
            CONSOLE.ok(line.strip())


def verify_install(root: Path, py: Path, before: EnvironmentInfo, plan: InstallPlan) -> None:
    triton = run_process(py, ["-s", "-B", "-c", TRITON_VERIFY], cwd=root, timeout=300)
    _show_child_output(triton)
    if plan.backend in {"Sage2", "Both"}:
        sage2 = run_process(py, ["-s", "-B", "-c", SAGE2_VERIFY], cwd=root, timeout=300)
        _show_child_output(sage2)
    if plan.backend in {"Sage3", "Both"}:
        sage3 = run_process(py, ["-s", "-B", "-c", SAGE3_VERIFY], cwd=root, timeout=300)
        _show_child_output(sage3)
    after = get_environment_info(py, root)
    if plan.legacy_triton == "REMOVE" and after.legacy_triton:
        raise InstallerError(
            f"Legacy triton is still installed after conflict removal ({after.legacy_triton})."
        )
    if after.torch_snapshot() != before.torch_snapshot():
        raise InstallerError(
            "Safety check failed: a read-only Torch package version changed. "
            f"Before={before.torch_snapshot()} After={after.torch_snapshot()}"
        )
    CONSOLE.ok("PyTorch, torchvision and torchaudio remained unchanged.")


# --------------------------------- runners -----------------------------------
def create_runner_file(root: Path, name: str, argument: str) -> bool:
    path = root / name
    if path.exists():
        CONSOLE.warn(f"{name} already exists; it was not overwritten.")
        return False
    content = (
        "@echo off\r\n"
        f".\\python_embeded\\python.exe -s ComfyUI\\main.py --windows-standalone-build {argument}\r\n"
        "pause\r\n"
    )
    path.write_text(content, encoding="ascii", newline="")
    CONSOLE.ok(f"Created {name}")
    return True


def create_runners(root: Path, plan: InstallPlan, caps: ComfyCapabilities) -> None:
    if plan.backend in {"Sage2", "Both"}:
        if caps.sage2_cli:
            create_runner_file(root, "run_nvidia_gpu_sageattention.bat", "--use-sage-attention")
        else:
            CONSOLE.warn("This ComfyUI build does not expose --use-sage-attention; no Sage2 runner was created.")
    if plan.backend in {"Sage3", "Both"}:
        if caps.sage3_cli:
            create_runner_file(root, "run_nvidia_gpu_sageattention3.bat", "--use-sage-attention3")
        else:
            CONSOLE.warn("This ComfyUI build has no global --use-sage-attention3 switch, so no Sage3 runner was created.")


def show_sage3_usage(caps: ComfyCapabilities) -> None:
    if caps.sage3_cli:
        CONSOLE.info("SageAttention 3 can be enabled globally by this ComfyUI build with --use-sage-attention3.")
    elif caps.sage3_registered:
        CONSOLE.info('ComfyUI registers the internal "sage3" backend, but this build has no global SA3 CLI switch.')
        if caps.kjnodes:
            CONSOLE.info("KJNodes detected: its Sage Attention patch mode can select SageAttention 3.")
        else:
            CONSOLE.info("Use a workflow/node that can select the registered sage3 backend; see README for details.")
    else:
        CONSOLE.warn("SageAttention 3 is installed and verified, but this ComfyUI build does not expose native sage3 registration.")
        if caps.kjnodes:
            CONSOLE.info("KJNodes detected and can provide SageAttention 3 selection.")
    CONSOLE.info("The SA3 test confirms that the kernel works on this system; it does not guarantee optimal quality for every model.")


# ----------------------------------- CLI -------------------------------------
def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="Install-SageAttention.py",
        description="Guided SageAttention 2/3 installer for ComfyUI Windows Portable.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--backend", choices=("auto", "sage2", "sage3", "both"), help="Backend to install. Omit for the guided menu.")
    parser.add_argument("--dry-run", action="store_true", help="Resolve and show the plan without writing files or changing packages.")
    parser.add_argument("--yes", action="store_true", help="Skip the final confirmation prompt.")
    parser.add_argument("--create-runner", action="store_true", help="Create supported ComfyUI runner .bat files after successful verification.")
    return parser.parse_args(argv)


def maybe_pause_for_double_click() -> None:
    if os.environ.get("SAGEATTN_DOUBLECLICK") == "1":
        try:
            input("\nPress Enter to close...")
        except EOFError:
            pass


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = Path(__file__).resolve().parent
    py = root / "python_embeded" / "python.exe"
    env_info: EnvironmentInfo | None = None
    plan: InstallPlan | None = None
    backup_dir: Path | None = None
    log_path: Path | None = None
    mutation_started = False
    recovered = False

    try:
        CONSOLE.banner()
        CONSOLE.phase(1, "Checking ComfyUI")
        assert_portable_root(root, py)
        caps = get_comfy_capabilities(root)
        CONSOLE.ok("ComfyUI Windows Portable layout detected.")

        CONSOLE.phase(2, "Detecting your hardware")
        env_info = get_environment_info(py, root)
        assert_base_environment(env_info)
        show_environment(env_info, caps)

        CONSOLE.phase(3, "Checking compatible SageAttention versions")
        # Fetch shared py-dev state once; both current backends require Triton.
        pydev = get_python_dev_state(root, env_info.python_mm)
        community_raw = fetch_json(COMMUNITY_INDEX_URL, max_bytes=4 * 1024 * 1024)
        community_index = community_raw if isinstance(community_raw, Mapping) else {}

        def resolver2(name: str, env: EnvironmentInfo) -> WheelCandidate | None:
            return resolve_backend_wheel(name, env, sage3=False, community_index=community_index)

        def resolver3(name: str, env: EnvironmentInfo) -> WheelCandidate | None:
            return resolve_backend_wheel(name, env, sage3=True, community_index=community_index)

        sage2_eval = evaluate_sage2(env_info, root, wheel_resolver=resolver2, pydev_state=pydev)
        sage3_eval = evaluate_sage3(env_info, root, wheel_resolver=resolver3, pydev_state=pydev)
        show_backend_status("SageAttention 2.2", sage2_eval)
        show_backend_status("SageAttention 3", sage3_eval)
        recommended = get_recommendation(env_info, sage2_eval, sage3_eval)
        if not recommended:
            raise InstallerError(f"No compatible backend was found. Sage2: {sage2_eval.reason} Sage3: {sage3_eval.reason}")
        CONSOLE.info(f"Recommendation: {recommended}")

        CONSOLE.phase(4, "Choose what to install")
        selected = select_backend(args.backend, recommended, sage2_eval, sage3_eval, env_info)
        if not selected:
            CONSOLE.info("Cancelled. Nothing was changed.")
            return 0
        assert_backend_available(selected, sage2_eval, sage3_eval)

        CONSOLE.phase(5, "Preparing installation")
        plan = new_plan(selected, env_info, sage2_eval, sage3_eval)
        show_plan(plan)

        if args.dry_run:
            CONSOLE.ok("Dry run complete. No files, logs, backups, downloads, runners or packages were changed.")
            return 0

        if not args.yes:
            try:
                answer = input("Proceed with this installation? [Y/n]: ").strip()
            except EOFError:
                raise InstallerError("Interactive confirmation is unavailable; rerun with --yes if appropriate.")
            if answer and answer.lower() not in {"y", "yes"}:
                CONSOLE.info("Cancelled. Nothing was changed.")
                return 0

        log_path = start_log(root)
        log("Environment: %s", safe_json(dataclasses.asdict(env_info)))
        log("ComfyUI capabilities: %s", safe_json(dataclasses.asdict(caps)))
        log("Recommendation: %s", recommended)
        log("Selected backend: %s", selected)
        log("Plan: %s", safe_json(dataclasses.asdict(plan)))

        staged = StagedFiles()
        if plan.has_changes():
            backup_dir = backup_state(root, py, env_info, plan)
            staged = stage_files(plan, env_info, backup_dir)
        else:
            CONSOLE.ok("All selected components are already installed at compatible versions.")

        CONSOLE.phase(6, "Installing")
        if plan.has_changes():
            mutation_started = True
            if plan.python_dev == "INSTALL":
                CONSOLE.info("Installing embedded Python developer include/libs...")
                assert staged.python_dev is not None
                install_python_dev(root, staged.python_dev, env_info.python_mm)
            if plan.legacy_triton == "REMOVE":
                CONSOLE.info("Removing conflicting legacy triton package...")
                remove_package(py, root, "triton")
            if plan.triton == "INSTALL":
                CONSOLE.info("Installing Triton-Windows...")
                assert staged.triton is not None
                install_wheel(py, root, staged.triton)
            if plan.sage2 == "INSTALL":
                CONSOLE.info("Installing SageAttention 2.2...")
                assert staged.sage2 is not None
                install_wheel(py, root, staged.sage2)
            if plan.sage3 == "INSTALL":
                CONSOLE.info("Installing SageAttention 3...")
                assert staged.sage3 is not None
                install_wheel(py, root, staged.sage3)
            CONSOLE.ok("Selected package changes installed.")
        else:
            CONSOLE.info("No package changes required.")

        CONSOLE.phase(7, "Testing GPU acceleration")
        verify_install(root, py, env_info, plan)
        if args.create_runner:
            try:
                create_runners(root, plan, caps)
            except Exception as exc:
                log("Optional runner creation failed: %s\n%s", exc, traceback.format_exc())
                CONSOLE.warn(f"Optional runner creation failed: {exc}")

        if backup_dir:
            (backup_dir / "result.json").write_text(safe_json({"status": "committed", "backend": plan.backend, "torch_snapshot": env_info.torch_snapshot()}), encoding="utf-8")
        log("COMMIT SUCCESS")

        CONSOLE.phase(8, "Done")
        CONSOLE.ok("Installation completed and GPU verification passed.")
        if plan.backend in {"Sage3", "Both"}:
            show_sage3_usage(caps)
        if backup_dir:
            CONSOLE.info(f"Backup: {backup_dir}")
        if log_path:
            CONSOLE.info(f"Log: {log_path}")
        return 0

    except Exception as exc:
        if LOGGER is not None:
            log("FATAL %s\n%s", exc, traceback.format_exc())
        if mutation_started and backup_dir and env_info and plan:
            recovered = recover(root, py, env_info, plan, backup_dir)
        print("\nInstallation could not be completed.")
        print("\nReason:")
        print(f"  {exc}")
        print()
        if not mutation_started:
            print("Nothing was changed.")
        elif recovered:
            print("The installer rolled back the managed changes.")
        else:
            print("Automatic recovery may be incomplete; keep the backup directory for inspection.")
        if log_path:
            print(f"\nLog:\n  {log_path}")
        return 1
    finally:
        maybe_pause_for_double_click()


if __name__ == "__main__":
    raise SystemExit(main())
