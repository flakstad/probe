# probe Agent Notes

This repo explores scratch execution tooling for Odin by generating temporary
Odin code and invoking the real Odin compiler.

## Direction

- Preserve Odin semantics exactly.
- Prefer generated Odin plus `odin run` / `odin check` over interpretation.
- Keep generated code boring and easy to inspect.
- Support external package probing using the import alias `target`.
- Support internal same-package probing for package-local functions.
- Support explicit disk-backed value slots for REPL-like workflows without
  hidden process state.

## Non-Goals

- Do not create a new language or syntax layer.
- Do not build hidden persistent runtime state.
- Do not make stored values implicit; they should be named files under the probe
  store.
- Do not swallow Odin diagnostics.
- Do not edit user source files for probing.

## Implementation

- Odin CLI entry point: `odin run cmd/probe -- ...` or
  `odin build cmd/probe -out:probe`.
- Full tooling loop: `./scripts/test_tooling.sh`.
- Odin tests: `odin test tests -define:ODIN_TEST_LOG_LEVEL=warning`. These
  include compiled CLI integration checks for Odin-owned behavior.
- Use real `odin check` / `odin run` in integration tests when Odin is
  available.
