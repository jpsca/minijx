"""
Benchmark: render the example app's pages with minijx and with Jx.

    make bench
    ../jx/.venv/bin/python bench/bench_example.py [--time 0.5] [--reload]

Both catalogs read the same `.jx` files in `example/components/`, with the
same arguments and globals the app uses.

Jx is measured in two configurations:

- "jx": its defaults, autoescape on and StrictUndefined. This is what a Jx
  app runs, but its output is escaped and minijx's is not.
- "jx noesc": autoescape off, StrictUndefined kept. Byte for byte the same
  output as minijx, which is checked before timing.

Reported per page:

- warm: median time of one render once everything is loaded, in µs.
- cold: first render with a new catalog, in ms. For Jx it includes turning
  every component the page uses into Python code; for minijx, loading the
  already generated module. minijx's own compile step is measured apart.
"""

import argparse
import copy
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "example"
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(EXAMPLE))

import app as demo  # noqa: E402  the example app: its data, routes and catalog setup
import jinja2  # noqa: E402
from jx import Catalog as JxCatalog  # noqa: E402
from minijx import Catalog as MiniCatalog  # noqa: E402


PAGES = ["/", "/users", "/users?q=a&sort=age", "/users/1", "/tree", "/filters", "/sitemap.xml", "/nope"]


def page_args(page: str):
    path, _, query = page.partition("?")
    params = dict(p.split("=", 1) for p in query.split("&") if p)
    _, _, component, kwargs = demo.route(path, params)
    if not component.endswith(".jx"):
        component += ".jx"  # minijx's catalog accepts the name without it; Jx does not
    globals_ = {
        "current_path": path,
        "components_count": sum(1 for _ in demo.COMPONENTS.rglob("*.jx")),
    }
    return component, kwargs, globals_


def catalog_globals() -> dict:
    return {"site_name": "minijx demo", "nav": demo.catalog.globals["nav"]}


def make_mini(auto_reload: bool) -> MiniCatalog:
    return MiniCatalog(demo.COMPONENTS, auto_reload=auto_reload, **catalog_globals())


def make_jx(auto_reload: bool, autoescape: bool) -> JxCatalog:
    env = None
    if not autoescape:
        env = jinja2.Environment(autoescape=False, undefined=jinja2.StrictUndefined)
    return JxCatalog(demo.COMPONENTS, jinja_env=env, auto_reload=auto_reload, **catalog_globals())


def collapse(html: str) -> str:
    return re.sub(r">\s+<", "><", re.sub(r"\s+", " ", str(html))).strip()


def render(catalog, page: str) -> str:
    component, kwargs, globals_ = page_args(page)
    return catalog.render(component, globals=globals_, **kwargs)


def warm_us(catalog, page: str, budget: float) -> float:
    """Median of batches of renders, µs per render."""
    component, kwargs, globals_ = page_args(page)

    def once():
        catalog.render(component, globals=dict(globals_), **kwargs)

    for _ in range(20):
        once()
    # size a batch to ~budget/10 seconds
    n, t0 = 0, time.perf_counter()
    while time.perf_counter() - t0 < budget / 10:
        once()
        n += 1
    samples = []
    for _ in range(10):
        t0 = time.perf_counter()
        for _ in range(n):
            once()
        samples.append((time.perf_counter() - t0) / n * 1e6)
    return statistics.median(samples)


def cold_ms(factory, page: str, trials: int = 7) -> float:
    samples = []
    for _ in range(trials):
        catalog = factory()
        t0 = time.perf_counter()
        render(catalog, page)
        samples.append((time.perf_counter() - t0) * 1e3)
    return statistics.median(samples)


def compile_all_ms(trials: int = 5) -> float:
    catalog = make_mini(auto_reload=False)
    args = [str(ROOT / "build" / "minijx"), *catalog.compiler_args()]
    samples = []
    for _ in range(trials):
        t0 = time.perf_counter()
        subprocess.run(args, capture_output=True)
        samples.append((time.perf_counter() - t0) * 1e3)
    return statistics.median(samples)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--time", type=float, default=0.5, help="seconds of warm timing per page and engine")
    parser.add_argument("--reload", action="store_true", help="auto_reload on in both catalogs (development mode)")
    opts = parser.parse_args()

    compile_ms = compile_all_ms()
    engines = {
        "minijx": lambda: make_mini(opts.reload),
        "jx noesc": lambda: make_jx(opts.reload, autoescape=False),
        "jx": lambda: make_jx(opts.reload, autoescape=True),
    }
    catalogs = {name: factory() for name, factory in engines.items()}

    # Same work: minijx and Jx without autoescape must produce the same HTML.
    for page in PAGES:
        mini = render(catalogs["minijx"], page)
        jx = str(render(catalogs["jx noesc"], page))
        if mini != jx:
            i = next(i for i, (a, b) in enumerate(zip(mini, jx)) if a != b)
            sys.exit(f"Different output for {page} at {i}:\n  minijx: {mini[i-60:i+60]!r}\n  jx:     {jx[i-60:i+60]!r}")

    mode = "auto_reload on" if opts.reload else "auto_reload off"
    print(f"Python {sys.version.split()[0]} · jinja2 {jinja2.__version__} · {mode}")
    print(f"minijx compile of all components: {compile_ms:.1f} ms (whole folder, one process)\n")

    header = f"{'page':<22}" + "".join(f"{name + ' µs':>13}" for name in engines) + f"{'vs jx':>9}{'vs noesc':>10}"
    print("Warm render, median")
    print(header)
    print("-" * len(header))
    totals = dict.fromkeys(engines, 0.0)
    for page in PAGES:
        times = {name: warm_us(cat, page, opts.time) for name, cat in catalogs.items()}
        for name, v in times.items():
            totals[name] += v
        print(
            f"{page:<22}"
            + "".join(f"{times[n]:>13.1f}" for n in engines)
            + f"{times['jx'] / times['minijx']:>8.1f}x{times['jx noesc'] / times['minijx']:>9.1f}x"
        )
    print("-" * len(header))
    print(
        f"{'all pages':<22}"
        + "".join(f"{totals[n]:>13.1f}" for n in engines)
        + f"{totals['jx'] / totals['minijx']:>8.1f}x{totals['jx noesc'] / totals['minijx']:>9.1f}x"
    )

    print("\nCold first render (new catalog), median ms")
    header = f"{'page':<22}" + "".join(f"{name + ' ms':>13}" for name in engines)
    print(header)
    print("-" * len(header))
    for page in PAGES:
        print(f"{page:<22}" + "".join(f"{cold_ms(f, page):>13.2f}" for f in engines.values()))


if __name__ == "__main__":
    main()
