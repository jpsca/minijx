"""
Shared helpers: compile .jx files with the minijx binary, render them with
the generated Python, and render the same files with Jx for comparison.
"""

import copy
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parent.parent
BIN = REPO / "build" / "minijx"
PYTHON_PKG = REPO / "src"
JX_VIEWS = Path.home() / "Code" / "jx" / "docs" / "views"

# MINIJX_TEST_INSTALLED=1 tests the installed package (e.g. a wheel) instead
# of the source tree.
if not os.environ.get("MINIJX_TEST_INSTALLED") and str(PYTHON_PKG) not in sys.path:
    sys.path.insert(0, str(PYTHON_PKG))

def collapse(html: str) -> str:
    """Whitespace-insensitive: runs collapse, and none is kept between tags."""
    return re.sub(r">\s+<", "><", re.sub(r"\s+", " ", html)).strip()


def run_minijx(*folders: Path) -> subprocess.CompletedProcess:
    assert BIN.exists(), f"build the binary first: make build ({BIN} missing)"
    return subprocess.run([str(BIN), *map(str, folders)], capture_output=True, text=True)


def load_module(py_path: Path):
    spec = importlib.util.spec_from_file_location(f"gen_{py_path.stem}_{id(py_path)}", py_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Project:
    """A folder of .jx files compiled by minijx, and a copy of it rendered by Jx."""

    def __init__(self, root: Path):
        self.root = root
        self.mini = root / "mini"
        self.jx = root / "jx"
        self.mini.mkdir()
        self.jx.mkdir()

    def write(self, files: dict[str, str]) -> "Project":
        for name, source in files.items():
            p = self.mini / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(source, encoding="utf-8")
            q = self.jx / name
            q.parent.mkdir(parents=True, exist_ok=True)
            q.write_text(source, encoding="utf-8")
        return self

    def compile(self) -> subprocess.CompletedProcess:
        return run_minijx(self.mini)

    def render_mini(self, template: str, globals=None, filters=None, tests=None, **kwargs) -> str:
        result = self.compile()
        assert result.returncode == 0, result.stderr
        if filters or tests:
            from minijx import Catalog

            catalog = Catalog(self.mini, compiler=False, filters=filters, tests=tests)
            return catalog.render(template, globals=globals, **kwargs)
        mod = load_module(self.mini / (template[:-3] + ".py"))
        return mod.render(_globals=globals, **kwargs)

    def render_jx(self, template: str, globals=None, filters=None, tests=None, **kwargs) -> str:
        import jinja2
        from jx import Catalog

        catalog = Catalog(
            self.jx,
            jinja_env=jinja2.Environment(autoescape=False),
            filters=filters,
            tests=tests,
        )
        return catalog.render(template, globals=globals, **kwargs)

    def assert_same(self, template: str, globals=None, filters=None, tests=None, **kwargs) -> str:
        """
        Same HTML as Jx, byte for byte. Arguments are deep-copied per render
        so templates may mutate them. `filters` and `tests` go to both
        catalogs.
        """
        env = {"filters": filters, "tests": tests}
        mini = self.render_mini(template, globals=copy.deepcopy(globals), **env, **copy.deepcopy(kwargs))
        jx = self.render_jx(template, globals=copy.deepcopy(globals), **env, **copy.deepcopy(kwargs))
        assert mini == str(jx), f"\nminijx: {mini!r}\njx:     {str(jx)!r}"
        return mini


@pytest.fixture
def project(tmp_path) -> Project:
    return Project(tmp_path)
