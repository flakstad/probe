# odineval

`odineval` is an experiment in REPL-like development tooling for Odin without
changing Odin itself.

Odin is compiled and statically checked, so this is not a real REPL. The goal is
to make common exploratory actions cheap:

- run one proc without editing `main`
- evaluate a small package-context expression
- generate a temporary runner package
- compile/run with the real Odin compiler
- show the generated Odin when debugging

The core rule: Odin remains the source of truth. `odineval` generates ordinary
Odin and invokes `odin run` or `odin check`.

## Current MVP

External package eval:

```sh
python3 -m src.odineval run /path/to/package 'target.some_proc()'
```

This generates a temporary Odin program like:

```odin
package main

import "core:fmt"
import target "/path/to/package"

main :: proc() {
    result := target.some_proc()
    fmt.println(result)
}
```

For void procedures or statement snippets:

```sh
python3 -m src.odineval run /path/to/package 'target.do_work()' --no-print
```

To inspect generated Odin:

```sh
python3 -m src.odineval run /path/to/package 'target.some_proc()' --show
```

To check without running:

```sh
python3 -m src.odineval check /path/to/package 'target.some_proc()'
```

Standard Odin package commands:

```sh
python3 -m src.odineval package-run /path/to/package
python3 -m src.odineval package-build /path/to/package
python3 -m src.odineval package-check /path/to/package
python3 -m src.odineval package-test /path/to/package
```

## Emacs

The repo includes a small Emacs integration at `emacs/odineval.el`. It uses the
local Python CLI and displays command output in `*Odin Eval*`.

Minimal setup:

```elisp
(add-to-list 'load-path "/Users/andreas/Projects/odineval/emacs")
(require 'odineval)

;; If you use odin-mode:
(add-hook 'odin-mode-hook #'odineval-setup-odin-mode-keys)
```

Default commands:

- `M-x odineval-run-expression`: prompt for an Odin expression and print result
- `M-x odineval-run-line`: run current line, or whole `//` block at point
- `M-x odineval-run-region`: run selected expression; with prefix, run as statements
- `M-x odineval-check-expression`: compile-check a generated runner
- `M-x odineval-run-comment-block`: run a contiguous `//` comment block as code
- `M-x odineval-run-proc`: call `target.<proc>(<args>)`
- `M-x odineval-run-proc-no-args`: call `target.<symbol-at-point>()`
- `M-x odineval-run-package`: run ordinary `odin run .` in the current package
- `M-x odineval-build-package`: run ordinary `odin build .` in the current package
- `M-x odineval-check-package`: run ordinary `odin check .` in the current package
- `M-x odineval-test-package`: run ordinary `odin test .` in the current package
- `M-x odineval-run-project`: run ordinary `odin run .` at the detected project root
- `M-x odineval-build-project`: run ordinary `odin build .` at the detected project root
- `M-x odineval-check-project`: run ordinary `odin check .` at the detected project root
- `M-x odineval-test-project`: run ordinary `odin test .` at the detected project root
- `M-x odineval-toggle-test-after-build`: optionally test after successful package builds
- `M-x odineval-toggle-show-generated`: also show generated Odin

Default `odin-mode` keys installed by `odineval-setup-odin-mode-keys`:

- `C-c C-e`: run current call, line, or `//` block and show result inline
- `C-c C-p`: run current call, line, or `//` block and open the result buffer
- `C-c C-i`: insert result as a `// => ...` comment below the eval unit
- `C-c C-r`: run region
- `C-c C-c`: eval the whole current line inline, ignoring cursor subexpression
- `C-c C-x`: run uncommented `//` block at point
- `C-c C-k`: check prompted expression
- `C-c C-a`: run ordinary package main via `odin run .`
- `C-c C-b`: build ordinary package via `odin build .`
- `C-c C-v`: check ordinary package via `odin check .`
- `C-c C-t`: test ordinary package via `odin test .`
- `C-c C-s`: toggle generated Odin display
- `C-c C-z`: switch to result buffer

Build/check/test commands only open `*Odin Eval*` on failure. On success they
report in the minibuffer and leave your window layout alone. Test commands are
an exception in one useful way: successful `odin test .` output is compacted and
shown in the minibuffer, because the test runner's summary is the result you
usually want to see.

The package directory defaults to the directory of the current `.odin` file.
That matches Odin's package model for the external-eval MVP. The project
directory is detected by walking up to `ols.json`, `odin.json`, or `.git`,
falling back to the current package directory.

Odin has tests out of the box via `odin test .`. Test procedures use Odin's
test attribute, for example:

```odin
import "core:testing"

@(test)
sample_test :: proc(t: ^testing.T) {
    testing.expect_value(t, 2 + 2, 4)
}
```

For Clojure-style scratch calls, keep ordinary Odin calls commented out and eval
the comment block:

```odin
// add(5, 2)
// some_package_local_proc(1, 2)
```

Place point on either line and run `C-c C-e` for an inline result, `C-c C-p`
for the result buffer, or `C-c C-i` to insert the result below the block as a
comment. With a prefix argument, the block is treated as statements and
`--no-print` is passed to the CLI.

Inserted result comments look like this and are ignored by later block evals:

```odin
// x := 1
// add(x, 3)
// => 4
```

For ordinary Odin code, if point is just after a call expression, that call is
used instead of the whole line:

```odin
fmt.println(add(5, 2)|)
```

`C-c C-e` evaluates `add(5, 2)`, not the full `fmt.println(...)` line.

If point is inside a call just after an atom, that atom is used:

```odin
add(5, 2|)
```

`C-c C-e` evaluates `2`.

Comment-block eval uses internal mode: the package is copied to a scratch
directory, an existing entry `main` is renamed, and the generated eval `main`
runs inside the same package. That means scratch comments can call local names
directly instead of going through `target.`.

## Direction

Two modes matter:

- External eval: generate a separate runner package that imports the target
  package as `target`. This works for exported/package-visible APIs.
- Internal eval: copy or shadow the package into a scratch directory and add a
  temporary runner file in the same package. This should allow calling
  package-local helpers without modifying source files.

External eval is the first milestone. Internal eval is likely the feature that
will make the tool feel closest to Lisp-style interactive development.

## Non-Goals

- Do not interpret Odin.
- Do not invent dynamic state or a hidden runtime.
- Do not require a custom Odin syntax.
- Do not hide compiler errors. Generated Odin should be inspectable.
