"""
minijx runtime: the `attrs` object, with the same rules as Jx.

- classes given to `render()` come before the caller's classes
- underscores in names become dashes
- `True` is a boolean property, `False`/`None` removes the attribute
- attributes are sorted by name, then properties sorted by name
"""

import typing as t


CLASS_KEY = "class"
CLASS_ALT_KEY = "classes"
CLASS_KEYS = (CLASS_KEY, CLASS_ALT_KEY)


def quote(value: t.Any) -> str:
    """Wrap an attribute value in quotes. Only the quote itself is escaped."""
    text = str(value)
    if '"' in text:
        if "'" in text:
            text = text.replace('"', "&quot;")
            return f'"{text}"'
        return f"'{text}'"
    return f'"{text}"'


class Attrs:
    __slots__ = ("_classes", "_attributes", "_properties")

    def __init__(self, attrs: "dict[str, t.Any] | None" = None) -> None:
        if not attrs:
            self._classes: tuple[str, ...] = ()
            self._attributes: dict[str, t.Any] = {}
            self._properties: set[str] = set()
            return

        attributes: dict[str, t.Any] = {}
        properties: set[str] = set()

        cls1 = attrs.get(CLASS_KEY, "")
        cls2 = attrs.get(CLASS_ALT_KEY, "")
        if cls1 or cls2:
            classes: list[str] = []
            for name in f"{cls1} {cls2}".split():
                if name and name not in classes:
                    classes.append(name)
            self._classes = tuple(classes)
        else:
            self._classes = ()

        for name, value in attrs.items():
            if name.startswith("_") or name in CLASS_KEYS:
                continue
            name = name.replace("_", "-")
            if value is True:
                properties.add(name)
            elif value is not False and value is not None:
                attributes[name] = value

        self._attributes = attributes
        self._properties = properties

    @property
    def classes(self) -> str:
        return " ".join(self._classes)

    @property
    def as_dict(self) -> dict[str, t.Any]:
        attributes = self._attributes.copy()
        classes = self.classes
        if classes:
            attributes[CLASS_KEY] = classes
        out: dict[str, t.Any] = dict(sorted(attributes.items()))
        for name in sorted(self._properties):
            out[name] = True
        return out

    def __getitem__(self, name: str) -> t.Any:
        return self.get(name)

    def __delitem__(self, name: str) -> None:
        self._remove(name)

    def __str__(self) -> str:
        return str(self.as_dict)

    def __repr__(self) -> str:
        return f"Attrs({self.as_dict!r})"

    def set(self, **kw) -> None:
        for name, value in kw.items():
            name = name.replace("_", "-")
            if value is False or value is None:
                self._remove(name)
                continue
            if name in CLASS_KEYS:
                self.add_class(value)
            elif value is True:
                self._properties.add(name)
            else:
                self._attributes[name] = value

    def setdefault(self, **kw) -> None:
        for name, value in kw.items():
            name = name.replace("_", "-")
            if value is False or value is None:
                continue
            if name in CLASS_KEYS:
                if not self._classes:
                    self.add_class(value)
                continue
            if value is True:
                if name not in self._properties:
                    self._properties.add(name)
            elif name not in self._attributes:
                self._attributes[name] = value

    def add_class(self, *values: str) -> None:
        new = list(self._classes)
        for names in values:
            for name in str(names).strip().split():
                if name not in new:
                    new.append(name)
        self._classes = tuple(new)

    def prepend_class(self, *values: str) -> None:
        new: list[str] = []
        for names in values:
            for name in str(names).strip().split():
                if name not in self._classes and name not in new:
                    new.append(name)
        self._classes = tuple(new) + self._classes

    def remove_class(self, *names: str) -> None:
        self._classes = tuple(c for c in self._classes if c not in names)

    def get(self, name: str, default: t.Any = None) -> t.Any:
        name = name.replace("_", "-")
        if name in CLASS_KEYS:
            return self.classes
        if name in self._attributes:
            return self._attributes[name]
        if name in self._properties:
            return True
        return default

    def render(self, **kw) -> str:
        if kw:
            render_classes = None
            for key in CLASS_KEYS:
                if key in kw:
                    render_classes = kw.pop(key)

            attributes = dict(self._attributes)
            classes = list(self._classes)
            properties = set(self._properties)

            for name, value in kw.items():
                name = name.replace("_", "-")
                if value is False or value is None:
                    attributes.pop(name, None)
                    properties.discard(name)
                elif value is True:
                    properties.add(name)
                else:
                    attributes[name] = value

            if render_classes:
                new = [name for name in str(render_classes).strip().split() if name not in classes]
                classes = new + classes
        else:
            attributes = self._attributes
            classes = list(self._classes)
            properties = self._properties

        if not attributes and not classes and not properties:
            return ""

        if classes:
            items = {**attributes, CLASS_KEY: " ".join(classes)}
        else:
            items = attributes

        if len(items) > 1:
            items = dict(sorted(items.items()))

        html_attrs = [f"{name}={quote(value)}" for name, value in items.items()]
        if properties:
            html_attrs.extend(sorted(properties))
        return " ".join(html_attrs)

    def _remove(self, name: str) -> None:
        if name in CLASS_KEYS:
            self._classes = ()
        else:
            self._attributes.pop(name, None)
            self._properties.discard(name)
