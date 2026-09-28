"""
minijx demo app. Standard library only.

    make example                 # builds the compiler, then runs this
    PORT=8080 make example

Every page is a component in `components/`, rendered through `minijx.Catalog`.
Everything is compiled once at startup with `catalog.compile()`, and since
the catalog also has the compiler, editing a `.jx` file and reloading the
page recompiles it. Render time goes to the console and to the
`Server-Timing` response header.
"""

import html
import mimetypes
import os
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs
from wsgiref.simple_server import WSGIRequestHandler, make_server


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if not os.environ.get("MINIJX_TEST_INSTALLED"):
    sys.path.insert(0, str(ROOT / "src"))  # run from a source checkout

from minijx import Catalog, CompileError  # noqa: E402


COMPONENTS = HERE / "components"
STATIC = HERE / "static"

USERS = [
    {"id": 1, "name": "Ana Torres", "age": 31, "role": "admin", "tags": ["python", "pascal"],
     "bio": "Escribe compiladores por diversión y templates por trabajo. Prefiere los errores con número de línea.",
     "website": "https://example.com/ana"},
    {"id": 2, "name": "Bruno Díaz", "age": 24, "role": "editor", "tags": ["css"]},
    {"id": 3, "name": "Carla Méndez", "age": 40, "role": "editor", "tags": [], "bio": "Diseño de sistemas."},
    {"id": 4, "name": "Daniel Ruiz", "age": 29, "role": "viewer", "tags": ["htmx", "jinja"]},
    {"id": 5, "name": "Elena Paz", "age": 35, "role": "admin", "tags": ["ops"], "website": "https://example.com/elena"},
    {"id": 6, "name": "Fabián Rojas", "age": 50, "role": "viewer", "tags": []},
    {"id": 7, "name": "Gabriela Soto", "age": 27, "role": "editor", "tags": ["python", "a11y"]},
]


def file_tree(path: Path) -> dict:
    """The demo's own folder, as nested dicts, for the recursive-loop page."""
    if path.is_dir():
        return {
            "name": path.name + "/",
            "children": [file_tree(p) for p in path.iterdir() if not p.name.startswith((".", "__"))],
        }
    return {"name": path.name, "size": path.stat().st_size}


catalog = Catalog(
    COMPONENTS,
    site_name="minijx demo",
    nav=[("/", "Inicio"), ("/users", "Usuarios"), ("/tree", "Árbol"), ("/filters", "Filtros")],
)


# Routes: each returns (status, content type, component, kwargs)


def route(path: str, query: dict[str, str]):
    if path == "/":
        return "200 OK", "text/html", "pages/home.jx", {"users": USERS}
    if path == "/users":
        sort = query.get("sort", "name")
        if sort not in ("name", "age", "role"):
            sort = "name"
        return "200 OK", "text/html", "pages/users.jx", {"users": USERS, "q": query.get("q", ""), "sort": sort}
    if path.startswith("/users/"):
        user = next((u for u in USERS if str(u["id"]) == path.rsplit("/", 1)[1]), None)
        if user:
            return "200 OK", "text/html", "pages/user.jx", {"user": user}
    if path == "/tree":
        return "200 OK", "text/html", "pages/tree.jx", {"root": file_tree(HERE)}
    if path == "/filters":
        return "200 OK", "text/html", "pages/filters.jx", {}
    if path == "/broken":
        return "200 OK", "text/html", "pages/broken.jx", {}
    if path == "/sitemap.xml":
        paths = ["/", "/users", "/tree", "/filters"] + [f"/users/{u['id']}" for u in USERS]
        return "200 OK", "application/xml", "sitemap.xml", {"base": "http://localhost", "paths": paths}
    return "404 Not Found", "text/html", "pages/not_found.jx", {"path": path}


def error_page(title: str, detail: str) -> str:
    # Not a component: it must work when the components do not compile.
    return (
        '<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/static/app.css">'
        f'<main class="container"><h1>{html.escape(title)}</h1>'
        f'<pre class="error">{html.escape(detail)}</pre><p><a href="/">← Inicio</a></p></main>'
    )


def serve_file(base: Path, rel: str, start_response):
    file = (base / rel).resolve()
    if not file.is_relative_to(base) or not file.is_file():
        start_response("404 Not Found", [("Content-Type", "text/plain")])
        return [b"not found"]
    ctype = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    start_response("200 OK", [("Content-Type", ctype), ("Cache-Control", "no-cache")])
    return [file.read_bytes()]


def app(environ, start_response):
    path = environ.get("PATH_INFO") or "/"
    if path.startswith("/static/"):
        return serve_file(STATIC, path.removeprefix("/static/"), start_response)

    query = {k: v[0] for k, v in parse_qs(environ.get("QUERY_STRING", "")).items()}
    status, ctype, component, kwargs = route(path, query)
    globals_ = {
        "current_path": path,
        "components_count": sum(1 for _ in COMPONENTS.rglob("*.jx")),
    }

    start = time.perf_counter()
    try:
        body = catalog.render(component, globals=globals_, **kwargs)
    except CompileError as err:
        status, ctype = "500 Internal Server Error", "text/html"
        body = error_page(f"Error de compilación en {component}", str(err))
    elapsed = (time.perf_counter() - start) * 1000

    print(f"  {path:<24} {component:<22} {elapsed:7.2f} ms", file=sys.stderr)
    start_response(status, [
        ("Content-Type", f"{ctype}; charset=utf-8"),
        ("Server-Timing", f"render;dur={elapsed:.3f}"),
    ])
    return [body.encode("utf-8")]


class QuietHandler(WSGIRequestHandler):
    def log_request(self, *args, **kwargs):
        pass  # `app` prints its own line, with the render time


def main() -> None:
    port = int(os.environ.get("PORT", "8000"))
    if catalog.compiler is None:
        print("No minijx compiler found; run `make build` first.", file=sys.stderr)
        sys.exit(1)
    try:
        catalog.compile()
    except CompileError as err:
        # `pages/broken.jx` is broken on purpose; the rest still compiled.
        print(f"Compiled with errors:\n{err}\n", file=sys.stderr)
    with make_server("127.0.0.1", port, app, handler_class=QuietHandler) as server:
        print(f"minijx demo on http://127.0.0.1:{port}  (Ctrl+C to stop)", file=sys.stderr)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
