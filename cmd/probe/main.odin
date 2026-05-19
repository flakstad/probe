package main

import "core:fmt"
import "core:os"
import probe "../../src/probe_core"

usage :: proc() {
    fmt.println("usage:")
    fmt.println("  probe run <package> <code> [--no-print] [--show] [--generated file] [--internal] [--keep-dir dir] [--import line]")
    fmt.println("  probe check <package> <code> [--no-print] [--show] [--generated file] [--internal] [--keep-dir dir] [--import line]")
    fmt.println("  probe store path <package>")
    fmt.println("  probe store save <package> <name> <value>")
    fmt.println("  probe store load <package> <name>")
    fmt.println("  probe store list <package>")
    fmt.println("  probe store rm <package> <name>")
    fmt.println("  probe package-run <package> [odin args...]")
    fmt.println("  probe package-build <package> [odin args...]")
    fmt.println("  probe package-check <package> [odin args...]")
    fmt.println("  probe package-test <package> [odin args...]")
}

print_result :: proc(result: probe.Run_Result) {
    if len(result.stdout) > 0 {
        fmt.print(result.stdout)
    }
    if len(result.stderr) > 0 {
        fmt.eprint(result.stderr)
    }
}

parse_probe_command :: proc(action: string) -> int {
    if len(os.args) < 4 {
        usage()
        return 2
    }

    target_package := os.args[2]
    code := os.args[3]
    no_print := false
    show := false
    internal := false
    keep_dir := ""
    generated_path := ""
    save_name := ""
    imports := make([dynamic]string)
    defer delete(imports)

    i := 4
    for i < len(os.args) {
        switch os.args[i] {
        case "--no-print":
            no_print = true
            i += 1
        case "--show":
            show = true
            i += 1
        case "--internal":
            internal = true
            i += 1
        case "--keep-dir":
            if i+1 >= len(os.args) {
                usage()
                return 2
            }
            keep_dir = os.args[i+1]
            i += 2
        case "--generated":
            if i+1 >= len(os.args) {
                usage()
                return 2
            }
            generated_path = os.args[i+1]
            i += 2
        case "--save":
            if i+1 >= len(os.args) {
                usage()
                return 2
            }
            save_name = os.args[i+1]
            i += 2
        case "--import":
            if i+1 >= len(os.args) {
                usage()
                return 2
            }
            append(&imports, os.args[i+1])
            i += 2
        case:
            usage()
            return 2
        }
    }

    if !os.exists(target_package) {
        fmt.eprintln("package path does not exist: ", target_package)
        return 2
    }

    runner_dir := keep_dir
    temp_dir := ""
    if keep_dir != "" {
        if os.is_absolute_path(keep_dir) {
            runner_dir = keep_dir
        } else {
            cwd, cwd_err := os.get_working_directory(context.allocator)
            if cwd_err != nil {
                fmt.eprintln("failed to resolve current directory")
                return 2
            }
            defer delete(cwd)

            abs_runner_dir, join_err := os.join_path({cwd, keep_dir}, context.allocator)
            if join_err != nil {
                fmt.eprintln("failed to resolve keep directory: ", keep_dir)
                return 2
            }
            runner_dir = abs_runner_dir
        }
    } else {
        dir, dir_err := os.make_directory_temp("", "probe-*", context.allocator)
        if dir_err != nil {
            fmt.eprintln("failed to create temporary directory")
            return 1
        }
        runner_dir = dir
        temp_dir = dir
    }
    defer if keep_dir != "" && runner_dir != "" && runner_dir != keep_dir {
        delete(runner_dir)
    }
    defer if temp_dir != "" {
        _ = os.remove_all(temp_dir)
        delete(temp_dir)
    }

    config := probe.Config{
        package_path = target_package,
        code         = code,
        print_result = !no_print,
        extra_imports = imports[:],
    }

    runner := ""
    ok := false
    if internal {
        runner, ok = probe.write_internal_runner(config, runner_dir)
    } else {
        runner, ok = probe.write_runner(config, runner_dir)
    }
    if !ok {
        fmt.eprintln("failed to generate probe runner")
        return 2
    }
    defer delete(runner)

    if show || generated_path != "" {
        data, read_err := os.read_entire_file_from_path(runner, context.allocator)
        if read_err != nil {
            fmt.eprintln("failed to read generated Odin: ", runner)
            return 1
        }
        if generated_path != "" {
            if os.write_entire_file(generated_path, data) != nil {
                fmt.eprintln("failed to write generated Odin: ", generated_path)
                delete(data)
                return 1
            }
        }
        if show {
            fmt.print(string(data))
        }
        delete(data)
    }

    result := probe.run_odin(action, runner_dir, target_package)
    defer delete(transmute([]byte)result.stdout)
    defer delete(transmute([]byte)result.stderr)
    if save_name != "" && result.exit_code == 0 {
        if !probe.valid_store_name(save_name) {
            fmt.eprintln("store name must contain only letters, digits, '_', '.', or '-'")
            return 2
        }
        if !probe.save_value(target_package, save_name, result.stdout) {
            fmt.eprintln("failed to save stored value")
            return 1
        }
    }
    print_result(result)
    return result.exit_code
}

parse_package_command :: proc(action: string) -> int {
    if len(os.args) < 3 {
        usage()
        return 2
    }
    target_package := os.args[2]
    if !os.exists(target_package) {
        fmt.eprintln("package path does not exist: ", target_package)
        return 2
    }
    extra_args := os.args[3:]
    result := probe.run_odin_package(action, target_package, extra_args)
    defer delete(transmute([]byte)result.stdout)
    defer delete(transmute([]byte)result.stderr)
    print_result(result)
    return result.exit_code
}

parse_store_command :: proc() -> int {
    if len(os.args) < 4 {
        usage()
        return 2
    }

    action := os.args[2]
    target_package := os.args[3]
    if !os.exists(target_package) {
        fmt.eprintln("package path does not exist: ", target_package)
        return 2
    }

    switch action {
    case "path":
        if len(os.args) != 4 {
            usage()
            return 2
        }
        directory, ok := probe.store_dir(target_package)
        if !ok {
            fmt.eprintln("failed to resolve store path")
            return 1
        }
        defer delete(directory)
        fmt.println(directory)
        return 0
    case "save":
        if len(os.args) != 6 {
            usage()
            return 2
        }
        name := os.args[4]
        value := os.args[5]
        if !probe.valid_store_name(name) {
            fmt.eprintln("store name must contain only letters, digits, '_', '.', or '-'")
            return 2
        }
        if !probe.save_value(target_package, name, value) {
            fmt.eprintln("failed to save stored value")
            return 1
        }
        return 0
    case "load":
        if len(os.args) != 5 {
            usage()
            return 2
        }
        name := os.args[4]
        if !probe.valid_store_name(name) {
            fmt.eprintln("store name must contain only letters, digits, '_', '.', or '-'")
            return 2
        }
        value, ok := probe.load_value(target_package, name)
        if !ok {
            fmt.eprintln("stored value not found: ", name)
            return 1
        }
        defer delete(transmute([]byte)value)
        fmt.print(value)
        return 0
    case "list":
        if len(os.args) != 4 {
            usage()
            return 2
        }
        names := probe.list_values(target_package)
        defer probe.delete_string_slice(names)
        for name in names {
            fmt.println(name)
        }
        return 0
    case "rm":
        if len(os.args) != 5 {
            usage()
            return 2
        }
        name := os.args[4]
        if !probe.valid_store_name(name) {
            fmt.eprintln("store name must contain only letters, digits, '_', '.', or '-'")
            return 2
        }
        if !probe.remove_value(target_package, name) {
            fmt.eprintln("stored value not found: ", name)
            return 1
        }
        return 0
    case:
        usage()
        return 2
    }
}

main :: proc() {
    if len(os.args) < 2 {
        usage()
        os.exit(2)
    }

    switch os.args[1] {
    case "run":
        os.exit(parse_probe_command("run"))
    case "check":
        os.exit(parse_probe_command("check"))
    case "store":
        os.exit(parse_store_command())
    case "package-run":
        os.exit(parse_package_command("run"))
    case "package-build":
        os.exit(parse_package_command("build"))
    case "package-check":
        os.exit(parse_package_command("check"))
    case "package-test":
        os.exit(parse_package_command("test"))
    case "-h", "--help", "help":
        usage()
    case:
        usage()
        os.exit(2)
    }
}
