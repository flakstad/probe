from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path


@dataclass(frozen=True)
class EvalConfig:
    package: Path
    code: str
    print_result: bool = True
    extra_imports: tuple[str, ...] = ()
    import_path: str | None = None
    package_name: str = "main"


def odin_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_runner(config: EvalConfig) -> str:
    package = config.package.resolve()
    import_path = config.import_path or str(package)
    imports = ['import "core:fmt"', f"import target {odin_string(import_path)}"]
    imports.extend(config.extra_imports)

    body: list[str] = []
    if config.print_result:
        lines = code_lines(config.code)
        if len(lines) > 1:
            body.extend(f"    {line}" for line in lines[:-1])
            body.append(f"    result := {lines[-1]}")
        else:
            body.append(f"    result := {config.code}")
        body.append("    fmt.println(result)")
    else:
        for line in config.code.splitlines():
            body.append(f"    {line}" if line.strip() else "")

    return "\n".join(
        [
            "package main",
            "",
            *imports,
            "",
            "main :: proc() {",
            *body,
            "}",
            "",
        ]
    )


def render_internal_runner(config: EvalConfig) -> str:
    imports = ['import "core:fmt"']
    imports.extend(config.extra_imports)

    body: list[str] = []
    if config.print_result:
        lines = code_lines(config.code)
        if len(lines) > 1:
            body.extend(f"    {line}" for line in lines[:-1])
            body.append(f"    result := {lines[-1]}")
        else:
            body.append(f"    result := {config.code}")
        body.append("    fmt.println(result)")
    else:
        for line in config.code.splitlines():
            body.append(f"    {line}" if line.strip() else "")

    return "\n".join(
        [
            f"package {config.package_name}",
            "",
            *imports,
            "",
            "main :: proc() {",
            *body,
            "}",
            "",
        ]
    )


def code_lines(code: str) -> list[str]:
    return [line for line in (line.strip() for line in code.splitlines()) if line]


def write_runner(config: EvalConfig, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    relative_import = os.path.relpath(config.package.resolve(), directory.resolve())
    config = replace(config, import_path=relative_import)
    path = directory / "main.odin"
    path.write_text(render_runner(config), encoding="utf-8")
    return path


def package_name_from_source(source: str) -> str:
    match = re.search(r"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)\b", source)
    if not match:
        raise ValueError("could not find Odin package declaration")
    return match.group(1)


def rename_entry_main(source: str) -> str:
    return re.sub(
        r"(?m)^(\s*)main(\s*::\s*proc\b)",
        r"\1odineval_original_main\2",
        source,
    )


DECLARATION_RE = re.compile(
    r"^\s*(?:package\b|import\b|foreign\b|when\b|@\(|#|[A-Za-z_][A-Za-z0-9_]*\s*(?:::|:\s|:=\s*proc\b))"
)


def comment_top_level_scratch_lines(source: str) -> str:
    """Comment obvious top-level scratch expressions in SOURCE.

    This lets files contain Clojure-style scratch calls such as `add(5, 3)` at
    file scope while internal eval compiles a temp copy. It is intentionally
    conservative and line-oriented; valid declarations are left unchanged.
    """
    out: list[str] = []
    depth = 0
    for line in source.splitlines():
        stripped = line.strip()
        at_top = depth == 0
        should_comment = (
            at_top
            and stripped
            and not stripped.startswith("//")
            and not stripped.startswith("/*")
            and not stripped.startswith("*")
            and not stripped in {"}", "},"}
            and not DECLARATION_RE.match(line)
        )
        out.append(f"// odineval scratch: {line}" if should_comment else line)
        depth += line.count("{") - line.count("}")
        if depth < 0:
            depth = 0
    return "\n".join(out) + ("\n" if source.endswith("\n") else "")


def copy_package_for_internal_eval(package: Path, directory: Path) -> str:
    directory.mkdir(parents=True, exist_ok=True)
    package_name: str | None = None
    copied = False

    for source_path in sorted(package.glob("*.odin")):
        source = source_path.read_text(encoding="utf-8")
        if package_name is None:
            package_name = package_name_from_source(source)
        source = rename_entry_main(source)
        source = comment_top_level_scratch_lines(source)
        (directory / source_path.name).write_text(source, encoding="utf-8")
        copied = True

    if not copied:
        raise ValueError(f"no .odin files found in package: {package}")
    if package_name is None:
        raise ValueError(f"could not determine package name: {package}")
    return package_name


def write_internal_runner(config: EvalConfig, directory: Path) -> Path:
    package_name = copy_package_for_internal_eval(config.package.resolve(), directory)
    config = replace(config, package_name=package_name)
    path = directory / "odineval_runner.odin"
    path.write_text(render_internal_runner(config), encoding="utf-8")
    return path


def run_odin(action: str, runner_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["odin", action, str(runner_dir)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def run_odin_package(action: str, package: Path, extra_args: tuple[str, ...] = ()) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["odin", action, str(package), *extra_args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def command_eval(args: argparse.Namespace, action: str) -> int:
    package = Path(args.package)
    if not package.exists():
        print(f"package path does not exist: {package}", file=sys.stderr)
        return 2

    config = EvalConfig(
        package=package,
        code=args.code,
        print_result=not args.no_print,
        extra_imports=tuple(args.imports or ()),
    )

    keep_dir = Path(args.keep_dir).expanduser().resolve() if args.keep_dir else None
    with tempfile.TemporaryDirectory(prefix="odineval-") as tmp:
        runner_dir = keep_dir or Path(tmp)
        try:
            runner = write_internal_runner(config, runner_dir) if args.internal else write_runner(config, runner_dir)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2

        if args.show:
            print(runner.read_text(encoding="utf-8"), end="")

        result = run_odin(action, runner_dir)
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        return result.returncode


def command_package(args: argparse.Namespace, action: str) -> int:
    package = Path(args.package)
    if not package.exists():
        print(f"package path does not exist: {package}", file=sys.stderr)
        return 2

    result = run_odin_package(action, package, tuple(args.odin_args or ()))
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="odineval")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("run", "check"):
        p = subparsers.add_parser(name)
        p.add_argument("package", help="Path to the Odin package to import as `target`.")
        p.add_argument("code", help="Odin expression or statement snippet to run.")
        p.add_argument("--no-print", action="store_true", help="Treat code as statements and do not print a result.")
        p.add_argument("--show", action="store_true", help="Print generated Odin before invoking Odin.")
        p.add_argument(
            "--internal",
            action="store_true",
            help="Copy the target package to a scratch directory and evaluate code inside that package.",
        )
        p.add_argument("--keep-dir", help="Write runner into this directory instead of a temporary directory.")
        p.add_argument(
            "--import",
            dest="imports",
            action="append",
            help='Extra raw Odin import line, e.g. \'import "core:strings"\'.',
        )

    for name, action in (
        ("package-run", "run"),
        ("package-build", "build"),
        ("package-check", "check"),
        ("package-test", "test"),
    ):
        p = subparsers.add_parser(name)
        p.set_defaults(odin_action=action)
        p.add_argument("package", help=f"Path to the Odin package to `{action}`.")
        p.add_argument("odin_args", nargs=argparse.REMAINDER, help="Additional arguments passed to Odin.")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if shutil.which("odin") is None:
        print("odin not found on PATH", file=sys.stderr)
        return 127

    if args.command == "run":
        return command_eval(args, "run")
    if args.command == "check":
        return command_eval(args, "check")
    if args.command in {"package-run", "package-build", "package-check", "package-test"}:
        return command_package(args, args.odin_action)

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
