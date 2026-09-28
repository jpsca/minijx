"""
Packaging: the `minijx` command, the bundled binary, and the version kept in
sync between the compiler and the runtime.
"""

import os
import re
import subprocess
import sys

import pytest
from conftest import BIN, PYTHON_PKG, REPO

import minijx
from minijx.catalog import MODULE_FORMAT, bundled_compiler


def run_module(*args):
    env = {"PATH": "/usr/bin:/bin"}
    if not os.environ.get("MINIJX_TEST_INSTALLED"):
        env["PYTHONPATH"] = str(PYTHON_PKG)
    return subprocess.run([sys.executable, "-m", "minijx", *args], capture_output=True, text=True, env=env)


def test_versions_match():
    source = (REPO / "compiler" / "mjcodegen.pas").read_text()
    assert re.search(r"MinijxVersion = '([^']+)'", source).group(1) == minijx.__version__
    assert re.search(r"ModuleFormat = (\d+);", source).group(1) == str(MODULE_FORMAT)
    out = subprocess.run([str(BIN), "--version"], capture_output=True, text=True).stdout
    assert out.strip() == f"minijx {minijx.__version__} (module format {MODULE_FORMAT})"


def test_command_runs_the_bundled_binary(tmp_path):
    assert bundled_compiler() is not None
    result = run_module("--version")
    assert result.returncode == 0
    assert result.stdout.startswith(f"minijx {minijx.__version__}")

    (tmp_path / "a.jx").write_text("{# def x #}<b>{{ x }}</b>")
    result = run_module(str(tmp_path))
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "a.py").is_file()

    (tmp_path / "bad.jx").write_text("{{ 1 + }}")
    result = run_module(str(tmp_path))
    assert result.returncode == 1
    assert "bad.jx:1:8" in result.stderr


def test_command_without_a_binary(tmp_path, monkeypatch):
    import minijx.__main__ as cli

    monkeypatch.setattr(cli, "bundled_compiler", lambda: None)
    with pytest.raises(SystemExit, match="no compiler binary"):
        cli.main()


@pytest.mark.parametrize(
    "platform_name,machine,tag",
    [
        ("linux", "x86_64", "manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64"),
        ("linux", "aarch64", "manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64"),
        ("darwin", "arm64", "macosx_11_0_arm64"),
        ("darwin", "x86_64", "macosx_10_12_x86_64"),
    ],
)
def test_wheel_platform_tag(monkeypatch, platform_name, machine, tag):
    # only here: a module-level importorskip would skip every test in the file
    pytest.importorskip("hatchling", reason="hatchling is only needed to build wheels")
    sys.path.insert(0, str(REPO))
    try:
        import hatch_build
    finally:
        sys.path.remove(str(REPO))
    monkeypatch.delenv("MINIJX_WHEEL_PLATFORM", raising=False)
    monkeypatch.setattr(hatch_build.sys, "platform", platform_name)
    monkeypatch.setattr(hatch_build.platform, "machine", lambda: machine)
    assert hatch_build.platform_tag() == tag
