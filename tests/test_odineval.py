from __future__ import annotations

import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from src.odineval import EvalConfig, comment_top_level_scratch_lines, render_internal_runner, render_runner


class RenderTests(unittest.TestCase):
    def test_render_printing_runner(self) -> None:
        runner = render_runner(EvalConfig(package=Path("/tmp/pkg"), code="target.answer()", import_path="../pkg"))

        self.assertIn('import "core:fmt"', runner)
        self.assertIn('import target "../pkg"', runner)
        self.assertIn("result := target.answer()", runner)
        self.assertIn("fmt.println(result)", runner)

    def test_render_no_print_runner(self) -> None:
        runner = render_runner(EvalConfig(package=Path("/tmp/pkg"), code="target.run()", print_result=False))

        self.assertIn("    target.run()", runner)
        self.assertNotIn("fmt.println(result)", runner)

    def test_render_internal_runner(self) -> None:
        runner = render_internal_runner(EvalConfig(package=Path("/tmp/pkg"), code="add(5, 2)", package_name="main"))

        self.assertIn("package main", runner)
        self.assertIn("result := add(5, 2)", runner)
        self.assertNotIn("import target", runner)

    def test_render_internal_runner_multiline_setup_then_result(self) -> None:
        runner = render_internal_runner(EvalConfig(package=Path("/tmp/pkg"), code="x := 1\nadd(x, 3)", package_name="main"))

        self.assertIn("    x := 1", runner)
        self.assertIn("    result := add(x, 3)", runner)
        self.assertNotIn("result := x := 1", runner)

    def test_comment_top_level_scratch_lines(self) -> None:
        source = textwrap.dedent(
            """\
            package main

            add :: proc(a: int, b: int) -> int {
                return a + b
            }

            add(5,3)
            """
        )

        commented = comment_top_level_scratch_lines(source)

        self.assertIn("add :: proc", commented)
        self.assertIn("// odineval scratch: add(5,3)", commented)


@unittest.skipIf(shutil.which("odin") is None, "odin not available")
class OdinIntegrationTests(unittest.TestCase):
    def test_run_external_package_proc(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "sample"
            pkg.mkdir()
            (pkg / "sample.odin").write_text(
                textwrap.dedent(
                    """\
                    package sample

                    answer :: proc() -> int {
                        return 42
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "run", str(pkg), "target.answer()"],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "42")

    def test_run_internal_package_main_comment_style_call(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "app"
            pkg.mkdir()
            (pkg / "app.odin").write_text(
                textwrap.dedent(
                    """\
                    package main

                    import "core:fmt"

                    add :: proc(a: int, b: int) -> int {
                        return a + b
                    }

                    main :: proc() {
                        fmt.println(add(1, 2))
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "run", str(pkg), "add(5, 2)", "--internal"],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "7")

    def test_run_internal_ignores_top_level_scratch_call(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "app"
            pkg.mkdir()
            (pkg / "app.odin").write_text(
                textwrap.dedent(
                    """\
                    package main

                    import "core:fmt"

                    add :: proc(a: int, b: int) -> int {
                        return a + b
                    }

                    // add(5, 2)
                    add(5, 3)

                    main :: proc() {
                        fmt.println(add(1, 2))
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "run", str(pkg), "add(5, 2)", "--internal"],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "7")

    def test_run_internal_multiline_comment_block_setup_then_result(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "app"
            pkg.mkdir()
            (pkg / "app.odin").write_text(
                textwrap.dedent(
                    """\
                    package main

                    add :: proc(a: int, b: int) -> int {
                        return a + b
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "run", str(pkg), "x := 1\nadd(x, 3)", "--internal"],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "4")

    def test_package_run_invokes_standard_main(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "app"
            pkg.mkdir()
            (pkg / "app.odin").write_text(
                textwrap.dedent(
                    """\
                    package main

                    import "core:fmt"

                    main :: proc() {
                        fmt.println("ordinary main")
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "package-run", str(pkg)],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "ordinary main")

    def test_package_test_invokes_odin_tests(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "app"
            pkg.mkdir()
            (pkg / "app.odin").write_text(
                textwrap.dedent(
                    """\
                    package sample

                    import "core:testing"

                    @(test)
                    sample_test :: proc(t: ^testing.T) {
                        testing.expect_value(t, 2 + 2, 4)
                    }
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                ["python3", "-m", "src.odineval", "package-test", str(pkg)],
                cwd=Path(__file__).resolve().parents[1],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
