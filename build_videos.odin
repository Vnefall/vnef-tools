package main

import "core:fmt"
import "core:io"
import "core:strconv"
import "core:strings"
import "core:path/filepath"
import os2 "core:os/os2"

MAGIC :: "VID0"
VERSION :: u32(1)

VIDEO_EXTS :: []string{
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".webm",
    ".m4v",
    ".mpg",
    ".mpeg",
    ".wmv",
    ".flv",
}

type Options struct {
    recursive: bool,
    keep_webm: bool,
    force: bool,
    audio: bool,
    audio_bitrate: int,
    crf: int,
    deadline: string,
    cpu_used: int,
    ffmpeg: string,
}

print_usage :: proc() {
    fmt.println("Usage:")
    fmt.println("  build_videos <input-file-or-dir> <output-dir> [options]")
    fmt.println("")
    fmt.println("Options:")
    fmt.println("  --recursive          Scan input directory recursively")
    fmt.println("  --keep-webm           Keep intermediate .webm files")
    fmt.println("  --force               Overwrite outputs if they exist")
    fmt.println("  --audio               Keep audio (Opus)")
    fmt.println("  --audio-bitrate <k>   Opus bitrate in kbps (default 128)")
    fmt.println("  --crf <n>             VP9 quality (default 30)")
    fmt.println("  --deadline <mode>     realtime|good|best (default good)")
    fmt.println("  --cpu-used <n>        VP9 speed/quality tradeoff (default 4)")
    fmt.println("  --ffmpeg <path>       Path to ffmpeg binary")
}

is_video_ext :: proc(ext: string) -> bool {
    for e in VIDEO_EXTS {
        if ext == e {
            return true
        }
    }
    return false
}

iter_inputs :: proc(src: string, recursive: bool) -> []string {
    inputs: [dynamic]string

    if os2.is_file(src) {
        append(&inputs, strings.clone(src))
        return inputs
    }
    if !os2.is_dir(src) {
        fmt.eprintln("Input path not found:", src)
        return inputs
    }

    if recursive {
        walk_proc := proc(info: os2.File_Info, in_err: os2.Error, user_data: rawptr) -> (err: os2.Error, skip_dir: bool) {
            if in_err != nil {
                return in_err, false
            }
            if info.type == .Directory {
                return nil, false
            }
            ext := strings.to_lower(filepath.ext(info.fullpath))
            defer delete(ext)
            if is_video_ext(ext) {
                append(&inputs, strings.clone(info.fullpath))
            }
            return nil, false
        }

        _ = filepath.walk(src, walk_proc, nil)
        return inputs
    }

    fis, err := os2.read_dir(src, context.temp_allocator)
    if err != nil {
        fmt.eprintln("Failed to read dir:", src)
        return inputs
    }
    defer os2.file_info_slice_delete(fis, context.temp_allocator)

    for fi in fis {
        if fi.type != .Regular {
            continue
        }
        ext := strings.to_lower(filepath.ext(fi.fullpath))
        defer delete(ext)
        if is_video_ext(ext) {
            append(&inputs, strings.clone(fi.fullpath))
        }
    }

    return inputs
}

resolve_ffmpeg :: proc(ffmpeg_arg: string) -> (path: string, lib_dir: string) {
    if ffmpeg_arg != "" {
        // If user supplies an explicit ffmpeg path, try sibling ../lib
        lib_guess := filepath.join(filepath.dir(ffmpeg_arg), "..", "lib")
        if os2.is_dir(lib_guess) {
            return ffmpeg_arg, lib_guess
        }
        return ffmpeg_arg, ""
    }

    tool_root := os2.get_current_directory(context.temp_allocator)
    bundled := filepath.join(tool_root, "third_party", "ffmpeg", "bin", "ffmpeg")
    when ODIN_OS == .Windows {
        bundled = bundled + ".exe"
    }
    if os2.is_file(bundled) {
        lib_dir := filepath.join(tool_root, "third_party", "ffmpeg", "lib")
        if os2.is_dir(lib_dir) {
            return bundled, lib_dir
        }
        return bundled, ""
    }

    // Find ffmpeg in PATH
    path_env := os2.get_env("PATH", context.temp_allocator)
    defer delete(path_env)
    sep := ":"
    when ODIN_OS == .Windows {
        sep = ";"
    }

    parts := strings.split(path_env, sep)
    defer delete(parts)
    for p in parts {
        candidate := filepath.join(p, "ffmpeg")
        when ODIN_OS == .Windows {
            candidate = candidate + ".exe"
        }
        if os2.is_file(candidate) {
            return candidate, ""
        }
    }

    return "", ""
}

set_ffmpeg_lib_env :: proc(lib_dir: string) {
    if lib_dir == "" do return
    key := "LD_LIBRARY_PATH"
    sep := ":"
    when ODIN_OS == .Windows {
        key = "PATH"
        sep = ";"
    }
    when ODIN_OS == .Darwin {
        key = "DYLD_LIBRARY_PATH"
        sep = ":"
    }

    existing := os2.get_env(key, context.temp_allocator)
    defer delete(existing)
    new_val := ""
    if existing != "" {
        new_val = strings.concatenate({lib_dir, sep, existing})
    } else {
        new_val = strings.clone(lib_dir)
    }
    _ = os2.set_env(key, new_val)
    delete(new_val)
}

run_ffmpeg :: proc(src, dst_webm: string, opts: Options, ffmpeg_path: string, lib_dir: string) -> bool {
    set_ffmpeg_lib_env(lib_dir)

    cmd: [dynamic]string
    append(&cmd, ffmpeg_path)
    if opts.force {
        append(&cmd, "-y")
    } else {
        append(&cmd, "-n")
    }
    append(&cmd, "-i")
    append(&cmd, src)
    append(&cmd, "-c:v")
    append(&cmd, "libvpx-vp9")
    append(&cmd, "-b:v")
    append(&cmd, "0")
    append(&cmd, "-crf")
    append(&cmd, strconv.itoa(opts.crf))
    append(&cmd, "-row-mt")
    append(&cmd, "1")
    append(&cmd, "-deadline")
    append(&cmd, opts.deadline)
    append(&cmd, "-cpu-used")
    append(&cmd, strconv.itoa(opts.cpu_used))

    if opts.audio {
        append(&cmd, "-c:a")
        append(&cmd, "libopus")
        append(&cmd, "-b:a")
        append(&cmd, strconv.itoa(opts.audio_bitrate) + "k")
    } else {
        append(&cmd, "-an")
    }

    append(&cmd, dst_webm)

    desc := os2.Process_Desc{command = cmd}
    state, stdout, stderr, err := os2.process_exec(desc, context.temp_allocator)
    defer delete(stdout)
    defer delete(stderr)
    defer delete(cmd)

    if err != nil || state.exit_code != 0 {
        if len(stdout) > 0 {
            fmt.eprintln(string(stdout))
        }
        if len(stderr) > 0 {
            fmt.eprintln(string(stderr))
        }
        fmt.eprintln("ffmpeg failed for:", src)
        return false
    }

    return true
}

write_u32_le :: proc(buf: []u8, v: u32) {
    buf[0] = u8(v)
    buf[1] = u8(v >> 8)
    buf[2] = u8(v >> 16)
    buf[3] = u8(v >> 24)
}

write_u64_le :: proc(buf: []u8, v: u64) {
    buf[0] = u8(v)
    buf[1] = u8(v >> 8)
    buf[2] = u8(v >> 16)
    buf[3] = u8(v >> 24)
    buf[4] = u8(v >> 32)
    buf[5] = u8(v >> 40)
    buf[6] = u8(v >> 48)
    buf[7] = u8(v >> 56)
}

wrap_webm_to_video :: proc(src_webm, dst_video: string, force: bool) -> bool {
    if os2.is_file(dst_video) && !force {
        fmt.eprintln("Output exists:", dst_video)
        return false
    }

    info, err := os2.stat(src_webm, context.temp_allocator)
    defer os2.file_info_delete(info, context.temp_allocator)
    if err != nil {
        fmt.eprintln("Failed to stat:", src_webm)
        return false
    }

    fin, err := os2.open(src_webm, {.Read})
    if err != nil || fin == nil {
        fmt.eprintln("Failed to open:", src_webm)
        return false
    }
    defer os2.close(fin)

    fout, err := os2.open(dst_video, {.Write, .Create, .Trunc}, os2.Permissions_Default_File)
    if err != nil || fout == nil {
        fmt.eprintln("Failed to open:", dst_video)
        return false
    }
    defer os2.close(fout)

    header: [16]u8
    copy(header[0:4], MAGIC)
    write_u32_le(header[4:8], VERSION)
    write_u64_le(header[8:16], u64(info.size))

    _, err = os2.write(fout, header[:])
    if err != nil {
        fmt.eprintln("Failed to write header:", dst_video)
        return false
    }

    buf: [1024*1024]u8
    for {
        n, rerr := os2.read(fin, buf[:])
        if rerr == io.EOF {
            break
        }
        if rerr != nil {
            fmt.eprintln("Read error:", src_webm)
            return false
        }
        if n == 0 {
            break
        }
        _, werr := os2.write(fout, buf[:n])
        if werr != nil {
            fmt.eprintln("Write error:", dst_video)
            return false
        }
    }

    return true
}

main :: proc() {
    args := os2.args

    opts := Options{
        recursive = false,
        keep_webm = false,
        force = false,
        audio = false,
        audio_bitrate = 128,
        crf = 30,
        deadline = "good",
        cpu_used = 4,
        ffmpeg = "",
    }

    src := ""
    out := ""

    i := 1
    for i < len(args) {
        a := args[i]
        if strings.has_prefix(a, "--") {
            switch a {
            case "--recursive": opts.recursive = true
            case "--keep-webm": opts.keep_webm = true
            case "--force": opts.force = true
            case "--audio": opts.audio = true
            case "--audio-bitrate":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                if v, ok := strconv.parse_int(args[i]); ok { opts.audio_bitrate = v }
            case "--crf":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                if v, ok := strconv.parse_int(args[i]); ok { opts.crf = v }
            case "--deadline":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                opts.deadline = args[i]
            case "--cpu-used":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                if v, ok := strconv.parse_int(args[i]); ok { opts.cpu_used = v }
            case "--ffmpeg":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                opts.ffmpeg = args[i]
            case:
                fmt.eprintln("Unknown option:", a)
                print_usage()
                return
            }
            i += 1
            continue
        }

        if src == "" {
            src = a
        } else if out == "" {
            out = a
        } else {
            fmt.eprintln("Unexpected arg:", a)
            print_usage()
            return
        }
        i += 1
    }

    if src == "" || out == "" {
        print_usage()
        return
    }

    err := os2.make_directory_all(out)
    if err != nil {
        fmt.eprintln("Failed to create output dir:", out)
        return
    }

    ffmpeg_path, lib_dir := resolve_ffmpeg(opts.ffmpeg)
    if ffmpeg_path == "" {
        fmt.eprintln("ffmpeg not found (use --ffmpeg or bundle in third_party/ffmpeg)")
        return
    }
    if lib_dir != "" {
        fmt.println("Using ffmpeg libs:", lib_dir)
    }
    fmt.println("Using ffmpeg:", ffmpeg_path)

    inputs := iter_inputs(src, opts.recursive)
    if len(inputs) == 0 {
        fmt.eprintln("No input videos found.")
        return
    }

    for input in inputs {
        stem := filepath.stem(input)
        webm_path := filepath.join(out, stem + ".webm")
        video_path := filepath.join(out, stem + ".video")

        if !run_ffmpeg(input, webm_path, opts, ffmpeg_path, lib_dir) {
            return
        }
        if !wrap_webm_to_video(webm_path, video_path, opts.force) {
            return
        }
        if !opts.keep_webm {
            _ = os2.remove(webm_path)
        }
        fmt.println("Built", video_path)
    }
}
