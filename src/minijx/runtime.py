"""
minijx runtime: helpers the generated code calls.

Everything the compiler emits goes through the names re-exported here, so
generated modules only need `from minijx.runtime import ...`.
"""

import typing as t


_MISSING = object()


class _Undefined:
    """
    What `x | default(...)` receives when `x` does not exist: a missing
    global, attribute or item. minijx is otherwise strict and has no
    Undefined; this sentinel exists so `default` can tell "missing" from a
    real `None`, as Jinja does. It never reaches the output: `default`
    always replaces it.
    """

    __slots__ = ()

    def __bool__(self) -> bool:
        return False

    def __repr__(self) -> str:
        return "UNDEFINED"


UNDEFINED = _Undefined()


def escape(value: t.Any) -> str:
    """
    Same table as `markupsafe.escape`, returning a plain `str`.

    Objects with `__html__` are returned as-is, like Jinja does for Markup.
    """
    if hasattr(value, "__html__"):
        return value.__html__()
    return (
        str(value)
        .replace("&", "&amp;")
        .replace(">", "&gt;")
        .replace("<", "&lt;")
        .replace("'", "&#39;")
        .replace('"', "&#34;")
    )


def concat(*parts: t.Any) -> str:
    """`a ~ b ~ c`: string concatenation with str() applied to each side."""
    return "".join([str(p) for p in parts])


# Everything `getattr` can find on a plain dict. An instance of exactly `dict`
# has no `__dict__`, so its attributes are only those of the class.
_DICT_ATTRS = frozenset(dir(dict))


def getattr_(obj: t.Any, name: t.Any, default: t.Any = _MISSING) -> t.Any:
    """
    Jinja's `obj.name`: try getattr, then getitem.

    Strict: if neither works and no default was given, raises AttributeError
    instead of returning Undefined.

    Shortcut for plain dicts: when `name` is not an attribute of `dict`, the
    `getattr` is bound to fail, and raising and catching that AttributeError
    costs more than the whole lookup. Going straight to the key gives the same
    result. Subclasses of `dict` take the general path, since they can define
    their own attributes.
    """
    if type(obj) is dict and type(name) is str and name not in _DICT_ATTRS:
        value = obj.get(name, _MISSING)
        if value is not _MISSING:
            return value
        if default is not _MISSING:
            return default
        raise AttributeError(f"'dict' object has no attribute or item {name!r}")
    if isinstance(name, str):
        try:
            return getattr(obj, name)
        except AttributeError:
            pass
    try:
        return obj[name]
    except (TypeError, LookupError, AttributeError):
        pass
    if default is not _MISSING:
        return default
    raise AttributeError(f"{type(obj).__name__!r} object has no attribute or item {name!r}")


def getitem(obj: t.Any, name: t.Any, default: t.Any = _MISSING) -> t.Any:
    """
    Jinja's `obj[name]`: try getitem, then getattr (the opposite order).
    """
    try:
        return obj[name]
    except (TypeError, LookupError, AttributeError):
        pass
    if isinstance(name, str):
        try:
            return getattr(obj, name)
        except AttributeError:
            pass
    if default is not _MISSING:
        return default
    raise AttributeError(f"{type(obj).__name__!r} object has no item or attribute {name!r}")


_ABSENT = object()


def has_attr(obj: t.Any, name: t.Any) -> bool:
    """`obj.name is defined`."""
    return getattr_(obj, name, _ABSENT) is not _ABSENT


def resolve_filter(name: str) -> t.Callable:
    from . import filters

    try:
        return filters.FILTERS[name]
    except KeyError:
        raise KeyError(f"No filter named {name!r}") from None


def resolve_test(name: str) -> t.Callable:
    from . import tests

    try:
        return tests.TESTS[name]
    except KeyError:
        raise KeyError(f"No test named {name!r}") from None


def to_str(value: t.Any) -> str:
    """`{{ value }}`: str() of anything, `None` renders as `None` like Jinja."""
    return value if type(value) is str else str(value)


def range_(*args):
    """Jinja's `range` global; identical to Python's."""
    return range(*args)


def namespace(**kwargs):
    raise NotImplementedError("namespace() is not supported by minijx")


BUILTINS: dict[str, t.Any] = {
    "range": range,
    "dict": dict,
    "list": list,
    "tuple": tuple,
    "set": set,
    "len": len,
    "min": min,
    "max": max,
    "sum": sum,
    "abs": abs,
    "round": round,
    "str": str,
    "int": int,
    "float": float,
    "bool": bool,
    "zip": zip,
    "enumerate": enumerate,
    "sorted": sorted,
    "reversed": reversed,
    "isinstance": isinstance,
    "getattr": getattr,
    "hasattr": hasattr,
}


from .attrs import Attrs  # noqa: E402
from .loop import Loop  # noqa: E402


__all__ = [
    "UNDEFINED", "Attrs", "Loop", "escape", "concat", "getattr_", "getitem", "has_attr",
    "resolve_filter", "resolve_test", "to_str",
]
