// SPDX-License-Identifier: LGPL-3.0-or-later
//! Builds GMP's runtime-loading module graph from the selected translated header.
//! Do not link the archive here; calls must resolve through the generated dispatch.

const std = @import("std");

/// Must match the prefix used by `runtime/sync.c` and `runtime/library.zig`.
const sync_prefix = "gmp_rt";

/// libc symbols that stay direct rather than entering the provider dispatch.
const libc_noise =
    \\__acrt_iob_func,__asprintf,__attr_access,__attr_dealloc,__attribute__,__builtin_constant_p,
    \\__builtin_va_arg,__builtin_va_arg_pack,__builtin_va_copy,__builtin_va_end,__builtin_va_start,__deprecated__,
    \\__deprecated_msg,__format__,__getdelim,__gets_chk,__gnu_printf__,__gnu_scanf__,
    \\__iob_func,__isoc23_fscanf,__isoc23_scanf,__isoc23_sscanf,__isoc23_vfscanf,__isoc23_vscanf,
    \\__isoc23_vsscanf,__isoc99_fscanf,__isoc99_scanf,__isoc99_sscanf,__isoc99_vfscanf,__isoc99_vscanf,
    \\__isoc99_vsscanf,__local_stdio_printf_options,__local_stdio_scanf_options,__memcmpeq,__mempcpy,__mingw_asprintf,
    \\__mingw_bos,__mingw_bos_known,__mingw_bos_ptr_chk,__mingw_bos_ptr_chk_warn,__mingw_call_fgets,__mingw_call_fread,
    \\__mingw_call_gets_warn,__mingw_call_ms_sprintf,__mingw_call_ms_vsprintf,__mingw_call_snprintf,__mingw_call_sprintf,__mingw_call_tmpnam,
    \\__mingw_call_vsnprintf,__mingw_call_vsprintf,__mingw_fprintf,__mingw_fscanf,__mingw_fwprintf,__mingw_fwscanf,
    \\__mingw_printf,__mingw_scanf,__mingw_snprintf,__mingw_snwprintf,__mingw_sprintf,__mingw_sscanf,
    \\__mingw_str_free,__mingw_str_utf8_wide,__mingw_str_wide_utf8,__mingw_swprintf,__mingw_swscanf,__mingw_vasprintf,
    \\__mingw_vfprintf,__mingw_vfscanf,__mingw_vfwprintf,__mingw_vfwscanf,__mingw_vprintf,__mingw_vscanf,
    \\__mingw_vsnprintf,__mingw_vsnwprintf,__mingw_vsprintf,__mingw_vsscanf,__mingw_vswprintf,__mingw_vswscanf,
    \\__mingw_vwprintf,__mingw_vwscanf,__mingw_wprintf,__mingw_wscanf,__ms_fprintf,__ms_fscanf,
    \\__ms_fwprintf,__ms_fwscanf,__ms_printf,__ms_printf__,__ms_scanf,__ms_scanf__,
    \\__ms_snprintf,__ms_snwprintf,__ms_sprintf,__ms_sscanf,__ms_swprintf,__ms_swscanf,
    \\__ms_vfprintf,__ms_vfscanf,__ms_vfwprintf,__ms_vfwscanf,__ms_vprintf,__ms_vscanf,
    \\__ms_vsnprintf,__ms_vsnwprintf,__ms_vsprintf,__ms_vsscanf,__ms_vswprintf,__ms_vswscanf,
    \\__ms_vwprintf,__ms_vwscanf,__ms_wprintf,__ms_wscanf,__nonnull,__obstack_free,
    \\__printf__,__printflike,__scanf__,__scanflike,__stdio_common_vfprintf,__stdio_common_vfscanf,
    \\__stdio_common_vfwprintf,__stdio_common_vfwscanf,__stdio_common_vsprintf,__stdio_common_vsscanf,__stdio_common_vswprintf,__stdio_common_vswscanf,
    \\__stpcpy,__stpncpy,__strtok_r,__svfscanf,__swift_unavailable,__swprintf_l,
    \\__va_copy,__vswprintf_l,__warning__,__xpg_strerror_r,_fclose_nolock,_fcloseall,
    \\_fflush_nolock,_fgetc_nolock,_fgetchar,_filbuf,_fileno,_flsbuf,
    \\_flushall,_fputc_nolock,_fputchar,_fread_nolock,_fseek_nolock,_ftell_nolock,
    \\_fwrite_nolock,_get_output_format,_get_printf_count_output,_getc_nolock,_getchar_nolock,_getmaxstdio,
    \\_lock_file,_obstack_begin,_obstack_begin_1,_obstack_memory_used,_obstack_newchunk,_putc_nolock,
    \\_putchar_nolock,_rmtmp,_scprintf,_scwprintf,_set_output_format,_set_printf_count_output,
    \\_setmaxstdio,_snprintf,_snscanf,_snwprintf,_spawnv,_spawnve,
    \\_spawnvp,_spawnvpe,_swprintf,_swprintf_c,_ungetc_nolock,_unlock_file,
    \\_vscprintf,_vscwprintf,_vsnprintf,_vsnwprintf,_vswprintf,_vswprintf_c,
    \\_wfdopen,_wfopen,_wfreopen,_wfsopen,_wperror,_wpopen,
    \\_wremove,_wspawnl,_wspawnle,_wspawnlp,_wspawnlpe,_wspawnv,
    \\_wspawnve,_wspawnvp,_wspawnvpe,_wtempnam,_wtmpnam,asprintf,
    \\clearerr,clearerr_unlocked,ctermid_r,dprintf,explicit_bzero,fclose,
    \\fcloseall,fdopen,feof,feof_unlocked,ferror,ferror_unlocked,
    \\fflush,fflush_unlocked,fgetc,fgetc_unlocked,fgetchar,fgetln,
    \\fgetpos,fgetpos64,fgets,fgets_unlocked,fgetwc,fgetws,
    \\fileno,fileno_unlocked,flockfile,flushall,fmemopen,fopen,
    \\fopen64,fopencookie,fprintf,fpurge,fputc,fputc_unlocked,
    \\fputchar,fputs,fputs_unlocked,fputwc,fputws,fread,
    \\fread_unlocked,freopen,freopen64,fscanf,fseek,fseeko,
    \\fseeko64,fsetpos,fsetpos64,ftell,ftello,ftello64,
    \\ftrylockfile,funlockfile,fwopen,fwprintf,fwrite,fwrite_unlocked,
    \\fwscanf,getc,getc_unlocked,getchar,getchar_unlocked,getdelim,
    \\getline,gets,getw,getwc,getwchar,memccpy,
    \\memchr,memcmp,memcpy,memfrob,memmem,memmove,
    \\mempcpy,memrchr,memset,memset_explicit,mkstemp,obstack_alloc_failed_handler,
    \\obstack_exit_failure,obstack_free,obstack_printf,obstack_vprintf,open_memstream,open_wmemstream,pclose,
    \\perror,popen,printf,putc,putc_unlocked,
    \\putchar,putchar_unlocked,puts,putw,putwc,putwchar,
    \\rawmemchr,remove,rename,renameat,renameat2,rewind,
    \\scanf,setbuf,setbuffer,setlinebuf,setvbuf,sigabbrev_np,
    \\sigdescr_np,snprintf,snwprintf,sprintf,sscanf,stderr,
    \\stdin,stdout,stpcpy,stpncpy,strcasestr,strcat,
    \\strchr,strchrnul,strcmp,strcoll,strcoll_l,strcpy,
    \\strcspn,strdup,strerror,strerror_l,strerror_r,strerrordesc_np,
    \\strerrorname_np,strfry,strlcat,strlcpy,strlen,strncat,
    \\strncmp,strncpy,strndup,strnlen,strpbrk,strrchr,
    \\strsep,strsignal,strspn,strstr,strtok,strtok_r,
    \\strverscmp,strxfrm,strxfrm_l,swprintf,swscanf,tempnam,
    \\tmpfile,tmpfile64,tmpnam,tmpnam_r,ungetc,ungetwc,
    \\unlink,vasprintf,vdprintf,vfprintf,vfscanf,vfwprintf,
    \\vfwscanf,vprintf,vscanf,vsnprintf,vsnwprintf,vsprintf,
    \\vsscanf,vswprintf,vswscanf,vwprintf,vwscanf,wprintf,
    \\wscanf,
    \\__isthreaded,__mingw_get_crt_info,__overflow,__prefetch,__snprintf_chk,__sprintf_chk,__srget,
    \\__stderrp,__stdinp,__stdio_common_vfprintf_p,__stdio_common_vfprintf_s,
    \\__stdio_common_vfwprintf_s,__stdio_common_vsnprintf_s,__stdio_common_vsnwprintf_s,
    \\__stdio_common_vsprintf_p,__stdio_common_vsprintf_s,__stdio_common_vswprintf_s,__stdoutp,
    \\__swbuf,__uflow,__vsnprintf_chk,__vsprintf_chk,__wasi_args_get,__wasi_args_sizes_get,
    \\__wasi_clock_res_get,__wasi_clock_time_get,__wasi_environ_get,__wasi_environ_sizes_get,
    \\__wasi_fd_advise,__wasi_fd_allocate,__wasi_fd_close,__wasi_fd_datasync,__wasi_fd_fdstat_get,
    \\__wasi_fd_fdstat_set_flags,__wasi_fd_fdstat_set_rights,__wasi_fd_filestat_get,
    \\__wasi_fd_filestat_set_size,__wasi_fd_filestat_set_times,__wasi_fd_pread,
    \\__wasi_fd_prestat_dir_name,__wasi_fd_prestat_get,__wasi_fd_pwrite,__wasi_fd_read,
    \\__wasi_fd_readdir,__wasi_fd_renumber,__wasi_fd_seek,__wasi_fd_sync,__wasi_fd_tell,
    \\__wasi_fd_write,__wasi_path_create_directory,__wasi_path_filestat_get,
    \\__wasi_path_filestat_set_times,__wasi_path_link,__wasi_path_open,__wasi_path_readlink,
    \\__wasi_path_remove_directory,__wasi_path_rename,__wasi_path_symlink,__wasi_path_unlink_file,
    \\__wasi_poll_oneoff,__wasi_proc_exit,__wasi_random_get,__wasi_sched_yield,__wasi_sock_accept,
    \\__wasi_sock_recv,__wasi_sock_send,__wasi_sock_shutdown,_fdopen,_fgetwc_nolock,_fgetwchar,
    \\_fprintf_l,_fprintf_p,_fprintf_p_l,_fprintf_s_l,_fputwc_nolock,_fputwchar,_fread_nolock_s,
    \\_fscanf_l,_fscanf_s_l,_fseeki64,_fseeki64_nolock,_fsopen,_ftelli64,_ftelli64_nolock,
    \\_fwprintf_s_l,_fwscanf_s_l,_getw,_getws,_getws_s,_pclose,_popen,_printf_l,_printf_p,
    \\_printf_p_l,_printf_s_l,_putw,_putws,_scanf_l,_scanf_s_l,_scprintf_l,_scprintf_p,
    \\_scprintf_p_l,_snprintf_c,_snprintf_c_l,_snprintf_l,_snprintf_s,_snprintf_s_l,_snscanf_l,
    \\_snscanf_s,_snscanf_s_l,_snwprintf_s,_snwprintf_s_l,_snwscanf,_snwscanf_s,_snwscanf_s_l,
    \\_sprintf_l,_sprintf_p,_sprintf_p_l,_sprintf_s_l,_sscanf_l,_sscanf_s_l,_swprintf_s_l,
    \\_swscanf_s_l,_tempnam,_ungetwc_nolock,_unlink,_wfopen_s,_wfreopen_s,_wprintf_s_l,_wscanf_s_l,
    \\_wtmpnam_s,bcmp,bcopy,bzero,clearerr_s,ctermid,cuserid,fdclose,ffs,ffsl,ffsll,fmtcheck,
    \\fopen_s,fprintf_s,fread_s,freopen_s,fscanf_s,ftruncate,funopen,fwprintf_s,fwscanf_s,gets_s,
    \\strcasecmp,strcasecmp_l,strncasecmp,strncasecmp_l,swprintf_s,swscanf_s,sys_nerr,tmpfile_s,
    \\tmpnam_s,truncate,wprintf_s,wscanf_s,
    \\__dprintf_chk,__explicit_bzero_chk,__fgets_alias,__fgets_chk,__fgets_chk_warn,__fprintf_chk,__fread_alias,__fread_chk,__fread_chk_warn,__fread_unlocked_alias,__fread_unlocked_chk,__fread_unlocked_chk_warn,__printf_chk,__strlcat_alias,__strlcat_chk,__strlcpy_alias,__strlcpy_chk,__vdprintf_chk,__vfprintf_chk,__vprintf_chk
;

/// No optional symbols: GMP gates the obstack entries in both header and library.
const provider_optional = "";

/// No provider symbols are excluded; only names in `libc_noise` stay direct.
const provider_excluded = "";

/// Creates the linked build's core so both configurations expose the same public types.
/// Runtime builds must reuse the dispatch's single core instance.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // Unix loader calls come from libc.
        .link_libc = true,
    });
}

/// Creates the runtime dispatch from this target's translated C module.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

/// The patched translation and dispatch outputs.
const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);

    // Re-export translated types so the facade and dispatch share nominal types.
    // The patched translation routes nested macros through `c_routed`.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Runs the host generator on this target's translation; configurations produce separate outputs.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("gmp-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("gmp");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
