"""
Hatch build hook: puts the minijx compiler inside the wheel.

The binary is compiled with FreePascal (`fpc`) from `compiler/`, or taken
from `$MINIJX_BINARY` when it was built elsewhere, and shipped as
`minijx/bin/minijx`. It is a standalone executable, not a CPython
extension, so the wheel is tagged `py3-none-<platform>`: one wheel per
platform serves every Python version.

Environment variables:

- `MINIJX_BINARY`: use this prebuilt binary instead of running `fpc`.
- `MINIJX_WHEEL_PLATFORM`: override the platform part of the wheel tag.
"""

import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


ROOT = Path(__file__).resolve().parent
COMPILER_SRC = ROOT / "compiler"

# FreePascal links the binary statically and without libc, so the same
# Linux wheel runs on glibc (manylinux) and musl (musllinux) systems.
LINUX_TAGS = "manylinux_2_17_{arch}.manylinux2014_{arch}.musllinux_1_1_{arch}"
MACOS_TAGS = {"arm64": "macosx_11_0_arm64", "x86_64": "macosx_10_12_x86_64"}


def platform_tag() -> str:
    override = os.environ.get("MINIJX_WHEEL_PLATFORM")
    if override:
        return override
    machine = platform.machine().lower()
    if sys.platform.startswith("linux"):
        arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
        if arch not in ("x86_64", "aarch64"):
            raise RuntimeError(f"minijx wheels are not built for Linux on {machine}")
        return LINUX_TAGS.format(arch=arch)
    if sys.platform == "darwin":
        arch = {"aarch64": "arm64", "amd64": "x86_64"}.get(machine, machine)
        if arch not in MACOS_TAGS:
            raise RuntimeError(f"minijx wheels are not built for macOS on {machine}")
        return MACOS_TAGS[arch]
    raise RuntimeError(f"minijx wheels are not built for {sys.platform} yet")


def compile_binary(out_dir: Path, version: str) -> Path:
    fpc = shutil.which("fpc")
    if not fpc:
        raise RuntimeError(
            "Building the minijx wheel needs FreePascal 3.2+ (`fpc`) in the PATH, "
            "or a prebuilt binary in $MINIJX_BINARY"
        )
    units = out_dir / "units"
    units.mkdir(parents=True, exist_ok=True)
    cmd = [
        fpc, f"@{COMPILER_SRC / 'minijx.cfg'}",
        f"-Fu{COMPILER_SRC}", f"-FE{out_dir}", f"-FU{units}",
        str(COMPILER_SRC / "minijx.lpr"),
    ]
    # the binary's version comes from the package's, at compile time
    env = {**os.environ, "MINIJX_VERSION": version}
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"fpc failed:\n{result.stdout}\n{result.stderr}")
    return out_dir / "minijx"


def check_version(binary: Path, version: str) -> None:
    """The binary and the runtime must agree, or generated modules won't load."""
    try:
        out = subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout
    except OSError as err:  # e.g. a binary built for another architecture
        print(f"minijx build hook: cannot run {binary} to check its version ({err})", file=sys.stderr)
        return
    m = re.match(r"minijx (\S+) \(module format (\d+)\)", out)
    if not m:
        raise RuntimeError(f"Unexpected `minijx --version` output: {out!r}")
    catalog = (ROOT / "src" / "minijx" / "catalog.py").read_text(encoding="utf-8")
    module_format = re.search(r"^MODULE_FORMAT = (\d+)", catalog, re.M).group(1)
    if m.group(1) != version:
        raise RuntimeError(f"compiler version {m.group(1)} != package version {version}")
    if m.group(2) != module_format:
        raise RuntimeError(
            f"compiler module format {m.group(2)} != runtime MODULE_FORMAT {module_format}"
        )


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        if self.target_name != "wheel" or version == "editable":
            # An editable install uses the binary `make build` copies to
            # src/minijx/bin/.
            return
        prebuilt = os.environ.get("MINIJX_BINARY")
        if prebuilt:
            binary = Path(prebuilt).resolve()
        else:
            self._tmp = tempfile.mkdtemp(prefix="minijx-build-")
            binary = compile_binary(Path(self._tmp), self.metadata.version)
        check_version(binary, self.metadata.version)
        build_data["force_include"][str(binary)] = "minijx/bin/minijx"
        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform_tag()}"

    def finalize(self, version: str, build_data: dict, artifact_path: str) -> None:
        tmp = getattr(self, "_tmp", None)
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
