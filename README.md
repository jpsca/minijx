<div align="center">
  <h1><img alt="Jx" src="https://raw.githubusercontent.com/jpsca/minijx/main/logo-minijx.png" height="100" align="top"></h1>
</div>

# MiniJx

MiniJx is a template engine that precompiles [Jx](https://github.com/jpsca/jx) components into plain Python functions before rendering them. It render pages about 3x faster than regular Jx and does not requires Jx nor Jinja to run; its only dependency is [MarkupSafe](https://markupsafe.palletsprojects.com/).

It can be used as a drop-in for existing Jx templates since it supports almost all of Jinja syntax except for macros, template inheritance, and, most notably, Jinja extensions. However, you can define any global variable to be treated as a tag (see [Custom tags](#custom-tags)).

The compiler it's implemented in [FreePascal](https://www.freepascal.org/) and can be used as a regular Python library and as a command line utility.

The wheel includes the compiler binary, so FreePascal is not needed to use it. Wheels are built for Linux (x86_64, aarch64; glibc and musl) and macOS (arm64, x86_64). It is tested on Python 3.13, 3.14 and free-threaded 3.14t: the runtime itself has no C extensions (MarkupSafe's are optional), and one catalog can render from many threads at once.

```
minijx [--autoescape=html,jx,xml] [--tags=cache,...] [--output=build/] components/ [more/folders/]
minijx --version
```

`--autoescape` lists the extensions of the components compiled with autoescape (see [Autoescape](#autoescape)). The default is `html,jx,xml`; `--autoescape=` turns it off. `--tags` lists the custom tags (see [Custom tags](#custom-tags)). `--output` writes the modules to a folder of their own (see below).

Import rules:

- `ui/button.jx` is searched in the folders, in the order given.
- `./x.jx` and `../x.jx` are relative to the importing file, and cannot leave
  the folder it was found in.
- **Prefixed imports (`@ui/button.jx`) are not supported.**

Every `name.jx` under the folders becomes a `.py` next to it. Dots in the name become `_`, so `sitemap.xml.jx` becomes `sitemap_xml.py`. Two sources that would produce the same `.py` are a compile error.

With `--output=build/`, the modules go there instead, and the folders of components keep only the `.jx` files. The modules of each folder go to `build/<the folder's name>/`, in the same layout: `views/pages/home.jx` becomes `build/views/pages/home.py`. When two folders have the same name, the second one gets `views-2`, and so on. A module records its sources relative to itself, so the project can be moved or deployed as a whole, and a module can be rendered without its `.jx` (with `compiler=False, auto_reload=False`). Each module exposes:

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
- A component's module is checked the first time it is loaded, in any mode: one that is missing, older than any `.jx` copied into it (its `SOURCES`), compiled from another file or with other settings is compiled again when there is a compiler, and raises `ComponentNotCompiledError` if not. With `auto_reload=True` (the default) this is checked again on every render, so a changed view is picked up; turn it off in production. A module shipped without its `.jx` is used as it is.
- `render_string(source, **kwargs)` renders a component from its source, compiled once to a temporary folder (its imports are looked for in the catalog's folders).
- A syntax error raises `CompileError` only for components that use the broken file. The rest keep rendering.
- `catalog.compile()` compiles every folder at once. It uses `compiler=` or a `minijx` in the `PATH`, and raises `CompileError` listing every error.
- `autoescape=` is the list of extensions compiled with autoescape; `True` (the default) is `("html", "jx", "xml")` and `False` turns it off. A module compiled with another list is stale.
- `output=` is the folder for the compiled modules, as `--output`. By default they go next to each `.jx`.
- `filters=`, `tests=` and `tags=` can also be added later, with `add_filters`, `add_tests` and `add_tags`, and `catalog.globals` is a dict that can be changed. A new tag makes the modules compiled before it stale.
- `render` returns `Markup` for a component compiled with autoescape, and `str` otherwise.
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
- `do`
- `raw`
- `macro` (see below)
- Every Jinja builtin filter except `xmlattr`, `pprint` and `urlize`
- custom filters and tests.

Not supported, by design: `extends`, `include`, `call` (a custom tag does its job), importing macros from another file, block `set`, `namespace()`, tuple unpacking in `set`, and Jinja extensions other than `do` (see [Custom tags](#custom-tags) for block tags like `{% cache %}`).

### `{% macro %}`

As in Jinja, for markup repeated inside one component:

```html+jinja
{% macro render_phone(form, label="Phone") -%}
<div class="nestedform">
  {{ form.value.tel_input() }}
  {{ form.label.text_input(placeholder=label) }}
</div>
{%- endmacro %}

{% for phone_form in form.phones.forms %}
  {{ render_phone(phone_form) }}
{% endfor %}
<template>{{ render_phone(form.phones.empty_form) }}</template>
```

- A macro sees the component's variables as they are when it is called, can call itself and the macros defined after it, and a `set` inside it does not change the variable outside. Defaults are evaluated on each call and can use the parameters before them.
- It returns markup with autoescape, so its output is not escaped again.
- Parameters are names or `name=default`; a missing argument is a `TypeError` (Jinja renders it as undefined).
- A macro belongs to its component: to share markup between files, make it a component.
- `caller`, `varargs` and `kwargs` are not supported: using them in a macro is a compile error.

### Custom tags

A catalog can add block tags. The body of a custom tag is not rendered first: it goes to the tag's function as `caller`, and is rendered only if the function calls it. That is what fragment caching needs:

```python
def cache(key, *, caller, template, expires_in=None):
    return app_cache.get_or_set(f"{template}:{key}", caller, expires_in=expires_in)

catalog = Catalog("components/", tags={"cache": cache})
```

```html+jinja
{% cache "sidebar" %}...{% endcache %}
{% cache user, expires_in=300 %}...{% endcache %}
{% cache(user, expires_in=300) %}...{% endcache %}
```

- `{% name args %}` and `{% name(args) %}` are the same call. With a space before the parenthesis, `{% name (a, b) %}` passes one argument, the tuple, as in Jinja.
- The function also gets `template`: the path of the component the tag is in, e.g. `"pages/home.jx"`. Two templates can use the same key without sharing a fragment.
- What it returns is not escaped, as with a Jinja extension's block tag; with autoescape, `caller()` returns markup.
- A name cannot be a builtin statement (`if`, `for`, `set`, `call`, `macro`...), nor start with `end`.
- The tags are compiled in: the modules record them in `TAGS`, and one compiled with other tags is stale.

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

### `{# def #}` defaults and types

As in Jx, a default value is a Python expression, not a Jinja one: `1 | 2` is 3. It can only use literals, `true`, `false`, `len`, `max`, `min`, `pow`, `sum`, and the names it binds itself (comprehension variables, lambda parameters). Anything else is a compile error. A default that is not a plain literal (`[]`, `{"a": 1}`, `len(x)`) is evaluated on each render, so a list is never shared between renders.

As in Jx, an argument annotated with a builtin type is checked on each render, with `isinstance`, and so is its default value:

```html+jinja
{# def title: str, count: int = 0, tags: list[str] = [], user: User = None #}
```

`title` must be a `str`, `count` an `int` (`True` is one, as in Python), and `tags` a `list`: of a generic, only the base type is checked. `User`, `str | None` and any other annotation are not checked, nor evaluated: they are kept, as text, in the signature of the generated function. A wrong type raises `InvalidPropType`, a `TypeError`, with Jx's message: `ui/card.jx: `count` expected int, got str`. Checking costs a few nanoseconds per typed argument.

What a component call shows in the template is checked when compiling, with the signature of the component:

- a required argument that is not given: ``<Card>` needs the argument `title` (ui/card.jx)``. Content between the tags counts as `content`. A call with `attrs=` is not checked, since its values are only known when rendering.
- a literal of a type the annotation does not accept: `count="3"` is a `str`, a flag (`<Card disabled />`) is `True`, and `{{ 3 }}`, `{{ -1.5 }}`, `{{ none }}`, `{{ [..] }}`, `{{ {..} }}` or `{{ (..) }}` have their type. With the rules of `isinstance`, so `{{ true }}` is an `int`. Any other expression is checked when rendering.

### Whitespace

The output is the same as Jx's, byte for byte:

- Whitespace control works as in Jinja with its default settings: `{%-`, `{{-` and `{#-` trim the text before the tag, `-%}`, `-}}` and `-#}` the text after it. `+` does nothing. Newlines are normalised to `\n`, and one newline at the very end of a file is dropped.
- A component's output never starts with whitespace.
- The content between a component's tags is trimmed at both ends.
- The markers inside `{% slot %}` and `{% fill %}` trim their bodies. The ones outside a fill do nothing, since the fill is moved out of the content, and the text around it becomes one piece.

## Autoescape

As in Jx, a `{{ }}` escapes what it renders, unless the value has `__html__` (a `markupsafe.Markup`, the result of `| safe` or `| e`, the output of `attrs.render()`...). The output is the same as Jx's with autoescape on, byte for byte.

Autoescape is decided per component, by the extension before `.jx`, or `jx` if there is none:

| file | extension | escaped with the default list |
|---|---|---|
| `card.jx` | `jx` | yes |
| `pages/home.html.jx` | `html` | yes |
| `sitemap.xml.jx` | `xml` | yes |
| `emails/welcome.txt.jx` | `txt` | no |
| `data.json.jx` | `json` | no |

```python
catalog = Catalog("components/")                       # html, jx, xml
catalog = Catalog("components/", autoescape=["html"])  # only *.html.jx
catalog = Catalog("components/", autoescape=False)     # nothing
```

Each component keeps its mode when it is copied into another module. The HTML a component passes to another (its content, its fills) is never escaped again: it is written by the template author, not data. That holds between modes too: a `.txt.jx` page can use an escaped `layout.jx`, and its content goes in as it is, while the arguments it passes (`title={{ subject }}`) are escaped by the layout like any other value.

With autoescape:

- `a ~ b` is markup when a part is, and escapes the other parts, as in Jinja.
- The body of `{% filter %}` and custom tags reaches the function as markup. The result of `{% filter %}` is escaped unless it is markup too (a `markdown` filter used in `{% filter markdown %}` must return `Markup`); the result of a custom tag is not, as with Jinja extensions.
- `join` and `replace` follow Jinja's autoescape rules.
- The filters `e`, `escape`, `forceescape` and `safe` cannot be replaced: the compiled code trusts them to return markup.

In every mode, `attrs.render()` escapes `&` and `<` in values that are not markup, as Jx does.

## Errors

An error while rendering points to the templates, not to the compiled Python, as Jinja does. `catalog.render` rewrites the traceback: each frame of a compiled module becomes a frame in its `.jx`, at the line of the construct that failed, with `^^^` under the expression and the template's variables as its locals. Macros, fills, custom tags and recursive loops get frames of their own. The frames of minijx itself are left out.

```
  File "app/views/pages/users.jx", line 12, in template
    <Card title={{ user.name }} />
    ^^^^^
  File "app/views/ui/card.jx", line 3, in template
    <p>{{ title }} · {{ subtitle.upper() }}</p>
                        ~~~~~~~~~~~~~~^^
AttributeError: 'NoneType' object has no attribute or item 'upper'
```

A name that is not defined is a `KeyError`, with a note saying where it was looked for, and a component called without a required argument is a `TypeError` that names it (`<ui/card.jx> missing 1 required keyword-only argument: 'title'`).

This works because each module has a `LINEMAP`, where each of its lines comes from, and, in a line that renders several `{{ }}`, the columns of each one. It costs nothing until a render raises. Calling a module's `render` directly, without a catalog, shows the compiled code.

## Semantics that differ from Jinja

- **Strict names.** A name that is not an argument, a `set` variable, a loop variable, `content`, `attrs`, `loop` or a Python builtin compiles to `_globals["name"]`. A missing global raises `KeyError`. `x is defined` and `x | default(...)` are the exceptions: they compile to a safe lookup.
- **Attribute access** `a.b` tries `getattr` then `getitem`, like Jinja. `a["b"]` tries the reverse. A miss raises `AttributeError`.
- **Scoping.** A `set` inside a `for`, a fill, a macro or the body of a custom tag is not visible after it, as in Jinja. Before the `set`, the body sees the outer value.
- **Arguments are keyword-only.** Builtin types are checked as in Jx (see above); other annotations are only copied into the signature.
- The `CSS` and `JS` module constants list the assets of the component and of everything it imports, in Jx's order: the component's own first, then each import's.
- `MINIJX_FORMAT` marks the module layout; the catalog treats a module from another minijx version as stale.
- `AUTOESCAPE` is the list of extensions the module was compiled with, and `ESCAPED` whether its `render` escapes.
- `LINEMAP` and `COMPONENTS` are for the tracebacks: where each line comes from in the templates, and the function of each component.

## Example app

```
make example      # http://127.0.0.1:8000, PORT=... to change it
```

A small site in `example/` built only with the standard library. It shows layouts with slots, `attrs`, loops with `loop`, recursive loops, filters, globals, a `sitemap.xml.jx`, and a component broken on purpose at `/broken`. The app compiles everything at startup with `catalog.compile()`. Edit any `.jx` in `example/components/` and reload the page: the catalog recompiles it. Render times go to the console and to the `Server-Timing` header.

## Benchmark

```
make bench        # or: PYTHONPATH=src ../jx/.venv/bin/python bench/bench_example.py [--reload]
```

Renders every page of the example app with minijx and with Jx, from the same `.jx` files and data. Each engine runs with autoescape on and off; before timing, it checks that minijx produces the same HTML as Jx in each mode. It reports the median warm render time per page, the first render with a new catalog, and the time to compile every component with the binary.

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