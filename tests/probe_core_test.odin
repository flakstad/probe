package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import probe "../src/probe_core"

Exec_Result :: struct {
    exit_code: int,
    stdout:    string,
    stderr:    string,
}

exec :: proc(command: []string, working_dir := "") -> Exec_Result {
    state, stdout, stderr, err := os.process_exec(
        os.Process_Desc{command = command, working_dir = working_dir},
        context.allocator,
    )
    exit_code := 1
    if err == nil && state.exited {
        exit_code = state.exit_code
    }
    return Exec_Result{exit_code = exit_code, stdout = string(stdout), stderr = string(stderr)}
}

delete_exec_result :: proc(result: Exec_Result) {
    delete(transmute([]byte)result.stdout)
    delete(transmute([]byte)result.stderr)
}

write_sample_package :: proc(t: ^testing.T, root: string) -> (pkg: string, ok: bool) {
    package_path, join_err := os.join_path({root, "sample"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err != nil {
        return "", false
    }
    if os.make_directory_all(package_path) != nil {
        delete(package_path)
        testing.expect_value(t, false, true)
        return "", false
    }

    source_path, source_join_err := os.join_path({package_path, "sample.odin"}, context.allocator)
    testing.expect_value(t, source_join_err == nil, true)
    if source_join_err != nil {
        delete(package_path)
        return "", false
    }
    defer delete(source_path)

    source := `package sample

import "core:fmt"

add :: proc(a: int, b: int) -> int {
    return a + b
}

answer :: proc() -> int {
    return 42
}

say :: proc() {
    fmt.println("said")
}
`
    testing.expect_value(t, os.write_entire_file_from_string(source_path, source) == nil, true)
    return package_path, true
}

write_main_package :: proc(t: ^testing.T, root: string) -> (pkg: string, ok: bool) {
    package_path, join_err := os.join_path({root, "app"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err != nil {
        return "", false
    }
    if os.make_directory_all(package_path) != nil {
        delete(package_path)
        testing.expect_value(t, false, true)
        return "", false
    }

    source_path, source_join_err := os.join_path({package_path, "app.odin"}, context.allocator)
    testing.expect_value(t, source_join_err == nil, true)
    if source_join_err != nil {
        delete(package_path)
        return "", false
    }
    defer delete(source_path)

    source := `package main

import "core:fmt"

add :: proc(a: int, b: int) -> int {
    return a + b
}

main :: proc() {
    fmt.println(add(1, 2))
}
`
    testing.expect_value(t, os.write_entire_file_from_string(source_path, source) == nil, true)
    return package_path, true
}

write_scratch_main_package :: proc(t: ^testing.T, root: string) -> (pkg: string, ok: bool) {
    package_path, join_err := os.join_path({root, "scratch_app"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err != nil {
        return "", false
    }
    if os.make_directory_all(package_path) != nil {
        delete(package_path)
        testing.expect_value(t, false, true)
        return "", false
    }

    source_path, source_join_err := os.join_path({package_path, "app.odin"}, context.allocator)
    testing.expect_value(t, source_join_err == nil, true)
    if source_join_err != nil {
        delete(package_path)
        return "", false
    }
    defer delete(source_path)

    source := `package main

import "core:fmt"

add :: proc(a: int, b: int) -> int {
    return a + b
}

/* add(5, 2) */
add(5, 3)

main :: proc() {
    fmt.println(add(1, 2))
}
`
    testing.expect_value(t, os.write_entire_file_from_string(source_path, source) == nil, true)
    return package_path, true
}

write_test_package :: proc(t: ^testing.T, root: string) -> (pkg: string, ok: bool) {
    package_path, join_err := os.join_path({root, "testpkg"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err != nil {
        return "", false
    }
    if os.make_directory_all(package_path) != nil {
        delete(package_path)
        testing.expect_value(t, false, true)
        return "", false
    }

    source_path, source_join_err := os.join_path({package_path, "testpkg.odin"}, context.allocator)
    testing.expect_value(t, source_join_err == nil, true)
    if source_join_err != nil {
        delete(package_path)
        return "", false
    }
    defer delete(source_path)

    source := `package testpkg

import "core:testing"

@(test)
sample_test :: proc(t: ^testing.T) {
    testing.expect_value(t, 2 + 2, 4)
}
`
    testing.expect_value(t, os.write_entire_file_from_string(source_path, source) == nil, true)
    return package_path, true
}

build_probe_binary :: proc(t: ^testing.T, root: string) -> (binary: string, ok: bool) {
    binary_path, join_err := os.join_path({root, "probe"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err != nil {
        return "", false
    }

    out_arg := strings.clone(fmt.tprintf("-out:%s", binary_path))
    defer delete(out_arg)

    result := exec([]string{"odin", "build", "cmd/probe", out_arg})
    defer delete_exec_result(result)
    testing.expect_value(t, result.exit_code, 0)
    if result.exit_code != 0 {
        delete(binary_path)
        return "", false
    }
    return binary_path, true
}

@(test)
render_printing_runner :: proc(t: ^testing.T) {
    output := probe.render_runner(probe.Config{
        package_path = "/tmp/pkg",
        code = "target.answer()",
        print_result = true,
        import_path = "../pkg",
    })
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "import \"core:fmt\""), true)
    testing.expect_value(t, strings.contains(output, "import target \"../pkg\""), true)
    testing.expect_value(t, strings.contains(output, "result := target.answer()"), true)
    testing.expect_value(t, strings.contains(output, "fmt.println(result)"), true)
}

@(test)
render_internal_multiline_probe :: proc(t: ^testing.T) {
    output := probe.render_internal_runner(probe.Config{
        package_path = "/tmp/pkg",
        code = "x := 1\nadd(x, 3)",
        print_result = true,
        package_name = "main",
    })
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "package main"), true)
    testing.expect_value(t, strings.contains(output, "    x := 1"), true)
    testing.expect_value(t, strings.contains(output, "    result := add(x, 3)"), true)
    testing.expect_value(t, strings.contains(output, "result := x := 1"), false)
}

@(test)
comment_top_level_scratch_lines :: proc(t: ^testing.T) {
    source := `package main

add :: proc(a: int, b: int) -> int {
    return a + b
}

add(5,3)
`
    output := probe.comment_top_level_scratch_lines(source)
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "add :: proc"), true)
    testing.expect_value(t, strings.contains(output, "/* probe scratch: add(5,3) */"), true)
}

@(test)
render_no_print_runner :: proc(t: ^testing.T) {
    output := probe.render_runner(probe.Config{
        package_path = "/tmp/pkg",
        code = "target.run()",
        print_result = false,
        import_path = "../pkg",
    })
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "    target.run()"), true)
    testing.expect_value(t, strings.contains(output, "fmt.println(result)"), false)
}

@(test)
comment_top_level_scratch_lines_preserves_block_comment :: proc(t: ^testing.T) {
    source := `package main

add :: proc(a: int, b: int) -> int {
    return a + b
}

/*
add(5,3)
*/

another :: proc(a: int) -> int {
    return a * 2
}
`
    output := probe.comment_top_level_scratch_lines(source)
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "/*\nadd(5,3)\n*/"), true)
    testing.expect_value(t, strings.contains(output, "probe scratch: add(5,3)"), false)
}

@(test)
store_values_round_trip :: proc(t: ^testing.T) {
    package_dir, dir_err := os.make_directory_temp("", "probe-store-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(package_dir)
        delete(package_dir)
    }

    testing.expect_value(t, probe.save_value(package_dir, "answer", "42\n"), true)

    value, ok := probe.load_value(package_dir, "answer")
    testing.expect_value(t, ok, true)
    if ok {
        defer delete(transmute([]byte)value)
        testing.expect_value(t, value, "42\n")
    }

    names := probe.list_values(package_dir)
    defer probe.delete_string_slice(names)
    testing.expect_value(t, len(names), 1)
    if len(names) == 1 {
        testing.expect_value(t, names[0], "answer")
    }

    testing.expect_value(t, probe.remove_value(package_dir, "answer"), true)
}

@(test)
compiled_cli_external_and_internal_probe :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-basic-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    sample_pkg, sample_ok := write_sample_package(t, root)
    if !sample_ok {
        return
    }
    defer delete(sample_pkg)

    external_result := exec([]string{binary, "run", sample_pkg, "target.add(5, 7)"})
    defer delete_exec_result(external_result)
    testing.expect_value(t, external_result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(external_result.stdout), "12")

    check_result := exec([]string{binary, "check", sample_pkg, "target.answer()"})
    defer delete_exec_result(check_result)
    testing.expect_value(t, check_result.exit_code, 0)

    no_print_result := exec([]string{binary, "run", sample_pkg, "target.say()", "--no-print"})
    defer delete_exec_result(no_print_result)
    testing.expect_value(t, no_print_result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(no_print_result.stdout), "said")

    cwd_result := exec([]string{
        binary,
        "run",
        sample_pkg,
        `_ = os.write_entire_file_from_string("probe-cwd.txt", "ok")`,
        "--no-print",
        "--import",
        `import "core:os"`,
    })
    defer delete_exec_result(cwd_result)
    testing.expect_value(t, cwd_result.exit_code, 0)

    cwd_file, cwd_join_err := os.join_path({sample_pkg, "probe-cwd.txt"}, context.allocator)
    testing.expect_value(t, cwd_join_err == nil, true)
    if cwd_join_err == nil {
        defer delete(cwd_file)
        cwd_data, cwd_read_err := os.read_entire_file_from_path(cwd_file, context.allocator)
        testing.expect_value(t, cwd_read_err == nil, true)
        if cwd_read_err == nil {
            defer delete(cwd_data)
            testing.expect_value(t, string(cwd_data), "ok")
        }
    }

    main_pkg, main_ok := write_main_package(t, root)
    if !main_ok {
        return
    }
    defer delete(main_pkg)

    internal_result := exec([]string{binary, "run", main_pkg, "add(5, 2)", "--internal"})
    defer delete_exec_result(internal_result)
    testing.expect_value(t, internal_result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(internal_result.stdout), "7")
}

@(test)
compiled_cli_internal_probe_comments_top_level_scratch :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-scratch-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_scratch_main_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    keep_dir, keep_join_err := os.join_path({root, "kept-internal"}, context.allocator)
    testing.expect_value(t, keep_join_err == nil, true)
    if keep_join_err != nil {
        return
    }
    defer delete(keep_dir)

    result := exec([]string{binary, "run", pkg, "add(5, 2)", "--internal", "--keep-dir", keep_dir})
    defer delete_exec_result(result)
    testing.expect_value(t, result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(result.stdout), "7")

    copied_source_path, copied_join_err := os.join_path({keep_dir, "app.odin"}, context.allocator)
    testing.expect_value(t, copied_join_err == nil, true)
    if copied_join_err != nil {
        return
    }
    defer delete(copied_source_path)

    copied_source, read_err := os.read_entire_file_from_path(copied_source_path, context.allocator)
    testing.expect_value(t, read_err == nil, true)
    if read_err == nil {
        defer delete(copied_source)
        testing.expect_value(t, strings.contains(string(copied_source), "/* probe scratch: add(5, 3) */"), true)
        testing.expect_value(t, strings.contains(string(copied_source), "probe_original_main :: proc()"), true)
    }
}

@(test)
compiled_cli_runs_and_writes_generated_source :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_sample_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    generated_path, generated_join_err := os.join_path({root, "generated.odin"}, context.allocator)
    testing.expect_value(t, generated_join_err == nil, true)
    if generated_join_err != nil {
        return
    }
    defer delete(generated_path)

    result := exec([]string{binary, "run", pkg, "target.answer()", "--generated", generated_path})
    defer delete_exec_result(result)

    testing.expect_value(t, result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(result.stdout), "42")

    generated, read_err := os.read_entire_file_from_path(generated_path, context.allocator)
    testing.expect_value(t, read_err == nil, true)
    if read_err == nil {
        defer delete(generated)
        testing.expect_value(t, strings.contains(string(generated), "import target"), true)
        testing.expect_value(t, strings.contains(string(generated), "result := target.answer()"), true)
    }

    show_result := exec([]string{binary, "run", pkg, "target.answer()", "--show"})
    defer delete_exec_result(show_result)
    testing.expect_value(t, show_result.exit_code, 0)
    testing.expect_value(t, strings.contains(show_result.stdout, "import target"), true)
    testing.expect_value(t, strings.has_suffix(strings.trim_space(show_result.stdout), "42"), true)
}

@(test)
compiled_cli_relative_keep_dir_runs_from_package_cwd :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-keep-dir-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_sample_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    keep_dir := "relative-probe-runner"
    result := exec([]string{binary, "run", pkg, "target.answer()", "--keep-dir", keep_dir}, root)
    defer delete_exec_result(result)
    testing.expect_value(t, result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(result.stdout), "42")

    kept_runner, join_err := os.join_path({root, keep_dir, "main.odin"}, context.allocator)
    testing.expect_value(t, join_err == nil, true)
    if join_err == nil {
        defer delete(kept_runner)
        testing.expect_value(t, os.exists(kept_runner), true)
    }
}

@(test)
compiled_cli_package_test :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-package-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_test_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    result := exec([]string{binary, "package-test", pkg, "-define:ODIN_TEST_LOG_LEVEL=warning"})
    defer delete_exec_result(result)
    testing.expect_value(t, result.exit_code, 0)
}

@(test)
compiled_cli_package_run_invokes_standard_main :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-package-run-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_main_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    result := exec([]string{binary, "package-run", pkg})
    defer delete_exec_result(result)
    testing.expect_value(t, result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(result.stdout), "3")
}

@(test)
compiled_cli_store_commands_round_trip :: proc(t: ^testing.T) {
    root, dir_err := os.make_directory_temp("", "probe-cli-store-test-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer {
        _ = os.remove_all(root)
        delete(root)
    }

    binary, binary_ok := build_probe_binary(t, root)
    if !binary_ok {
        return
    }
    defer delete(binary)

    pkg, pkg_ok := write_sample_package(t, root)
    if !pkg_ok {
        return
    }
    defer delete(pkg)

    run_result := exec([]string{binary, "run", pkg, "target.add(20, 22)", "--save", "answer"})
    defer delete_exec_result(run_result)
    testing.expect_value(t, run_result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(run_result.stdout), "42")

    load_result := exec([]string{binary, "store", "load", pkg, "answer"})
    defer delete_exec_result(load_result)
    testing.expect_value(t, load_result.exit_code, 0)
    testing.expect_value(t, load_result.stdout, "42\n")

    list_result := exec([]string{binary, "store", "list", pkg})
    defer delete_exec_result(list_result)
    testing.expect_value(t, list_result.exit_code, 0)
    testing.expect_value(t, strings.trim_space(list_result.stdout), "answer")

    rm_result := exec([]string{binary, "store", "rm", pkg, "answer"})
    defer delete_exec_result(rm_result)
    testing.expect_value(t, rm_result.exit_code, 0)
}
