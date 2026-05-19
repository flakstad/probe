# probe

`probe` is scratch execution tooling for Odin. It makes small experiments cheap
without changing Odin itself.

Odin is compiled and statically checked, so this is not a REPL or interpreter.
The goal is to make common exploratory actions cheap:

- run one proc without editing `main`
- run a small package-context expression
- generate a temporary runner package
- compile/run with the real Odin compiler
- show the generated Odin when debugging
- persist explicit text values between probes

The core rule: Odin remains the source of truth. `probe` generates ordinary
Odin and invokes `odin run` or `odin check`.

## Current Commands

Build the compiled CLI with:

```sh
odin build cmd/probe -out:probe
```

External package probing:

```sh
./probe run /path/to/package 'target.some_proc()'
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
./probe run /path/to/package 'target.do_work()' --no-print
```

To inspect generated Odin:

```sh
./probe run /path/to/package 'target.some_proc()' --show
```

The compiled Odin CLI also supports writing generated source to a file while
keeping stdout as just the probe result:

```sh
./probe run /path/to/package 'target.some_proc()' --generated /tmp/probe-runner.odin
```

To check without running:

```sh
./probe check /path/to/package 'target.some_proc()'
```

To save successful stdout into an explicit package-local value slot:

```sh
./probe run /path/to/package 'target.some_proc()' --save last-result
./probe store load /path/to/package last-result
```

Value slots are plain text files under `/path/to/package/.probe/values/` by
default. Set `PROBE_STORE_DIR` to use a different store location.

Store commands:

```sh
./probe store path /path/to/package
./probe store save /path/to/package answer '42'
./probe store load /path/to/package answer
./probe store list /path/to/package
./probe store rm /path/to/package answer
```

Standard Odin package commands:

```sh
./probe package-run /path/to/package
./probe package-build /path/to/package
./probe package-check /path/to/package
./probe package-test /path/to/package
```

## Tests

The feedback loop now puts the compiled Odin CLI first:

```sh
./scripts/test_tooling.sh
```

That script runs the full local loop:

```sh
odin check cmd/probe
odin test tests -define:ODIN_TEST_LOG_LEVEL=warning
emacs -Q --batch -f batch-byte-compile emacs/probe.el
```

`odin test tests` covers the core renderer/helpers and builds/runs the compiled
CLI for Odin-owned behavior: external probing, internal probing, scratch-line
commenting, package commands, generated-file output, and value storage.
The script also builds a temporary compiled CLI and runs five probes in parallel
to catch output-binary collisions.

## Emacs

The repo includes a small Emacs integration at `emacs/probe.el`. It requires the
compiled Odin `probe` CLI and displays command output in `*Probe*`.

Minimal setup:

```elisp
(add-to-list 'load-path "/Users/andreas/Projects/probe/emacs")
(require 'probe)

;; If you use odin-mode:
(add-hook 'odin-mode-hook #'probe-setup-odin-mode-keys)
```

Build `./probe` first.

Default commands:

- `M-x probe-run-expression`: prompt for an Odin expression and print result
- `M-x probe-run-expression-save`: run an expression and save stdout to a value slot
- `M-x probe-run-line`: run current line, or whole `/* ... */` block at point
- `M-x probe-run-region`: run selected expression; with prefix, run as statements
- `M-x probe-check-expression`: compile-check a generated runner
- `M-x probe-run-comment-block`: run a contiguous `/* ... */` comment block as code
- `M-x probe-run-proc`: call `target.<proc>(<args>)`
- `M-x probe-run-proc-no-args`: call `target.<symbol-at-point>()`
- `M-x probe-store-save`: write a named plain-text value
- `M-x probe-store-load`: print a named value in `*Probe*`
- `M-x probe-store-list`: list value slots
- `M-x probe-store-remove`: remove a value slot
- `M-x probe-store-path`: show the active store directory
- `M-x probe-run-package`: run ordinary `odin run .` in the current package
- `M-x probe-build-package`: run ordinary `odin build .` in the current package
- `M-x probe-check-package`: run ordinary `odin check .` in the current package
- `M-x probe-test-package`: run ordinary `odin test .` in the current package
- `M-x probe-run-project`: run ordinary `odin run .` at the detected project root
- `M-x probe-build-project`: run ordinary `odin build .` at the detected project root
- `M-x probe-check-project`: run ordinary `odin check .` at the detected project root
- `M-x probe-test-project`: run ordinary `odin test .` at the detected project root
- `M-x probe-toggle-test-after-build`: optionally test after successful package builds
- `M-x probe-toggle-show-generated`: also show generated Odin

Default `odin-mode` keys installed by `probe-setup-odin-mode-keys`:

- `C-c C-e`: run current call, line, or `/* ... */` block and show result inline
- `C-c C-p`: run current call, line, or `/* ... */` block and open the result buffer
- `C-c C-i`: insert result as a `// => ...` comment below the probed unit
- `C-c C-r`: run region
- `C-c C-c`: run the whole current line inline, ignoring cursor subexpression
- `C-c C-x`: run uncommented `/* ... */` block at point
- `C-c C-k`: check prompted expression
- `C-c C-a`: run ordinary package main via `odin run .`
- `C-c C-b`: build ordinary package via `odin build .`
- `C-c C-v`: check ordinary package via `odin check .`
- `C-c C-t`: test ordinary package via `odin test .`
- `C-c C-s`: toggle generated Odin display
- `C-c C-z`: switch to result buffer

Build/check/test commands only open `*Probe*` on failure. On success they
report in the minibuffer and leave your window layout alone. Test commands are
an exception in one useful way: successful `odin test .` output is compacted and
shown in the minibuffer, because the test runner's summary is the result you
usually want to see. The default Emacs test command is:

```sh
odin test . -define:ODIN_TEST_LOG_LEVEL=warning
```

That suppresses Odin's verbose successful test-runner info logs while preserving
warnings, errors, and the final summary. Customize `probe-test-command` if
you want different test runner flags.

The package directory defaults to the directory of the current `.odin` file.
That matches Odin's package model for the external probing MVP. The project
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

For Clojure-style scratch calls, keep ordinary Odin calls inside a multiline
comment block and run that block:

```odin
/*
add(5, 2)
some_package_local_proc(1, 2)
*/
```

Place point inside the block and run `C-c C-e` for an inline result, `C-c C-p`
for the result buffer, or `C-c C-i` to insert the result below the block as a
comment. With a prefix argument, the block is treated as statements and
`--no-print` is passed to the CLI.

Inserted result comments look like this and are ignored by later block probes:

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

`C-c C-e` runs `add(5, 2)`, not the full `fmt.println(...)` line.

If point is inside a call just after an atom, that atom is used:

```odin
add(5, 2|)
```

`C-c C-e` runs `2`.

Block-comment probing uses internal mode: the package is copied to a scratch
directory, an existing entry `main` is renamed, and the generated probe `main`
runs inside the same package. That means scratch comments can call local names
directly instead of going through `target.`.

## Direction

Two modes matter:

- External probing: generate a separate runner package that imports the target
  package as `target`. This works for exported/package-visible APIs.
- Internal probing: copy or shadow the package into a scratch directory and add a
  temporary runner file in the same package. This allows calling package-local
  helpers without modifying source files.
- Explicit store: write and read named plain-text values on disk. This supports
  REPL-like workflows where a result can be reused later without pretending that
  Odin has a persistent interactive heap.

External probing is useful for exported/package-visible APIs. Internal probing is
the workflow that makes scratch comments useful while keeping ordinary Odin
source as the source of truth.

## Future Considerations

The current tool is good enough to use while learning Odin. Prefer using it for
a while before adding more surface area; real friction should drive the next
features.

Likely useful adjacent work:

- Test at point: detect the surrounding `@(test)` procedure and run only that
  test via `-define:ODIN_TEST_NAMES=package.test_name`.
- Multi-package project commands: discover package directories and run
  `odin check` or `odin test` across them, instead of assuming the project root
  itself is a buildable package.
- Failure navigation: parse Odin compiler output into Emacs compilation-mode or
  xref-friendly locations so `next-error` jumps directly to failures.
- Result cleanup: remove generated `// =>` result comments from a buffer or
  selected region.
- Documentation-at-point: keep this in the Odin/OLS Emacs setup rather than
  probe. Bind commands such as `eglot-help-at-point` or `eldoc-doc-buffer`
  for hover/docs buffers.
- Learning examples: keep a small Odin scratch/example project covering
  arrays, slices, maps, allocators, errors, tests, `defer`, structs, enums, and
  procedure groups.

The main Odin learning axis is allocation and ownership. Probing is useful for
quick feedback, but returned maps, slices, strings, and allocator-backed helpers
still need explicit lifetime thinking.

## Non-Goals

- Do not interpret Odin.
- Do not invent dynamic state or a hidden runtime.
- Do not make stored values implicit. Disk-backed state should be visible and
  named by the user.
- Do not require a custom Odin syntax.
- Do not hide compiler errors. Generated Odin should be inspectable.
