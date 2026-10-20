#!/usr/bin/env python3
"""Checks that every test docs/edge-cases.md names exists, so the list can't drift from the tests.

References are `make <target>`, `spec "<name>"`, `python <name>` and `swift "<name>"`.
Exits 1 and lists the missing ones.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REFERENCE = re.compile(r'`(make [\w-]+|spec "[^"]+"|python \w+|swift "[^"]+")`')


def sources(pattern):
    return "\n".join(p.read_text() for p in sorted(ROOT.glob(pattern)))


def missing(doc, makefile, specs, python, swift):
    """The references in `doc` that name no existing test, in order."""
    gone = []
    for ref in REFERENCE.findall(doc):
        kind, _, name = ref.partition(" ")
        if kind == "make":
            found = re.search(rf"^{re.escape(name)}:", makefile, re.M)
        elif kind == "spec":
            found = f"it({name}" in specs
        elif kind == "python":
            found = re.search(rf"def {re.escape(name)}\(", python)
        else:
            found = f"test({name})" in swift
        if not found:
            gone.append(ref)
    return gone


def main():
    doc = (ROOT / "docs/edge-cases.md").read_text()
    gone = missing(doc, (ROOT / "Makefile").read_text(), sources("spec/*.lua"),
                   sources("tests/test_*.py"), sources("recorder/Tests/*.swift"))
    if not REFERENCE.search(doc):
        print("docs/edge-cases.md names no tests")
        return 1
    for ref in gone:
        print(f"docs/edge-cases.md names a test that doesn't exist: {ref}")
    return 1 if gone else 0


if __name__ == "__main__":
    sys.exit(main())
