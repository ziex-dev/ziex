const TranslatedZx = @This();

const std = @import("std");

owner: *std.Build,
run: *std.Build.Step.Run,
output_dir: std.Build.LazyPath,
out_basename: []const u8,
mod_opts: std.Build.Module.CreateOptions,

pub const Options = struct {
    /// The `.zx` / `.mdzx` / `.md` source file to transpile.
    root_source_file: std.Build.LazyPath,
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.lang.Optimize = null,
};

/// Create a `TranslatedZx` by running the host `zx transpile` CLI over
/// `opts.root_source_file`.
pub fn create(
    b: *std.Build,
    transpiler_exe: *std.Build.Step.Compile,
    opts: Options,
) *TranslatedZx {
    const self = b.allocator.create(TranslatedZx) catch @panic("OOM");

    const basename = rootBasename(opts.root_source_file);
    const ext = std.Io.Dir.path.extension(basename);
    const stem = if (ext.len > 0 and basename.len > ext.len)
        basename[0 .. basename.len - ext.len]
    else
        basename;
    const out_basename = b.fmt("{s}.zig", .{stem});

    const run = b.addRunArtifact(transpiler_exe);
    run.setName(b.fmt("translate-zx {s}", .{basename}));
    run.expectExitCode(0);

    run.addArg("transpile");
    run.addFileArg(opts.root_source_file);

    run.addArg("--outdir");
    const output_dir = run.addOutputDirectoryArg2("translated", .{});
    run.addArg("--dep-file");
    _ = run.addDepFileOutputArg2("transpile.d", .{});
    run.addArgs(&.{ "--map", "inline" });

    self.* = .{
        .owner = b,
        .run = run,
        .output_dir = output_dir,
        .out_basename = out_basename,
        .mod_opts = .{
            .root_source_file = output_dir.path(b, out_basename),
            .target = opts.target,
            .optimize = opts.optimize,
        },
    };
    return self;
}

/// The translated root `.zig` source file.
pub fn getOutput(self: *TranslatedZx) std.Build.LazyPath {
    return self.output_dir.path(self.owner, self.out_basename);
}

/// Create a private module from the translated source. The module has no `zx`
/// import - add it afterwards, e.g. `mod.addImport("zx", zx_module)`.
pub fn createModule(self: *TranslatedZx) *std.Build.Module {
    return self.owner.createModule(self.mod_opts);
}

/// Like `createModule`, but exposes the module to dependent packages under `name`.
pub fn addModule(self: *TranslatedZx, name: []const u8) *std.Build.Module {
    return self.owner.addModule(name, self.mod_opts);
}

fn rootBasename(lp: std.Build.LazyPath) []const u8 {
    const sub_path = switch (lp) {
        .src_path => |sp| sp.sub_path,
        .cwd_relative => |p| p,
        .dependency => |d| d.sub_path,
        .relative => |r| r.sub_path,
        .generated => |g| if (g.sub_path.len != 0) g.sub_path else "generated.zx",
    };
    return std.Io.Dir.path.basename(sub_path);
}
