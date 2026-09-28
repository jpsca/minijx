<div align="center">
  <h1><img alt="Jx" src="https://raw.githubusercontent.com/jpsca/minijx/main/logo-minijx.png" height="100" align="top"></h1>
</div>

# MiniJx

MiniJx is a template engine that precompiles [Jx](https://github.com/jpsca/jx) components into plain Python functions before rendering them. It render pages about 4x faster than regular Jx and does not requires Jx nor Jinja to run.

It can be used as a drop-in for existing Jx templates since it supports almost all of Jinja syntax except for macros, template inheritance, and, most notably, Jinja extensions. The lack of support for Jinja extensions is the reason this starts as a separated project from Jx.

The compiler it's implemented in [FreePascal](https://www.freepascal.org/) and can be used as a regular Python library and as a command line utility.

The wheel includes the compiler binary, so FreePascal is not needed to use it. Wheels are built for Linux (x86_64, aarch64; glibc and musl) and macOS (arm64, x86_64). It is tested on Python 3.13, 3.14 and free-threaded 3.14t: the runtime has no C extensions, and one catalog can render from many threads at once.

```
minijx components/ [more/folders/]
minijx --version
```

Import rules:

- `ui/button.jx` is searched in the folders, in the order given.
- `./x.jx` and `../x.jx` are relative to the importing file, and cannot leave
  the folder it was found in.
- **Prefixed imports (`@ui/button.jx`) are not supported.**

Every `name.jx` under the folders becomes a `.py` next to it. Dots in the name become `_`, so `sitemap.xml.jx` becomes `sitemap_xml.py`. Two sources that would produce the same `.py` are a compile error. Each module exposes:

```python
def render(
  *,
  <arguments from {# def #}>,
  content="",
  _globals=None,
  _fills=None,
  **attrs
) -> str
```

The generated module imports only the `minijx` package. It has no dependency on Jinja or on Jx. Components a file imports are copied into the same module as private functions, so each `.py` is self contained.

## Catalog

`minijx.Catalog` has the same shape as `jx.Catalog`. It finds a component's generated module by name and calls its `render`.

```python
from minijx import Catalog

catalog = Catalog("components/", site_name="Demo")
catalog.compile()
html = catalog.render("pages/home.jx", globals={"user": user}, items=items)
```

- The catalog uses the compiler bundled with the package, or a `minijx` in the `PATH`. `compiler=` points it to another binary, and `compiler=False` disables compiling: then the modules must be built ahead, e.g. when the application is packaged.
- It refuses a binary that generates modules of a format this runtime cannot load, such as a `minijx` from another version.
- Names are paths relative to a folder, with or without `.jx`. Folders added with `add_folder` are searched in order.
- Globals are the catalog's, then the render's, then `assets` (`assets.render()`, `render_css()`, `render_js()`, `collect_css()`, `collect_js()`), as in Jx. `_get_random_id` is available too.
- With `auto_reload=True` (the default) a changed module is reloaded. A module older than any `.jx` copied into it (its `SOURCES`) is recompiled when `compiler` is given, and raises `ComponentNotCompiledError` if not.
- A syntax error raises `CompileError` only for components that use the broken file. The rest keep rendering.
- `catalog.compile()` compiles every folder at once. It uses `compiler=` or a `minijx` in the `PATH`, and raises `CompileError` listing every error.
- Jx's `add_package`, `asset_resolver`, `get_assets_folder` and `collect_assets` are not supported, since they depend on prefixes.


## The language

A component is a `.jx` file with an optional header and a template. As in Jx, the header is the run of `{# def #}`, `{# import #}`, `{# css #}` and `{# js #}` comments the file starts with; the same comment further down is an ordinary comment.

```html+jinja
{# import "./header.jx" as Header #}
{# import "ui/button.jx" as Button #}
{# css "card.css" #}
{# js "card.js" #}
{# def title, items: list = [], show_footer=true #}

<div {{ attrs.render(class="card") }}>
  <Header title={{ title }} count={{ items | length }} />
  {{ content }}
  {% for item in items if item.visible %}
    <p>{{ loop.index }}: {{ item.name | upper }}</p>
  {% else %}
    <p>No items</p>
  {% endfor %}
  {% slot footer %}<Button text="OK" />{% endslot %}
</div>
```

Jinja syntax supported:

- Rendering of variables `{{ }}`
- `if/elif/else`
- `for ... if ... recursive` with `else` and the full `loop` object
- `set name = value`
- `do`,
- `call` (see below),
- `raw`
- Every Jinja builtin filter except `xmlattr`, `pprint` and `urlize`
- custom filters and tests.

Not supported, by design: `extends`, `include`, `macro`, Jinja's `call` with `caller`, block `set`, `namespace()`, tuple unpacking in `set`, and Jinja extensions other than `do`.

### `{% call %}`

Like `{% filter %}`, but the function is a variable: the body is rendered and passed as the first argument of the call.

```html+jinja
{% call markdown %}# {{ title }}{% endcall %}          {# markdown(body) #}
{% call highlight("python", lines=true) %}...{% endcall %} {# highlight(body, "python", lines=True) #}
{% call obj.render %}...{% endcall %}                  {# obj.render(body) #}
```

The callable can be an argument, a `set` variable or a global. This is not Jinja's `call`, which calls a macro with a `caller`.

### Custom filters and tests

```python
catalog = Catalog(
    "components/",
    filters={"markdown": markdown, "upper": my_upper},
    tests={"admin": lambda user: user.is_admin},
)
```

As in Jx, a filter receives the filtered value first, and a custom filter can replace a builtin one. `map`, `select`, `reject`, `selectattr` and `rejectattr` see the custom filters and tests too. The tests minijx compiles into plain Python (`defined`, `undefined`, `none`, `in`, `callable`, `sameas` and the comparisons like `eq` or `gt`) cannot be replaced; the catalog raises `ValueError` if you try.

The generated code looks filters and tests up by name at render time, so an unknown filter is a `KeyError` when it runs, not a compile error.

### `{# def #}` defaults

As in Jx, a default value is a Python expression, not a Jinja one: `1 | 2` is 3. It can only use literals, `true`, `false`, `len`, `max`, `min`, `pow`, `sum`, and the names it binds itself (comprehension variables, lambda parameters). Anything else is a compile error.

### Whitespace

The output is the same as Jx's, byte for byte:

- Whitespace control works as in Jinja with its default settings: `{%-`, `{{-` and `{#-` trim the text before the tag, `-%}`, `-}}` and `-#}` the text after it. `+` does nothing. Newlines are normalised to `\n`, and one newline at the very end of a file is dropped.
- A component's output never starts with whitespace.
- The content between a component's tags is trimmed at both ends.
- The markers inside `{% slot %}` and `{% fill %}` trim their bodies. The ones outside a fill do nothing, since the fill is moved out of the content, and the text around it becomes one piece.

## Semantics that differ from Jinja

- **Strict names.** A name that is not an argument, a `set` variable, a loop variable, `content`, `attrs`, `loop` or a Python builtin compiles to `_globals["name"]`. A missing global raises `KeyError`. `x is defined` and `x | default(...)` are the exceptions: they compile to a safe lookup.
- **Attribute access** `a.b` tries `getattr` then `getitem`, like Jinja. `a["b"]` tries the reverse. A miss raises `AttributeError`.
- **No autoescape.** Only the `escape` (`e`) filter escapes. `safe` is the identity.
- **Python scoping.** A `set` inside a `for` is visible after the loop.
- **Arguments are keyword-only.** Type annotations are copied into the signature and not validated.
- `render` returns `str`
- The `CSS` and `JS` module constants list the assets of the component and of everything it imports, in Jx's order: the component's own first, then each import's.
- `MINIJX_FORMAT` marks the module layout; the catalog treats a module from another minijx version as stale.

## Example app

```
make example      # http://127.0.0.1:8000, PORT=... to change it
```

A small site in `example/` built only with the standard library. It shows layouts with slots, `attrs`, loops with `loop`, recursive loops, filters, globals, a `sitemap.xml.jx`, and a component broken on purpose at `/broken`. The app compiles everything at startup with `catalog.compile()`. Edit any `.jx` in `example/components/` and reload the page: the catalog recompiles it. Render times go to the console and to the `Server-Timing` header.

## Benchmark

```
make bench        # or: PYTHONPATH=src ../jx/.venv/bin/python bench/bench_example.py [--reload]
```

Renders every page of the example app with minijx and with Jx, from the same `.jx` files and data. Before timing, it checks that minijx and Jx with autoescape off produce the same HTML. It reports the median warm render time per page, the first render with a new catalog, and the time to compile every component with the binary.

## Layout

```
compiler/       FreePascal sources: mjlexer, mjparser, mjexpr (expression tree), mjdefs,
                mjgen (Python functions), mjcompiler (modules), minijx.lpr
src/minijx/     Python package: catalog.py, filters.py, tests.py, attrs.py, loop.py,
                runtime.py, __main__.py (the `minijx` command), bin/ (the binary)
hatch_build.py  wheel build hook
example/        demo app: app.py, components/, static/
bench/          benchmark against Jx
tests/          pytest suite; tests/fixtures has a sample component set
```

Errors are printed as `file:line:col: message` on stderr and the exit code is 1. Other files still compile.

## Development

```
make build        # needs fpc 3.2+; writes build/minijx and copies it into src/minijx/bin/
make test         # pytest: golden tests against Jx, filters/tests against jinja2
make dist         # the wheel for this platform and the sdist, in dist/
```

`make test` uses `../jx/.venv/bin/python`, a Python with `jx`, `jinja2` and `pytest`. `make test JX_PYTHON="uv run --group test python"` uses the test dependencies from `pyproject.toml` instead, with Jx from PyPI.

The wheel build (`hatch_build.py`) compiles the binary with `fpc`, or takes it from `$MINIJX_BINARY`, checks that its version and module format match the runtime's, and tags the wheel `py3-none-<platform>`. The version is only written in `pyproject.toml` (`uv version --bump patch` changes it): the Makefile and the wheel build pass it to `fpc` in `$MINIJX_VERSION`, and `minijx.__version__` reads it from the package metadata, or from `pyproject.toml` in a source checkout. The `fpc` options are in `compiler/minijx.cfg`, which both use.

`MINIJX_TEST_INSTALLED=1` makes the tests import the installed package instead of `src/`, to test a wheel. On a free-threaded Python, run the tests with `PYTHON_GIL=0`: the concurrency tests then run truly in parallel, and one of them fails if something turned the GIL back on.

### Releasing

The `wheels` workflow tests every push on Python 3.13, 3.14 and 3.14t, and builds a wheel on each platform and tests it on 3.13 and 3.14t.