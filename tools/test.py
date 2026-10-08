#!/usr/bin/env python3
"""Validate the extension and run isolated tests using local Lua and Python.

Usage: python3 tools/test.py [--require-lua] [--xml-only]
No packages or network access are needed. A Lua executable or a Lua 5.2–5.4
shared library is sufficient; --require-lua makes an absent runtime an error.
This checks code outside Fantasy Grounds and cannot certify its host APIs.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


PROJECT = Path(__file__).resolve().parents[1]


def validate_xml(project: Path) -> tuple[list[str], int, int]:
    """Check XML syntax and local file references without guessing FG schemas."""
    extension = project / "extension"
    errors: list[str] = []
    files = sorted(extension.rglob("*.xml")) if extension.is_dir() else []
    entry = extension / "extension.xml"
    if not entry.is_file():
        errors.append("Missing extension/extension.xml")
    references = 0
    for path in files:
        relative = path.relative_to(project).as_posix()
        try:
            tree = ET.parse(path)
        except (ET.ParseError, OSError) as exc:
            errors.append(f"{relative}: {exc}")
            continue
        root = tree.getroot()
        if path == entry:
            if root.tag != "root":
                errors.append(f"{relative}: top-level element must be <root>")
            if root.find("base") is None:
                errors.append(f"{relative}: missing extension <base>")
            if not (root.findtext("properties/name") or "").strip():
                errors.append(f"{relative}: missing extension name")
        for element in root.iter():
            candidates = []
            if "file" in element.attrib:
                candidates.append(element.attrib["file"])
            if element.tag == "includefile":
                candidates.append(element.attrib.get("source", ""))
            for value in candidates:
                references += 1
                pure = PurePosixPath(value.replace("\\", "/"))
                if not value or pure.is_absolute() or ".." in pure.parts or ":" in value:
                    errors.append(f"{relative}: invalid local file reference {value!r}")
                    continue
                target = extension.joinpath(*pure.parts)
                if not target.is_file():
                    errors.append(f"{relative}: referenced file is missing: {value}")
                elif not target.resolve().is_relative_to(extension.resolve()):
                    errors.append(f"{relative}: reference leaves extension directory: {value}")
    return errors, len(files), references


def find_lua() -> tuple[str, str] | None:
    """Prefer real interpreters; use the local C API if no executable is present."""
    requested = os.environ.get("ARMSBRIDGE_LUA")
    executables = [requested] if requested else ["lua5.1", "luajit", "lua5.2", "lua5.3", "lua5.4", "lua"]
    for executable in executables:
        if executable and (found := shutil.which(executable)):
            return "executable", found
    requested_library = os.environ.get("ARMSBRIDGE_LUA_LIBRARY")
    libraries = [requested_library] if requested_library else [
        ctypes.util.find_library(name) for name in ("lua5.4", "lua5.3", "lua5.2", "lua")
    ]
    for library in libraries:
        if not library:
            continue
        try:
            handle = ctypes.CDLL(library)
            for name in ("luaL_newstate", "luaL_openlibs", "luaL_loadfilex", "lua_pcallk", "lua_tolstring", "lua_close"):
                getattr(handle, name)
        except (OSError, AttributeError):
            continue
        return "library", library
    return None


def library_worker(library: str, mode: str, filename: Path) -> int:
    """Execute in a child process so each test gets a clean Lua state."""
    lib = ctypes.CDLL(library)
    lib.luaL_newstate.argtypes = []
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lib.luaL_openlibs.restype = None
    lib.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.luaL_loadfilex.restype = ctypes.c_int
    lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
    lib.lua_pcallk.restype = ctypes.c_int
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lib.lua_tolstring.restype = ctypes.c_void_p
    lib.lua_close.argtypes = [ctypes.c_void_p]
    lib.lua_close.restype = None
    state = lib.luaL_newstate()
    if not state:
        print("Unable to allocate Lua state", file=sys.stderr)
        return 1
    try:
        lib.luaL_openlibs(state)
        status = lib.luaL_loadfilex(state, os.fsencode(filename), None)
        if status == 0 and mode == "test":
            status = lib.lua_pcallk(state, 0, -1, 0, 0, None)
        if status:
            length = ctypes.c_size_t()
            pointer = lib.lua_tolstring(state, -1, ctypes.byref(length))
            message = ctypes.string_at(pointer, length.value).decode("utf-8", "replace") if pointer else "Non-string Lua error"
            print(message, file=sys.stderr)
            return 1
        return 0
    finally:
        lib.lua_close(state)


def run_process(command: list[str], project: Path, timeout: float, env: dict | None = None) -> tuple[bool, str]:
    try:
        result = subprocess.run(command, cwd=project, env=env, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, str(exc)
    output = (result.stdout + result.stderr).strip()
    if result.returncode and not output:
        output = f"Process exited with status {result.returncode}"
    return result.returncode == 0, output


def run_lua(backend: tuple[str, str], mode: str, filename: Path, project: Path, timeout: float) -> tuple[bool, str]:
    kind, location = backend
    if kind == "library":
        command = [sys.executable, str(Path(__file__).resolve()), "--lua-worker", mode, "--lua-library", location, "--lua-file", str(filename)]
        return run_process(command, project, timeout)
    env = os.environ.copy()
    if mode == "syntax":
        env["ARMSBRIDGE_LUA_FILE"] = str(filename)
        command = [location, "-e", "assert(loadfile(os.getenv('ARMSBRIDGE_LUA_FILE')))"]
    else:
        command = [location, str(filename)]
    return run_process(command, project, timeout, env)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--require-lua", action="store_true")
    parser.add_argument("--xml-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--test", type=Path, help="Run one project test instead of all test_*.lua/py")
    parser.add_argument("--lua-worker", choices=["syntax", "test"], help=argparse.SUPPRESS)
    parser.add_argument("--lua-library", help=argparse.SUPPRESS)
    parser.add_argument("--lua-file", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.lua_worker:
        if not args.lua_library or not args.lua_file:
            parser.error("Lua worker requires a library and filename")
        return library_worker(args.lua_library, args.lua_worker, args.lua_file)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    project = args.project.resolve()
    errors, xml_count, references = validate_xml(project)
    for error in errors:
        print(f"FAIL XML: {error}")
    if errors:
        return 1
    print(f"PASS XML: {xml_count} documents, {references} local file references")
    if args.xml_only:
        return 0
    backend = find_lua()
    if backend:
        print(f"Lua backend: {backend[0]} {backend[1]}")
    elif args.require_lua:
        print("FAIL: No Lua executable or Lua 5.2–5.4 shared library is available.")
        return 1
    else:
        print("SKIP Lua: no local runtime; this is not a complete validation. Use --require-lua in release checks.")
    if args.test:
        selected = (project / args.test).resolve()
        if not selected.is_file() or selected.suffix not in (".lua", ".py"):
            parser.error("--test must identify an existing Lua or Python test")
        tests = [selected]
    else:
        tests = sorted((project / "tests").glob("test_*.lua")) + sorted((project / "tests").glob("test_*.py"))
    failures = 0
    syntax_count = 0
    if backend:
        for filename in sorted((project / "extension").rglob("*.lua")):
            okay, output = run_lua(backend, "syntax", filename, project, args.timeout)
            syntax_count += 1
            if not okay:
                failures += 1
                print(f"FAIL syntax {filename.relative_to(project)}\n{output}")
        with tempfile.TemporaryDirectory(prefix="armsbridge-inline-") as directory:
            for xml_file in sorted((project / "extension").rglob("*.xml")):
                for position, element in enumerate(ET.parse(xml_file).getroot().iter("script"), 1):
                    code = (element.text or "").strip()
                    if not code:
                        continue
                    filename = Path(directory) / "inline.lua"
                    filename.write_text(code + "\n", encoding="utf-8")
                    okay, output = run_lua(backend, "syntax", filename, project, args.timeout)
                    syntax_count += 1
                    if not okay:
                        failures += 1
                        print(f"FAIL inline Lua {xml_file.relative_to(project)}, script {position}\n{output}")
        print(f"Lua syntax: {syntax_count} external and inline scripts checked")
    executed = 0
    skipped = 0
    for filename in tests:
        if filename.suffix == ".lua":
            if not backend:
                skipped += 1
                continue
            okay, output = run_lua(backend, "test", filename, project, args.timeout)
        else:
            okay, output = run_process([sys.executable, str(filename)], project, args.timeout)
        executed += 1
        failures += int(not okay)
        display = filename.relative_to(project) if filename.is_relative_to(project) else filename
        print(f"{'PASS' if okay else 'FAIL'} {display}")
        if output:
            print(output)
    print(f"Result: {executed} test files executed, {skipped} skipped, {failures} failures.")
    print("Scope: standalone syntax, XML, and mocked tests; Fantasy Grounds integration requires an in-app smoke test.")
    return int(failures > 0)


if __name__ == "__main__":
    raise SystemExit(main())
