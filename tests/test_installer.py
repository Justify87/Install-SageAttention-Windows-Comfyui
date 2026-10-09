from __future__ import annotations

import ast
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Install-SageAttention.py"
SPEC = importlib.util.spec_from_file_location("sage_installer", SCRIPT)
assert SPEC and SPEC.loader
installer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)


def make_env(
    *,
    cc="8.6",
    python_mm="3.13",
    torch="2.10.0+cu128",
    cuda="12.8",
    triton_windows=None,
    legacy_triton=None,
    sageattention=None,
    sageattn3=None,
):
    return installer.EnvironmentInfo(
        python=python_mm + ".7",
        python_mm=python_mm,
        python_bits=64,
        cp="cp" + python_mm.replace(".", ""),
        executable=r"C:\ComfyUI\python_embeded\python.exe",
        site_packages=r"C:\ComfyUI\python_embeded\Lib\site-packages",
        torch=torch,
        torchvision="0.25.0+cu128",
        torchaudio="2.10.0+cu128",
        cuda=cuda,
        cuda_ok=True,
        gpu="Test GPU",
        cc=cc,
        vram_gb=16.0,
        triton_windows=triton_windows,
        legacy_triton=legacy_triton,
        sageattention=sageattention,
        sageattn3=sageattn3,
        architecture=installer.get_architecture(cc),
    )


def wheel(package, version, *, source="Comfy-Org/wheels", community=False):
    py = "cp313"
    return installer.WheelCandidate(
        url=f"https://github.com/example/{package}-{version}-{py}-{py}-win_amd64.whl",
        name=f"{package}-{version}-{py}-{py}-win_amd64.whl",
        version=version,
        source=source,
        community=community,
    )


def evaluation(package, version, *, triton_minor="3.6", pydev=None, source="Comfy-Org/wheels", community=False):
    return installer.BackendEvaluation(
        True,
        None,
        wheel(package, version, source=source, community=community),
        triton_minor,
        pydev or installer.PythonDevState(True),
    )


class ParityFixtureTests(unittest.TestCase):
    def test_expected_python_and_powershell_matrices_match(self):
        data = json.loads((ROOT / "tests" / "resolver_fixtures.json").read_text("utf-8"))
        for row in data["scenarios"]:
            with self.subTest(row=row["name"]):
                self.assertEqual(row["python_expected"], row["powershell_expected"])
                env = make_env(cc=row["cc"], python_mm=row["python"], torch=row["torch"], cuda=row["cuda"])
                s2 = installer.BackendEvaluation(row["sage2_available"], None, None, row["triton_minor"], None)
                s3 = installer.BackendEvaluation(row["sage3_available"], None, None, row["triton_minor"], None)
                self.assertEqual(installer.get_recommendation(env, s2, s3), row["python_expected"])
                self.assertEqual(installer.get_triton_minor(env.torch), row["triton_minor"])

    def test_full_triton_matrix(self):
        expected = {
            "2.4":"3.1", "2.5":"3.1", "2.6":"3.2", "2.7":"3.3", "2.8":"3.4",
            "2.9":"3.5", "2.10":"3.6", "2.11":"3.6", "2.12":"3.7", "2.13":"3.7", "2.14":"3.8",
        }
        self.assertEqual(installer.TRITON_BY_TORCH_MINOR, expected)


class HardwareTests(unittest.TestCase):
    def test_ampere_ada_hopper_sage2(self):
        for cc, cuda in [("8.6", "12.0"), ("8.9", "12.4"), ("9.0", "12.3")]:
            with self.subTest(cc=cc):
                self.assertIsNone(installer.test_sage2_hardware(make_env(cc=cc, cuda=cuda)))

    def test_sage3_python_support_is_resolver_driven(self):
        # Current Comfy-Org SA3 wheels include multiple CPython minors, so Python
        # compatibility is resolved from wheel/build metadata rather than a hard
        # installer floor. Hardware/runtime requirements still apply.
        self.assertIsNone(installer.test_sage3_hardware(make_env(cc="12.0", python_mm="3.12", torch="2.9.0", cuda="12.8")))
        self.assertIsNone(installer.test_sage3_hardware(make_env(cc="12.0", python_mm="3.13", torch="2.9.0", cuda="12.8")))


class BackendEvaluationTests(unittest.TestCase):
    def test_blackwell_without_matching_sage3_wheel_is_unavailable(self):
        env = make_env(cc="12.0", torch="2.10.0", cuda="12.8")
        result = installer.evaluate_sage3(
            env, ROOT, wheel_resolver=lambda _name, _env: None, pydev_state=installer.PythonDevState(True)
        )
        self.assertFalse(result.supported)
        self.assertIn("No compatible SageAttention 3 Windows wheel", result.reason)


class WheelTagTests(unittest.TestCase):
    def test_exact_cpython_wheel(self):
        name = "sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        self.assertTrue(installer.python_tag_matches(name, "3.13", allow_abi3=True))
        self.assertFalse(installer.python_tag_matches(name, "3.12", allow_abi3=True))

    def test_abi3_sage2(self):
        name = "sageattention-2.2.0+cu128torch210-cp310-abi3-win_amd64.whl"
        self.assertTrue(installer.python_tag_matches(name, "3.13", allow_abi3=True))
        self.assertFalse(installer.python_tag_matches(name, "3.13", allow_abi3=False))

    def test_no_cuda_minor_alias(self):
        name = "sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        self.assertTrue(installer.cuda_tag_matches(name, "12.8"))
        self.assertFalse(installer.cuda_tag_matches(name, "12.9"))

    def test_compressed_and_dotted_torch_tags(self):
        compact = "sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        dotted = "sageattention-2.2.0+cu128torch2.10-cp313-cp313-win_amd64.whl"
        self.assertTrue(installer.torch_tag_matches(compact, "2.10.1+cu128"))
        self.assertTrue(installer.torch_tag_matches(dotted, "2.10.1+cu128"))
        self.assertFalse(installer.torch_tag_matches(compact, "2.11.0+cu128"))

    def test_comfy_build_matrix_architecture_override(self):
        env = make_env(cc="12.0", torch="2.10.0", cuda="12.8")
        spec = """name: sageattn3
arch_list: \"10.0 12.0\"
build_matrix:
  combinations:
    - cuda: \"12.8\"
      pytorch: \"2.10.0\"
      python_versions: [\"3.12\", \"3.13\"]
      arch_list: \"12.0\"
  platforms: [\"linux\", \"windows\"]
"""
        self.assertEqual(installer.parse_comfy_build_spec(spec, env), ["12.0"])
        self.assertTrue(installer.arch_list_supports(["12.0"], "12.0", strict_minor=True))
        self.assertFalse(installer.arch_list_supports(["12.0"], "12.1", strict_minor=True))

    def test_official_wheel_has_priority_over_community(self):
        env = make_env()
        spec = """name: sageattention
arch_list: \"8.0 9.0\"
build_matrix:
  combinations:
    - cuda: \"12.8\"
      pytorch: \"2.10.0\"
      python_versions: [\"3.13\"]
  platforms: [\"windows\"]
"""
        filename = "sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        def fetcher(url):
            return spec if url.endswith("sageattention.yml") else f'<a href="{filename}">{filename}</a>'
        community = {"packages":[{"id":"sageattention","wheels":[{
            "package_version":"2.2.0", "torch_version":["2.10","2.10"],
            "python_version":["3.13","3.13"], "cuda_version":["12.8","12.8"],
            "url":"https://github.com/wildminder/AI-windows-whl/releases/download/test/" + filename
        }]}]}
        found = installer.resolve_backend_wheel("sageattention", env, official_fetcher=fetcher, community_index=community)
        self.assertIsNotNone(found)
        self.assertEqual(found.source, "Comfy-Org/wheels")
        self.assertFalse(found.community)

    def test_community_fallback_and_ranges(self):
        env = make_env()
        index = {"packages":[{"id":"sageattention","name":"sageattention","wheels":[{
            "package_version":"2.2.0",
            "torch_version":["2.9", "2.10.99"],
            "python_version":["3.12", "3.13.99"],
            "cuda_version":["12.8", "12.8"],
            "url":"https://github.com/wildminder/AI-windows-whl/releases/download/test/sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        }]}]}
        found = installer.resolve_community_wheel("sageattention", env, index_data=index)
        self.assertIsNotNone(found)
        self.assertTrue(found.community)
        self.assertEqual(found.source, "wildminder/AI-windows-whl")

    def test_community_rejects_cuda_alias_even_when_range_matches(self):
        env = make_env(cuda="12.9")
        index = {"packages":[{"id":"sageattention","wheels":[{
            "package_version":"2.2.0", "torch_version":["2.10", "2.10"],
            "python_version":["3.13", "3.13"], "cuda_version":["12.8", "12.9"],
            "url":"https://github.com/wildminder/AI-windows-whl/releases/download/test/sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"
        }]}]}
        self.assertIsNone(installer.resolve_community_wheel("sageattention", env, index_data=index))


class PlanTests(unittest.TestCase):
    def fake_triton(self, env, minor):
        return installer.WheelCandidate(
            url="https://files.pythonhosted.org/packages/triton_windows.whl",
            name=f"triton_windows-{minor}.1-cp313-cp313-win_amd64.whl",
            version=f"{minor}.1",
            source="PyPI/triton-windows",
        )

    def test_existing_compatible_triton_is_kept(self):
        env = make_env(triton_windows="3.6.0.post20")
        s2 = evaluation("sageattention", "2.2.0+cu128torch210")
        plan = installer.new_plan("Sage2", env, s2, installer.BackendEvaluation(False,"n/a",None,None,None), triton_resolver=self.fake_triton)
        self.assertEqual(plan.triton, "KEEP")

    def test_legacy_triton_forces_remove_and_triton_windows_reinstall(self):
        env = make_env(triton_windows="3.6.0.post20", legacy_triton="3.6.0")
        s2 = evaluation("sageattention", "2.2.0+cu128torch210")
        plan = installer.new_plan("Sage2", env, s2, installer.BackendEvaluation(False,"n/a",None,None,None), triton_resolver=self.fake_triton)
        self.assertEqual(plan.legacy_triton, "REMOVE")
        self.assertEqual(plan.triton, "INSTALL")

    def test_existing_sage2_and_sage3_versions_are_kept(self):
        env = make_env(cc="12.0", triton_windows="3.6.1", sageattention="2.2.0+cu128torch210", sageattn3="1.0.0+cu128torch210")
        s2 = evaluation("sageattention", "2.2.0+cu128torch210")
        s3 = evaluation("sageattn3", "1.0.0+cu128torch210")
        plan = installer.new_plan("Both", env, s2, s3, triton_resolver=self.fake_triton)
        self.assertEqual(plan.sage2, "KEEP")
        self.assertEqual(plan.sage3, "KEEP")

    def test_both_partial_preinstall(self):
        env = make_env(cc="12.0", triton_windows="3.6.1", sageattention="2.2.0+cu128torch210", sageattn3=None)
        s2 = evaluation("sageattention", "2.2.0+cu128torch210")
        s3 = evaluation("sageattn3", "1.0.0+cu128torch210")
        plan = installer.new_plan("Both", env, s2, s3, triton_resolver=self.fake_triton)
        self.assertEqual(plan.sage2, "KEEP")
        self.assertEqual(plan.sage3, "INSTALL")


class ProcessSafetyTests(unittest.TestCase):
    def test_installer_process_does_not_block_itself(self):
        target = r"C:\ComfyUI\python_embeded\python.exe"
        items = [installer.ProcessInfo(123, target)]
        self.assertEqual(installer.find_conflicting_embedded_python_processes(target, current_pid=123, process_iter=items), [])

    def test_second_embedded_python_process_blocks(self):
        target = r"C:\ComfyUI\python_embeded\python.exe"
        items = [installer.ProcessInfo(123, target), installer.ProcessInfo(456, target)]
        result = installer.find_conflicting_embedded_python_processes(target, current_pid=123, process_iter=items)
        self.assertEqual([p.pid for p in result], [456])


class MutationSafetyTests(unittest.TestCase):
    def test_sage_install_uses_no_deps_and_never_targets_torch(self):
        args = installer.build_pip_install_args(Path("sageattention-2.2.0+cu128torch210-cp313-cp313-win_amd64.whl"))
        self.assertIn("--no-deps", args)
        self.assertNotIn("torch", [x.lower() for x in args])

    def test_torch_mutation_is_rejected(self):
        for package in ("torch", "torchvision>=1", "torchaudio"):
            with self.subTest(package=package), self.assertRaises(installer.InstallerError):
                installer.assert_safe_pip_mutation(["install", package])

    def test_child_probes_keep_site_packages_and_disable_bytecode(self):
        with mock.patch.object(installer, "run_process") as rp:
            rp.return_value = types.SimpleNamespace(stdout="ok\n", returncode=0)
            out = installer.run_python_code(Path("python.exe"), ROOT, "print('ok')")
            self.assertEqual(out, "ok")
            args = rp.call_args.args[1]
            self.assertEqual(args[:2], ["-s", "-B"])
            self.assertNotIn("-S", args)


class FileSafetyTests(unittest.TestCase):
    def _write_wheel(self, path: Path, *, traversal=False):
        with zipfile.ZipFile(path, "w") as zf:
            if traversal:
                zf.writestr("../escape.txt", "x")
            zf.writestr("sageattention-2.2.0.dist-info/METADATA", "Name: sageattention\nVersion: 2.2.0\n")
            zf.writestr("sageattention-2.2.0.dist-info/WHEEL", "Wheel-Version: 1.0\nTag: cp313-cp313-win_amd64\n")

    def test_wheel_zip_metadata_validation(self):
        env = make_env()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "sageattention-2.2.0-cp313-cp313-win_amd64.whl"
            self._write_wheel(path)
            installer.validate_wheel(path, "sageattention", "2.2.0", env, allow_abi3=True)

    def test_wheel_path_traversal_is_rejected(self):
        env = make_env()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "sageattention-2.2.0-cp313-cp313-win_amd64.whl"
            self._write_wheel(path, traversal=True)
            with self.assertRaises(installer.InstallerError):
                installer.validate_wheel(path, "sageattention", "2.2.0", env, allow_abi3=True)

    def test_runner_never_overwrites(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "run_nvidia_gpu_sageattention.bat"
            target.write_text("ORIGINAL", encoding="ascii")
            self.assertFalse(installer.create_runner_file(root, target.name, "--use-sage-attention"))
            self.assertEqual(target.read_text("ascii"), "ORIGINAL")


class DryRunRuntimeTests(unittest.TestCase):
    def test_dry_run_calls_no_mutating_functions_and_creates_no_repo_files(self):
        env = make_env(triton_windows="3.6.1")
        s2 = evaluation("sageattention", "2.2.0+cu128torch210")
        s3 = installer.BackendEvaluation(False, "Blackwell only", None, None, None)
        caps = installer.ComfyCapabilities(False, False, False, True, False)
        before = {p.relative_to(ROOT) for p in ROOT.rglob("*")}
        with mock.patch.object(installer, "assert_portable_root"), \
             mock.patch.object(installer, "get_comfy_capabilities", return_value=caps), \
             mock.patch.object(installer, "get_environment_info", return_value=env), \
             mock.patch.object(installer, "assert_base_environment"), \
             mock.patch.object(installer, "get_python_dev_state", return_value=installer.PythonDevState(True)), \
             mock.patch.object(installer, "fetch_json", return_value={}), \
             mock.patch.object(installer, "evaluate_sage2", return_value=s2), \
             mock.patch.object(installer, "evaluate_sage3", return_value=s3), \
             mock.patch.object(installer, "start_log") as start_log, \
             mock.patch.object(installer, "backup_state") as backup, \
             mock.patch.object(installer, "stage_files") as stage, \
             mock.patch.object(installer, "download_file") as download, \
             mock.patch.object(installer, "install_wheel") as install, \
             mock.patch.object(installer, "create_runners") as runners:
            with mock.patch("builtins.print"):
                rc = installer.main(["--backend", "auto", "--dry-run", "--create-runner"])
        self.assertEqual(rc, 0)
        for mocked in (start_log, backup, stage, download, install, runners):
            mocked.assert_not_called()
        after = {p.relative_to(ROOT) for p in ROOT.rglob("*")}
        self.assertEqual(before, after)


class StaticArchitectureTests(unittest.TestCase):
    def test_main_process_has_no_native_package_imports(self):
        tree = ast.parse(SCRIPT.read_text("utf-8"))
        banned = {"torch", "triton", "sageattention", "sageattn3"}
        imported = set()
        for node in tree.body:
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
        self.assertTrue(banned.isdisjoint(imported), imported & banned)

    def test_dry_run_guard_is_before_log_backup_stage_and_runner_mutations(self):
        source = SCRIPT.read_text("utf-8")
        main_source = source[source.index("def main("):]
        guard = main_source.index("if args.dry_run:")
        self.assertLess(guard, main_source.index("start_log(root)"))
        self.assertLess(guard, main_source.index("backup_state(root"))
        self.assertLess(guard, main_source.index("stage_files(plan"))
        self.assertLess(guard, main_source.index("create_runners(root"))
        self.assertIn("sys.dont_write_bytecode = True", source)

    def test_bat_launcher_only_delegates_to_embedded_python(self):
        bat = (ROOT / "Install-SageAttention-Python.bat").read_text("utf-8")
        self.assertIn(r'"python_embeded\python.exe" -S -B "Install-SageAttention.py" %*', bat)
        for forbidden in ("pip install", "triton-windows", "sageattention-"):
            self.assertNotIn(forbidden.lower(), bat.lower())


if __name__ == "__main__":
    unittest.main()
