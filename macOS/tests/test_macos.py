#!/usr/bin/env python3
"""macOS 回归测试：仅操作临时文件和测试进程，不改变真实窗口或 Karabiner 配置。"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MacOSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="capslock-pro-tests-")
        cls.directory = Path(cls.scratch.name)
        cls.binary = cls.directory / "move-window-display"
        source = ROOT / "macOS/src/move-window-display.swift"
        subprocess.run(["swiftc", "-O", "-warnings-as-errors", str(source), "-o", str(cls.binary)], check=True)
        helpers = cls.directory / "helpers.swift"
        helpers.write_text(source.read_text().split("// MARK: - Arguments")[0]
                           + (ROOT / "macOS/tests/helpers.swift").read_text())
        cls.harness = cls.directory / "helpers"
        subprocess.run(["swiftc", "-warnings-as-errors", str(helpers), "-o", str(cls.harness)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def run_command(self, args, **kwargs):
        return subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)

    def wait_for(self, path):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_size:
                return path.read_text()
            time.sleep(0.02)
        self.fail(f"Timed out waiting for {path}")

    def test_geometry(self):
        result = self.run_command([self.harness, "geometry"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_arguments_and_shell_syntax(self):
        for args, expected in [(["--help"], 0), (["--background", "--help"], 0),
                               (["invalid"], 2), (["--background", "invalid"], 2), (["next", "extra"], 2)]:
            result = self.run_command([self.binary, *args])
            self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(self.run_command(["bash", "-n", ROOT / "macOS/update.sh"]).returncode, 0)

    def test_importable_rules_use_background(self):
        rules = json.loads((ROOT / "macOS/Karabiner-Elements.json").read_text())
        commands = [event["shell_command"] for rule in rules["rules"]
                    for manipulator in rule["manipulators"] for event in manipulator.get("to", [])
                    if "move-window-display" in event.get("shell_command", "")]
        self.assertEqual(len(commands), 7)
        self.assertTrue(all('" --background ' in command for command in commands))

    def test_custom_install_and_migration(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as directory:
            directory = Path(directory)
            # 同时覆盖相对路径、空格、单引号和 shell 展开字符。
            bin_dir = directory / "bin ' \" $(touch INJECTED) `touch INJECTED`"
            bin_dir.mkdir()
            binary = bin_dir / "move-window-display"
            shutil.copy2(self.binary, binary)
            config_path = directory / "karabiner.json"
            source = json.loads((ROOT / "macOS/Karabiner-Elements.json").read_text())
            old_rules = json.loads(json.dumps(source["rules"]))
            old_rules[0]["description"] = "CAPSLOCK + hjkl to arrow keys (Post CAPSLOCK if press CAPSLOCK alone)"
            custom = {"description": "Unrelated", "manipulators": []}
            config = {"profiles": [
                {"selected": True, "complex_modifications": {"rules": [custom] + old_rules}},
                {"selected": False, "complex_modifications": {"rules": [custom]}}
            ]}
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
            env = dict(os.environ, CAPSLOCK_PRO_BIN_DIR=bin_dir.name,
                       CAPSLOCK_PRO_KARABINER_CONFIG=str(config_path),
                       CAPSLOCK_PRO_KARABINER_ASSETS_DIR=str(directory / "assets"))
            for iteration in range(2):
                result = self.run_command([ROOT / "macOS/update.sh"], env=env, cwd=directory)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if iteration == 0:
                    backup = Path(str(config_path) + ".capslock-pro.backup")
                    self.assertEqual(json.loads(backup.read_text()), config)
                else:
                    self.assertIn("配置已经是最新版本", result.stdout)
            updated = json.loads(config_path.read_text())
            installed = json.loads((directory / "assets/capslock-pro.json").read_text())
            self.assertEqual(updated["profiles"][0]["complex_modifications"]["rules"], [custom] + installed["rules"])
            self.assertEqual(updated["profiles"][1], config["profiles"][1])
            self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)
            # 执行实际生成的 shell 文本，以确认路径转义和参数传递。
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPSLOCK_TEST_ARGS"\n')
            marker = directory / "arguments"
            env["CAPSLOCK_TEST_ARGS"] = str(marker)
            command = installed["rules"][-1]["manipulators"][0]["to"][-1]["shell_command"]
            result = self.run_command(["/bin/sh", "-c", command], env=env, cwd=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker.read_text().splitlines(), ["--background", "next"])
            self.assertFalse((directory / "INJECTED").exists())

    def test_lock_excludes_overlap_and_recovers_after_crash(self):
        lock = self.directory / "operation.lock"
        first = subprocess.Popen([self.harness, "lock", lock, "hold"], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(first.stdout.readline().strip(), "acquired")
            second = self.run_command([self.harness, "lock", lock])
            self.assertEqual(second.stdout.strip(), "busy")
        finally:
            first.kill()
            first.wait(timeout=5)
            first.stdout.close()
        self.assertEqual(self.run_command([self.harness, "lock", lock]).stdout.strip(), "acquired")

    def test_background_survives_launcher_group_termination(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as directory:
            directory = Path(directory)
            worker = directory / "worker.sh"
            ready = directory / "ready"
            done = directory / "done"
            worker.write_text('cd "$(dirname "$0")"\necho "$$" > ready\nsleep 0.5\necho completed > done\necho logged\n')
            log = directory / "window.log"
            launcher = subprocess.Popen([self.harness, "spawn", worker, log], start_new_session=True)
            try:
                worker_pid = int(self.wait_for(ready).strip())
                self.assertEqual(os.getpgid(worker_pid), worker_pid)
                self.assertNotEqual(os.getpgid(worker_pid), launcher.pid)
                os.killpg(launcher.pid, signal.SIGTERM)
                launcher.wait(timeout=5)
                self.assertEqual(self.wait_for(done).strip(), "completed")
                self.assertEqual(self.wait_for(log).strip(), "logged")
            finally:
                if launcher.poll() is None:
                    os.killpg(launcher.pid, signal.SIGKILL)
                    launcher.wait(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
