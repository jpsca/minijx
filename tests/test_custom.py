"""
Custom filters and tests passed to the catalog (compared with Jx).
"""

import pytest

from minijx import Catalog


def shout(value, suffix="!"):
    return str(value).upper() + suffix


def wrap(value, left="[", right="]"):
    return f"{left}{value}{right}"


def is_short(value, limit=3):
    return len(value) < limit


FILTERS = {"shout": shout, "wrap": wrap}
TESTS = {"short": is_short}


# Custom filters and tests, same output as Jx


def test_custom_filters_and_tests(project):
    project.write({
        "page.jx": """{# def words #}
{{ "hi" | shout }} {{ "hi" | shout("?") }} {{ "x" | wrap(left="<", right=">") }}
{% filter shout | wrap %}block{% endfilter %}
{{ words | map("shout") | join(",") }}
{{ words | select("short") | join(",") }} {{ words | reject("short", 5) | join(",") }}
{% for w in words %}{% if w is short %}[{{ w }}]{% endif %}{% if w is not short(2) %}({{ w }}){% endif %}{% endfor %}
{{ "shout" is filter }} {{ "short" is test }} {{ "nope" is filter }}
{{ [{"n": "ab"}, {"n": "abcd"}] | selectattr("n", "short") | map(attribute="n") | join }}
"""
    })
    project.assert_same("page.jx", filters=FILTERS, tests=TESTS, words=["a", "abc", "abcdef"])


def test_custom_filter_replaces_a_builtin(project):
    project.write({"page.jx": '{{ "abc" | upper }} {{ ["x", "y"] | map("upper") | join }}'})
    project.assert_same("page.jx", filters={"upper": lambda s: f"<{s}>"})


def test_custom_filters_reach_imported_components_and_fills(project):
    project.write({
        "child.jx": "{# def v #}<b>{{ v | shout }}</b>{% slot s %}{% endslot %}",
        "page.jx": """{# import "child.jx" as Child #}
{% for v in ["a", "b"] %}<Child v={{ v | wrap }}>{% fill s %}{{ v | shout("?") }}{% endfill %}</Child>{% endfor %}
<ul>{% for n in [{"k": "x", "c": [{"k": "y", "c": []}]}] recursive %}<li>{{ n.k | shout }}{{ loop(n.c) }}</li>{% endfor %}</ul>
""",
    })
    project.assert_same("page.jx", filters=FILTERS)


def test_def_defaults_are_python_as_in_jx(project):
    """`|` in a default is Python's bitwise or, not a filter; names are limited."""
    project.write({
        "page.jx": """{# def
    flags=1 | 2,
    n=len([1, 2, 3]) + max(4, 5) + pow(2, 3) + sum([1, 1]) + min(0, 1),
    s="a#b" + 'c',  # a comment
    t=true and not false,
    items=[x * 2 for x in (1, 2)],
    pairs={k: v for k, v in [("a", 1)]},
    g=(lambda y, z=1: y + z)(1),
    d={"k": (1, 2)}["k"][0],
    f=1e3,
#}
{{ flags }} {{ n }} {{ s | shout }} {{ t }} {{ items }} {{ pairs }} {{ g }} {{ d }} {{ f }}"""
    })
    project.assert_same("page.jx", filters=FILTERS)


def test_without_a_catalog_the_builtins_are_used(project):
    project.write({"page.jx": '{{ "a" | upper }}{{ 3 is odd }}'})
    assert project.render_mini("page.jx") == "ATrue"


def test_unknown_filter_at_render_time(project):
    project.write({"page.jx": '{{ "a" | nope }}'})
    with pytest.raises(KeyError, match="nope"):
        project.render_mini("page.jx")
    project.write({"page.jx": '{{ ["a"] | map("nope") | list }}'})
    with pytest.raises(KeyError, match="No filter named 'nope'"):
        project.render_mini("page.jx", filters=FILTERS)


def test_inline_tests_cannot_be_replaced(tmp_path):
    with pytest.raises(ValueError, match="'defined', 'eq'"):
        Catalog(tmp_path, tests={"eq": len, "defined": len, "short": is_short})


def test_filters_must_be_callable(tmp_path):
    with pytest.raises(TypeError, match="'shout' is not callable"):
        Catalog(tmp_path, filters={"shout": "nope"})
