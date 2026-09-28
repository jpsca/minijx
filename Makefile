FPC ?= fpc
# the options live in compiler/minijx.cfg, shared with hatch_build.py
FPCFLAGS ?= @compiler/minijx.cfg -Fucompiler -FEbuild -FUbuild/units
# the one place the version is written; the binary gets it from here
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)
BIN = build/minijx
# where the package looks for its binary; the wheel build puts it there too
PKG_BIN = src/minijx/bin/minijx

# A Python with jx, jinja2 and pytest. The default is the Jx checkout next
# to this one; `make test JX_PYTHON="uv run --group test python"` works too.
JX_PYTHON ?= ../jx/.venv/bin/python

.PHONY: all build test example bench wheel sdist dist clean install lint lint-fix

all: build

build: $(BIN) $(PKG_BIN)

$(BIN): compiler/*.pas compiler/*.lpr compiler/minijx.cfg pyproject.toml
	mkdir -p build/units
	MINIJX_VERSION=$(VERSION) $(FPC) $(FPCFLAGS) compiler/minijx.lpr

$(PKG_BIN): $(BIN)
	mkdir -p $(dir $(PKG_BIN))
	cp $(BIN) $(PKG_BIN)

test: build
	PYTHONPATH=src $(JX_PYTHON) -m pytest -q tests

example: build
	PYTHONPATH=src python3 example/app.py

bench: build
	PYTHONPATH=src $(JX_PYTHON) bench/bench_example.py

# One wheel for this platform, with the binary inside, and the sdist.
wheel:
	uv build --wheel --out-dir dist

sdist:
	uv build --sdist --out-dir dist

dist: wheel sdist

clean:
	rm -rf build dist $(dir $(PKG_BIN))

install:
	uv sync --group dev --group test
	uv pip install -e .

lint:
	uv run ruff check src/minijx tests
	uv run ty check

lint-fix:
	uv run ruff check src/minijx tests --fix
