"""
The `minijx` command: runs the compiler binary shipped inside the package.

    minijx components/ [more/folders/]
    python -m minijx --version
"""

import os
import sys

from .catalog import bundled_compiler


def main() -> None:
    binary = bundled_compiler()
    if binary is None:
        sys.exit(
            "minijx: this installation has no compiler binary "
            "(from a source checkout, run `make build` first)"
        )
    # Replace this process: exit code, stdout and stderr are the binary's own.
    os.execv(binary, [str(binary), *sys.argv[1:]])


if __name__ == "__main__":
    main()
