"""
The demo app: every route renders through the catalog, and the component
that is broken on purpose is reported without taking the others down.
"""

import importlib.util
from wsgiref.util import setup_testing_defaults

import pytest
from conftest import REPO


EXAMPLE = REPO / "example"


@pytest.fixture(scope="module")
def demo():
    spec = importlib.util.spec_from_file_location("minijx_demo_app", EXAMPLE / "app.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def get(demo, path: str, query: str = ""):
    environ = {"PATH_INFO": path, "QUERY_STRING": query}
    setup_testing_defaults(environ)
    environ["PATH_INFO"] = path
    out = {}

    def start_response(status, headers):
        out["status"] = status
        out["headers"] = dict(headers)

    body = b"".join(demo.app(environ, start_response)).decode("utf-8")
    return out["status"], out["headers"], body


@pytest.mark.parametrize(
    "path,query,expected",
    [
        ("/", "", "Edad promedio: 33.7"),
        ("/", "", '<a href="/" aria-current="page" class="nav-link active">Inicio</a>'),
        ("/users", "q=an&sort=age", "Ana Torres"),
        ("/users", "q=<script>", "&lt;script&gt;"),
        ("/users/1", "", "example.com/ana"),
        ("/users/2", "", "Sin biografía."),
        ("/tree", "", "app.py"),
        ("/filters", "", "B4N4N4"),
        ("/filters", "", "&lt;b&gt;negrita&lt;/b&gt;"),
        ("/sitemap.xml", "", "<loc>http://localhost/users/7</loc>"),
    ],
)
def test_pages(demo, path, query, expected):
    status, headers, body = get(demo, path, query)
    assert status == "200 OK"
    assert "render;dur=" in headers["Server-Timing"]
    assert expected in body


def test_assets_of_the_page_tree(demo):
    _, _, body = get(demo, "/tree")
    assert '<link rel="stylesheet" href="/static/tree.css">' in body
    assert '<link rel="stylesheet" href="/static/app.css">' in body
    assert '<script type="module" src="/static/app.js"></script>' in body


def test_search_with_no_results(demo):
    _, _, body = get(demo, "/users", "q=zzz")
    assert "No hay usuarios que contengan «zzz»" in body


def test_not_found(demo):
    status, _, body = get(demo, "/nope")
    assert status == "404 Not Found"
    assert "<code>/nope</code>" in body


def test_broken_component_reports_its_position(demo):
    status, _, body = get(demo, "/broken")
    assert status.startswith("500")
    assert "broken.jx:6:16: Expected `)`" in body
    # the others still work afterwards
    assert get(demo, "/")[0] == "200 OK"


def test_static(demo):
    status, headers, _ = get(demo, "/static/app.css")
    assert status == "200 OK"
    assert headers["Content-Type"] == "text/css"
    assert get(demo, "/static/../app.py")[0].startswith("404")


def test_sitemap_is_well_formed_xml(demo):
    import xml.etree.ElementTree as ET

    _, headers, body = get(demo, "/sitemap.xml")
    assert headers["Content-Type"].startswith("application/xml")
    assert body.startswith("<?xml")
    root = ET.fromstring(body.encode())
    assert len(root) == 4 + 7
