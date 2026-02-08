package main

import "core:fmt"
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

Options :: struct {
    recursive: bool,
    keep_webm: bool,
    force: bool,
    audio: bool,
    audio_bitrate: int,
    audio_out: string,
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
    fmt.println("  --audio               Extract audio to .ogg (Opus)")
    fmt.println("  --audio-out <dir>      Output directory for extracted audio (.ogg)")
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

@(private)
collect_dir :: proc(path: string, recursive: bool, inputs: ^[dynamic]string) {
    fis, err := os2.read_all_directory_by_path(path, context.temp_allocator)
    if err != nil {
        fmt.eprintln("Failed to read dir:", path)
        return
    }
    defer os2.file_info_slice_delete(fis, context.temp_allocator)

    for fi in fis {
        if fi.type == .Directory {
            if recursive {
                collect_dir(fi.fullpath, recursive, inputs)
            }
            continue
        }
        if fi.type != .Regular {
            continue
        }
        ext := strings.to_lower(filepath.ext(fi.fullpath))
        if is_video_ext(ext) {
            append(inputs, strings.clone(fi.fullpath))
        }
        delete(ext)
    }
}

iter_inputs :: proc(src: string, recursive: bool) -> []string {
    inputs: [dynamic]string

    if os2.is_file(src) {
        append(&inputs, strings.clone(src))
        return inputs[:]
    }
    if !os2.is_dir(src) {
        fmt.eprintln("Input path not found:", src)
        return inputs[:]
    }

    collect_dir(src, recursive, &inputs)
    return inputs[:]
}

resolve_ffmpeg :: proc(ffmpeg_arg: string) -> (path: string, lib_dir: string) {
    if ffmpeg_arg != "" {
        // If user supplies an explicit ffmpeg path, try sibling ../lib
        lib_guess, _ := filepath.join([]string{filepath.dir(ffmpeg_arg), "..", "lib"})
        if os2.is_dir(lib_guess) {
            return ffmpeg_arg, lib_guess
        }
        return ffmpeg_arg, ""
    }

    tool_root, err := os2.get_working_directory(context.temp_allocator)
    if err == nil {
        defer delete(tool_root)
    } else {
        tool_root = "."
    }
    bundled, _ := filepath.join([]string{tool_root, "third_party", "ffmpeg", "bin", "ffmpeg"})
    when ODIN_OS == .Windows {
        bundled = strings.concatenate({bundled, ".exe"})
    }
    if os2.is_file(bundled) {
        lib_dir, _ := filepath.join([]string{tool_root, "third_party", "ffmpeg", "lib"})
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
        candidate, _ := filepath.join([]string{p, "ffmpeg"})
        when ODIN_OS == .Windows {
            candidate = strings.concatenate({candidate, ".exe"})
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
    append(&cmd, "-hide_banner")
    append(&cmd, "-loglevel")
    append(&cmd, "error")
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
    crf_str := int_to_string(opts.crf)
    append(&cmd, crf_str)
    append(&cmd, "-row-mt")
    append(&cmd, "1")
    append(&cmd, "-deadline")
    append(&cmd, opts.deadline)
    append(&cmd, "-cpu-used")
    cpu_str := int_to_string(opts.cpu_used)
    append(&cmd, cpu_str)

    // Always keep the .video output silent. Audio is extracted separately.
    append(&cmd, "-an")

    append(&cmd, dst_webm)

    desc := os2.Process_Desc{command = cmd[:]}
    fmt.println("Running ffmpeg:", src)
    p, err := os2.process_start(desc)

    if err != nil {
        fmt.eprintln("Failed to start ffmpeg for:", src, err)
        return false
    }
    defer {
        _ = os2.process_close(p)
    }

    state, wait_err := os2.process_wait(p)
    fmt.println("ffmpeg finished:", src, "exit", state.exit_code)
    delete(cmd)
    delete(crf_str)
    delete(cpu_str)
    if wait_err != nil || state.exit_code != 0 {
        fmt.eprintln("ffmpeg failed for:", src, "exit:", state.exit_code)
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
    if err != nil {
        fmt.eprintln("Failed to stat:", src_webm)
        return false
    }
    defer os2.file_info_delete(info, context.temp_allocator)

    fin: ^os2.File
    fin, err = os2.open(src_webm, {.Read})
    if err != nil || fin == nil {
        fmt.eprintln("Failed to open:", src_webm)
        return false
    }
    defer os2.close(fin)

    fout: ^os2.File
    fout, err = os2.open(dst_video, {.Write, .Create, .Trunc}, os2.Permissions_Default_File)
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

    buf := make([]u8, 256*1024)
    defer delete(buf)
    for {
        n, rerr := os2.read(fin, buf[:])
        if rerr == .EOF {
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

run_ffmpeg_audio :: proc(src, dst_audio: string, opts: Options, ffmpeg_path: string, lib_dir: string) -> bool {
    set_ffmpeg_lib_env(lib_dir)

    cmd: [dynamic]string
    append(&cmd, ffmpeg_path)
    append(&cmd, "-hide_banner")
    append(&cmd, "-loglevel")
    append(&cmd, "error")
    if opts.force {
        append(&cmd, "-y")
    } else {
        append(&cmd, "-n")
    }
    append(&cmd, "-i")
    append(&cmd, src)
    append(&cmd, "-vn")
    append(&cmd, "-c:a")
    append(&cmd, "libopus")
    append(&cmd, "-b:a")
    br_str := int_to_string(opts.audio_bitrate)
    br_k := strings.concatenate({br_str, "k"})
    append(&cmd, br_k)
    append(&cmd, dst_audio)

    desc := os2.Process_Desc{command = cmd[:]}
    p, err := os2.process_start(desc)
    if err != nil {
        delete(cmd)
        delete(br_k)
        delete(br_str)
        fmt.eprintln("Failed to start ffmpeg (audio) for:", src, err)
        return false
    }
    defer {
        _ = os2.process_close(p)
    }

    state, wait_err := os2.process_wait(p)
    delete(cmd)
    delete(br_k)
    delete(br_str)

    if wait_err != nil || state.exit_code != 0 {
        fmt.eprintln("ffmpeg audio failed for:", src, "exit:", state.exit_code)
        return false
    }
    return true
}

int_to_string :: proc(v: int) -> string {
    buf: [64]u8
    s := strconv.write_int(buf[:], i64(v), 10)
    return strings.clone(s)
}

main :: proc() {
    args := os2.args

    opts := Options{
        recursive = false,
        keep_webm = false,
        force = false,
        audio = false,
        audio_bitrate = 128,
        audio_out = "",
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
            case "--audio-out":
                if i+1 >= len(args) { print_usage(); return }
                i += 1
                opts.audio_out = args[i]
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
            case "--help", "-h":
                print_usage()
                return
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
    if err != nil && err != .Exist {
        fmt.eprintln("Failed to create output dir:", out, err)
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

    if opts.audio {
        if opts.audio_out == "" {
    base_dir := filepath.dir(out)
    opts.audio_out, _ = filepath.join([]string{base_dir, "video_audio"})
        }
        err = os2.make_directory_all(opts.audio_out)
        if err != nil && err != .Exist {
            fmt.eprintln("Failed to create audio output dir:", opts.audio_out, err)
            return
        }
    }

    for input in inputs {
        stem := filepath.stem(input)
        webm_name := strings.concatenate({stem, ".webm"})
        video_name := strings.concatenate({stem, ".video"})
        webm_path, _ := filepath.join([]string{out, webm_name})
        video_path, _ := filepath.join([]string{out, video_name})
        audio_name := strings.concatenate({stem, ".ogg"})
        audio_path := ""
        if opts.audio {
            audio_path, _ = filepath.join([]string{opts.audio_out, audio_name})
        }

        if !run_ffmpeg(input, webm_path, opts, ffmpeg_path, lib_dir) {
            delete(webm_name)
            delete(video_name)
            delete(webm_path)
            delete(video_path)
            delete(audio_name)
            if audio_path != "" do delete(audio_path)
            return
        }
        if !wrap_webm_to_video(webm_path, video_path, opts.force) {
            delete(webm_name)
            delete(video_name)
            delete(webm_path)
            delete(video_path)
            delete(audio_name)
            if audio_path != "" do delete(audio_path)
            return
        }
        if opts.audio {
            if !run_ffmpeg_audio(input, audio_path, opts, ffmpeg_path, lib_dir) {
                delete(webm_name)
                delete(video_name)
                delete(webm_path)
                delete(video_path)
                delete(audio_name)
                delete(audio_path)
                return
            }
        }
        if !opts.keep_webm {
            _ = os2.remove(webm_path)
        }
        fmt.println("Built", video_path)
        delete(webm_name)
        delete(video_name)
        delete(webm_path)
        delete(video_path)
        delete(audio_name)
        if audio_path != "" do delete(audio_path)
    }
}
