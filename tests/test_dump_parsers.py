import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("analyze_dump", ROOT / "analyze-dump.py")
assert SPEC is not None and SPEC.loader is not None
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)

DRIVER_LIST = 0x2100
DRIVER_BASE = 0xFFFFF80500000000
KERNEL_BASE = 0xFFFFF80000000000


def make_dump(stack_offset=0x2FF0, stack_size=16):
    data = bytearray(0x3000)
    data[:8] = b"PAGEDU64"
    struct.pack_into("<I", data, 0x38, 0xC4)
    struct.pack_into(
        "<4Q", data, 0x40, DRIVER_BASE + 0x34, 0x1234, 0, DRIVER_BASE + 0x44
    )
    struct.pack_into("<IIII", data, 0x2028, stack_offset, stack_size, DRIVER_LIST, 2)

    for index, (base, name, name_offset) in enumerate(
        ((DRIVER_BASE, "example.sys", 0x2300), (KERNEL_BASE, "ntoskrnl.exe", 0x2400))
    ):
        entry = DRIVER_LIST + index * 144
        encoded = name.encode("utf-16-le")
        struct.pack_into("<Q", data, entry, name_offset)
        struct.pack_into("<Q", data, entry + 0x38, base)
        struct.pack_into("<I", data, entry + 0x48, 0x1000)
        struct.pack_into("<I", data, name_offset, len(name))
        data[name_offset + 4:name_offset + 4 + len(encoded)] = encoded

    struct.pack_into("<QQ", data, stack_offset, KERNEL_BASE + 0x20, DRIVER_BASE + 0x30)
    return data


def incomplete_driver_list():
    data = make_dump()
    struct.pack_into("<II", data, 0x2030, len(data) - 100, 1)
    return data


def truncated_driver_name():
    data = make_dump(stack_offset=0x2FE0)
    name_offset = len(data) - 6
    struct.pack_into("<Q", data, DRIVER_LIST, name_offset)
    struct.pack_into("<I", data, name_offset, 8)
    data[-2:] = b"x\x00"
    return data


def truncated_stack():
    data = make_dump(stack_offset=0x2FE0)
    struct.pack_into("<II", data, 0x2028, len(data) - 8, 16)
    struct.pack_into("<Q", data, len(data) - 8, DRIVER_BASE + 0x30)
    return data


class PythonDumpParserTests(unittest.TestCase):
    def analyze(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.dmp"
            path.write_bytes(data)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                analyzer.analyze(str(path))
            return output.getvalue()

    def test_valid_dump_resolves_last_stack_entry_at_end_of_file(self):
        output = self.analyze(make_dump())
        self.assertIn("Bugcheck : 0xC4  DRIVER_VERIFIER_DETECTED_VIOLATION", output)
        self.assertIn("param1 -> example.sys +0x34", output)
        self.assertIn("Fault address -> example.sys +0x44", output)
        self.assertIn(f"0x{KERNEL_BASE + 0x20:016x}", output)
        self.assertIn(f"0x{DRIVER_BASE + 0x30:016x}", output)
        self.assertIn("third-party driver(s) on the stack: example.sys", output)

    def test_stack_size_does_not_include_a_partial_frame(self):
        output = self.analyze(make_dump(stack_offset=0x2FE0, stack_size=9))
        self.assertIn(f"0x{KERNEL_BASE + 0x20:016x}", output)
        self.assertNotIn(f"0x{DRIVER_BASE + 0x30:016x}", output)
        self.assertIn("no third-party driver captured", output)

        output = self.analyze(truncated_stack())
        self.assertIn(f"0x{DRIVER_BASE + 0x30:016x}", output)
        self.assertIn("third-party driver(s) on the stack: example.sys", output)

    def test_bad_signature_and_truncated_files_are_reported(self):
        invalid = make_dump()
        invalid[:8] = b"NOTADUMP"
        self.assertIn("Not a 64-bit kernel dump", self.analyze(invalid))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = make_dump()
            paths = [root / name for name in ("header.dmp", "triage.dmp", "valid.dmp")]
            for path, data in zip(paths, (valid[:0x50], valid[:0x2020], valid)):
                path.write_bytes(data)
            result = subprocess.run(
                [sys.executable, str(ROOT / "analyze-dump.py"), *(str(p) for p in paths)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.stdout.count("Failed to parse:"), 2, result.stdout)
            self.assertIn("valid.dmp", result.stdout)
            self.assertIn("third-party driver(s) on the stack: example.sys", result.stdout)
            self.assertNotIn("Traceback", result.stderr)

    def test_truncated_driver_metadata_is_not_used(self):
        self.assertIn("No module list recovered", self.analyze(incomplete_driver_list()))

        data = truncated_driver_name()
        modules = analyzer.read_modules(data, DRIVER_LIST, 2)
        driver = next(module for module in modules if module[0] == DRIVER_BASE)
        self.assertEqual(driver[2], "")
        self.assertNotIn("third-party driver(s) on the stack: x", self.analyze(data))

        data = make_dump(stack_offset=0x2F00)
        name = "edge.sys"
        encoded = name.encode("utf-16-le")
        name_offset = len(data) - 4 - len(encoded)
        struct.pack_into("<Q", data, DRIVER_LIST, name_offset)
        struct.pack_into("<I", data, name_offset, len(name))
        data[name_offset + 4:] = encoded
        modules = analyzer.read_modules(data, DRIVER_LIST, 2)
        driver = next(module for module in modules if module[0] == DRIVER_BASE)
        self.assertEqual(driver[2], name)


@unittest.skipUnless(os.name == "nt", "Windows PowerShell is required")
class PowerShellDumpParserTests(unittest.TestCase):
    def run_watcher(self, fixtures):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "watch-dumps.ps1"
            shutil.copyfile(ROOT / "watch-dumps.ps1", script)
            dumps = root / "minidumps"
            wer = root / "wer"
            dumps.mkdir()
            wer.mkdir()
            for name, data in fixtures.items():
                (dumps / name).write_bytes(data)
            result = subprocess.run(
                [
                    "powershell.exe", "-NoProfile", "-NonInteractive",
                    "-ExecutionPolicy", "Bypass", "-File", str(script),
                    "-Once", "-ReportExisting", "-DumpDir", str(dumps), "-WerRoot", str(wer),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            diag = root / "diag"
            log = (diag / "watcher.log").read_text(encoding="utf-8-sig")
            reports = {
                path.name: path.read_text(encoding="utf-8-sig")
                for path in (diag / "reports").glob("*.txt")
            }
            return log, reports

    def run_peek(self, data):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "peek-livedump.ps1"
            shutil.copyfile(ROOT / "peek-livedump.ps1", script)
            windows = root / "windows"
            dumps = windows / "LiveKernelReports"
            dumps.mkdir(parents=True)
            (dumps / "synthetic.dmp").write_bytes(data)
            env = os.environ.copy()
            env["STOPCODE_TEST_ROOT"] = str(windows)
            env["STOPCODE_TEST_SCRIPT"] = str(script)
            command = (
                "$env:SystemRoot = $env:STOPCODE_TEST_ROOT; "
                "function Start-Sleep { param([int]$Seconds) }; & $env:STOPCODE_TEST_SCRIPT"
            )
            result = subprocess.run(
                [
                    "powershell.exe", "-NoProfile", "-NonInteractive",
                    "-ExecutionPolicy", "Bypass", "-Command", command,
                ],
                capture_output=True,
                text=True,
                env=env,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return (root / "peek-livedump.txt").read_text(encoding="utf-8-sig")

    def test_watcher_resolves_last_frame_at_end_of_file(self):
        _, reports = self.run_watcher({"valid.dmp": make_dump()})
        report = reports["crash-valid.txt"]
        self.assertIn("Bugcheck  : 0xC4  DRIVER_VERIFIER_DETECTED_VIOLATION", report)
        self.assertIn("param1 -> example.sys +0x34", report)
        self.assertIn("Fault address -> example.sys +0x44", report)
        self.assertIn(f"0x{KERNEL_BASE + 0x20:016x}", report)
        self.assertIn(f"0x{DRIVER_BASE + 0x30:016x}", report)
        self.assertIn("example.sys", report)
        self.assertIn("<-- THIRD PARTY", report)

    def test_watcher_respects_declared_stack_size(self):
        _, reports = self.run_watcher(
            {
                "partial-frame.dmp": make_dump(stack_offset=0x2FE0, stack_size=9),
                "short-stack.dmp": truncated_stack(),
            }
        )
        report = reports["crash-partial-frame.txt"]
        self.assertIn(f"0x{KERNEL_BASE + 0x20:016x}", report)
        self.assertNotIn(f"0x{DRIVER_BASE + 0x30:016x}", report)
        self.assertNotIn("<-- THIRD PARTY", report)
        self.assertIn(f"0x{DRIVER_BASE + 0x30:016x}", reports["crash-short-stack.txt"])

    def test_watcher_rejects_bad_headers_and_handles_incomplete_driver_list(self):
        valid = make_dump()
        invalid = bytearray(valid)
        invalid[:8] = b"NOTADUMP"
        log, reports = self.run_watcher(
            {
                "bad-signature.dmp": invalid,
                "short-header.dmp": valid[:0x50],
                "short-triage.dmp": valid[:0x2020],
                "partial-drivers.dmp": incomplete_driver_list(),
            }
        )
        self.assertIn("FAILED to parse bad-signature.dmp", log)
        self.assertIn("missing PAGEDU64 signature", log)
        self.assertIn("FAILED to parse short-header.dmp", log)
        self.assertIn("FAILED to parse short-triage.dmp", log)
        self.assertEqual(log.count("File too small to be a kernel dump."), 2)
        self.assertEqual(list(reports), ["crash-partial-drivers.txt"])
        self.assertIn("Modules   : 0", reports["crash-partial-drivers.txt"])

    def test_watcher_does_not_name_a_truncated_driver(self):
        _, reports = self.run_watcher({"partial-name.dmp": truncated_driver_name()})
        report = reports["crash-partial-name.txt"]
        self.assertNotIn("<-- THIRD PARTY", report)
        self.assertNotIn("VERIFIER NAMED THE OFFENDER", report)
        self.assertNotIn("Fault address ->", report)
        self.assertIn("no third-party driver captured", report)

    def test_peek_reads_valid_header_and_rejects_bad_signature(self):
        valid = make_dump()
        struct.pack_into("<I", valid, 0x2034, 16)
        output = self.run_peek(valid)
        self.assertIn("bugcheck       : 0xC4  DRIVER_VERIFIER_DETECTED_VIOLATION", output)
        self.assertIn(f"0x{DRIVER_BASE + 0x44:016x}", output)
        self.assertIn("TRIAGE SECTION LOOKS PRESENT", output)

        valid[:8] = b"NOTADUMP"
        output = self.run_peek(valid)
        self.assertIn("not a 64-bit kernel dump", output)
        self.assertNotIn("bugcheck       :", output)

    def test_peek_reports_truncated_header_and_triage(self):
        valid = make_dump()
        for size in (0, 0x50, 0x1FFF):
            with self.subTest(size=size):
                output = self.run_peek(valid[:size])
                self.assertIn("truncated dump header", output)
                self.assertNotIn("bugcheck       :", output)

        for size in (0x2000, 0x2037):
            with self.subTest(size=size):
                output = self.run_peek(valid[:size])
                self.assertIn("bugcheck       : 0xC4", output)
                self.assertIn("triage section probe: unavailable (truncated dump)", output)
                self.assertNotIn("no triage section", output)

        output = self.run_peek(valid[:0x2038])
        self.assertIn("triage section probe:", output)
        self.assertNotIn("triage section probe: unavailable", output)


if __name__ == "__main__":
    unittest.main()
