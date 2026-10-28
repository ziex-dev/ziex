// NOTE: This has been taken from https://codeberg.org/ziglang/zig/pulls/31620/files, once this is merged to std, we should just use std.cli instead
/// Command-line argument parser.
///
/// The grammar of a command-line is represented as a directed acyclic graph of commands and subcommands.
/// Each command may have named and positional arguments.
///
/// For example, a graph representing these two git commands:
///
/// ```sh
/// git clone https://example.com/repo.git
/// git commit -m "added cli to std library"
/// ```
///
/// ```
///  - git (root command)
///      - clone (subcommand)
///          - url (positional string argument)
///      - commit (subcommand)
///          - message (named string argument)
/// ```
///
/// 1. Describe your graph at comptime with `Command`.
/// 2. Parse the command-line with `const parsed = try parse(command, ...)`.
/// 3. Optionally automatically exit the program when help is requested or there is a usage error.
/// 4. Access arguments with `parsed.kind.args.@"my-argument-name-here"`.
/// 5. Access subcommands with `if (parsed.subcommand) |subcommand| switch (subcommand) ...`.
///
/// `--help` and '-h' named arguments are reserved by the parser to indicate help was requested by the user.
/// Determine if help was requested (if not auto-exiting) with `switch (parsed.kind) {.help => ..., .args => ...}`.
const cli = @This();

const std = @import("std");
const assert = std.debug.assert;

fn cutPrefixSentinel(comptime T: type, comptime s: T, haystack: [:s]const T, prefix: []const T) ?[:s]const T {
    if (!std.mem.startsWith(T, haystack, prefix)) return null;
    return haystack[prefix.len.. :s];
}

/// A recursive representation of the commands available in a CLI.
pub const Command = struct {
    /// If this is the root command, has no effect. Example: "git".
    /// For subcommands, this is the name of the corresponding tagged union field in `parsed.subcommands.?`. Example: `.commit`.
    /// Name of the subcommand in the cli.
    /// To obtain a dashed-command like `git merge-base`, provide name `.@"merge-base"` and access with `parsed.subcommands.?.@"merge-base"`.
    /// Must not start with "-".
    name: @EnumLiteral(),
    /// Named arguments are arguments that begin with `--` in the CLI, or `-` for shorthands, like `git commit --message "std.cli"` or `git commit -m "std.cli"`.
    named_args: []const Argument = &.{},
    /// Positional arguments are arguments parsed by their position after the command. Like the branch name in `git branch dev/std.cli`.
    positional_args: []const Argument = &.{},
    /// The subcommands of this command. Like `commit` in `git commit`.
    subcommands: []const Command = &.{},
    /// Long-form help text for this command. For example the text returned by `git --help`.
    /// Typically ends in a newline (`"\n"`).
    help: [:0]const u8 = "",
    /// The single-line help sentence for subcommands.
    help_short: [:0]const u8 = "",
    /// Omitted from generated help. Still parsed normally.
    hidden: bool = false,
};

pub const Argument = struct {
    /// Field name in the Parsed.args struct.
    name: [:0]const u8,
    /// Type of field in Parsed.args.
    type: type,
    attrs: std.builtin.Type.Struct.FieldAttributes,
    count: Count,
    /// The single-line help sentence next to each option in a list of options.
    help: [:0]const u8,
    /// If non-null, allows named arguments to have single character aliases.
    /// Example: `git commit -m "std.cli"` and `git commit --message "std.cli"` parse results are identical.
    /// Has no effect for positional arguments.
    short: ?u8,
    /// Omitted from generated help. Still parsed normally.
    hidden: bool,

    pub const Count = enum {
        /// If the argument is provided multiple times, the last instance is the result.
        /// Example: `git --verbose --no-verbose` results in a single false bool for `parsed.kind.args.verbose`.
        one,
        /// If the argument is provided multiple times, they are accumulated into a slice.
        /// Example: `git commit --message "Paragraph 1" --message "Paragraph 2"` results in `&.{"Paragraph 1", "Paragraph 2"}` and args.message is a `[]const []const u8` (the provided `T` must be a slice type).
        unlimited,
    };

    pub fn init(
        /// Name of the corresponding field in `parsed.kind.args`.
        /// Prefixed with `--` for the CLI user.
        /// Example: `git commit --message "std.cli"` has name `.message` and parsed.kind.args.message is `"std.cli"`.
        ///
        /// To obtain dashed arguments like `git commit --reset-author` provide `.@"reset-author"` and access with `parsed.kind.args.@"reset-author"`.
        comptime name: @EnumLiteral(),
        /// The type of the corresponding field in `parsed.kind.args`.
        ///
        /// - bool: `--verbose`, `--verbose=true`, `-v` result in true. `--no-verbose`, `--verbose=false` result in false.
        /// - enum: string input corresponding to each enum field. Example: `--log-level debug` results in `.debug`.
        /// - integer: uses `std.fmt.parseInt` to parse an integer.
        /// - float: uses `std.fmt.parseFloat` to parse a float.
        /// - `[]const u8`: a string. Example: `git branch dev/std.cli` results in `"dev/std.cli"`. `[:0]const u8` is also supported.
        /// - `?T`: when the user does not provide the argument, results in `null`. `null` is the only supported default value.
        ///
        /// For `.count = .unlimited` arguments, provide a `[]T`. Example: `git add README.md build.zig.zon` can be parsed with `[]const []const u8` as `&.{"README.md", "build.zig.zon"}`.
        comptime T: type,
        comptime options: struct {
            count: Count = .one,
            help: [:0]const u8 = "",
            /// Arguments with default values are optional in the CLI and the default value is applied to the field before it is returned as part of `parsed.kind.args`.
            /// Optionals types (like ?i32) may only have default value null. This allows determining if a user provided argument or not. Example: `git branch dev/std.cli` has optional `?[]const u8` positional argument.
            default_value: ?T = null,
            short: ?u8 = null,
            hidden: bool = false,
        },
    ) Argument {
        switch (options.count) {
            .one => {},
            .unlimited => {
                if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .slice) {
                    @compileError("Unlimited arguments must be a slice type.");
                }
            },
        }
        const default_value_ptr: ?*const anyopaque = switch (@typeInfo(T)) {
            .optional => if (options.default_value) |_| {
                @compileError("The only supported default value for optional types is null");
            } else &@as(T, null),
            else => if (options.default_value) |value| @ptrCast(@alignCast(&value)) else null,
        };

        return .{
            .name = @tagName(name),
            .type = T,
            .attrs = .{
                .default_value_ptr = default_value_ptr,
                .@"align" = null,
                .@"comptime" = false,
            },
            .count = options.count,
            .help = options.help,
            .short = options.short,
            .hidden = options.hidden,
        };
    }

    pub inline fn isOptional(comptime self: Argument) bool {
        return @typeInfo(self.type) == .optional or self.attrs.defaultValue(self.type) != null;
    }
};

/// Represents the result of CLI parsing.
///
/// When the user requests help, `parsed.kind == .help`, otherwise the named and positional arguments are accessible in `parsed.kind.args`.
/// Subcommands are accessible in `parsed.subcommand`.
pub fn Parsed(comptime command: Command) type {
    const ArgsStruct = blk: {
        const num_args = command.named_args.len + command.positional_args.len;
        var field_types: [num_args]type = undefined;
        var field_names: [num_args][]const u8 = undefined;
        var field_attrs: [num_args]std.builtin.Type.Struct.FieldAttributes = undefined;
        inline for (&field_types, &field_names, &field_attrs, command.named_args ++ command.positional_args) |*field_type, *field_name, *field_attr, arg| {
            field_type.* = arg.type;
            field_name.* = arg.name;
            field_attr.* = .{
                .@"comptime" = arg.attrs.@"comptime",
                .@"align" = arg.attrs.@"align",
                .default_value_ptr = arg.attrs.default_value_ptr,
            };
        }
        break :blk @Struct(
            .auto,
            null,
            &field_names,
            &field_types,
            &field_attrs,
        );
    };

    const SubcommandTaggedUnion = blk: {
        if (command.subcommands.len <= 0) {
            const E = @Enum(noreturn, .exhaustive, &.{}, &.{});
            break :blk @Union(.auto, E, &.{}, &.{}, &.{});
        }

        var field_types: [command.subcommands.len]type = undefined;
        var field_names: [command.subcommands.len][]const u8 = undefined;
        inline for (&field_types, &field_names, command.subcommands) |*field_type, *field_name, subcommand| {
            field_type.* = Parsed(subcommand);
            field_name.* = @tagName(subcommand.name);
        }
        const field_attrs: [command.subcommands.len]std.builtin.Type.Union.FieldAttributes = @splat(.{});
        const bits = if (field_names.len != 0) std.math.log2_int_ceil(usize, field_names.len) else 0;
        const TagInt = @Int(.unsigned, bits);
        comptime var field_values: [field_names.len]TagInt = undefined;
        comptime for (0..field_names.len) |id| {
            field_values[id] = @intCast(id);
        };
        const E = @Enum(TagInt, .exhaustive, &field_names, &field_values);
        break :blk @Union(
            .auto,
            E,
            &field_names,
            &field_types,
            &field_attrs,
        );
    };

    return struct {
        kind: union(enum) {
            /// Help requested by user with `--help`.
            help,
            /// The named and positional arguments.
            /// Each argument is a field in this struct.
            args: ArgsStruct,
        },
        /// null when no subcommand provided.
        /// Each union field is a subcommand.
        subcommand: ?SubcommandTaggedUnion,
    };
}

pub const ParseOptions = struct {
    /// Call std.process.exit(1) when there is a usage error.
    exit_usage_error: bool = false,
    /// Provide information about why a usage error occurred to stderr.
    /// Errors when writing to stderr are silently ignored.
    render_usage_errors: bool = false,
    /// Call std.process.exit(0) when the user requests help with --help.
    exit_help: bool = false,
    /// Provide help information to stdout when the user requests help with --help.
    /// Errors when writing to stdout are silently ignored.
    render_help: union(enum) {
        /// Write the .help field for the active subcommand verbatim.
        verbatim,
        /// Write a generated help text (based on command).
        generated,
        /// No help text will be written to stdout.
        none,
    } = .none,
};

pub const ParseError = error{
    /// Malformed input from the user.
    /// Example: `git commit --not-a-valid-option`.
    Usage,
};

/// Parse the operating system provided arguments according to the grammar defined in command.
/// The lifetime of args must exceed the return value (return value may point to args).
/// If you have .count = .unlimited args, parsing will require allocation. See parseAlloc.
///
/// This function has no side-effects unless enabled in options.
pub fn parse(
    comptime command: Command,
    /// See std.process.Args.toSlice
    /// Index 0 is skipped (typically the program name). No args is a usage error.
    args: []const [:0]const u8,
    options: ParseOptions,
) ParseAllocError!Parsed(command) {
    comptime if (parseRequiresAlloc(command)) @compileError("Parsing requires allocation. See parseAlloc.");
    var iter: Iterator = .init(args);
    const argv0 = iter.next() orelse return usageErrorExit(options, "missing first argument (typically program name)", .{});
    const parsed = try parseRecursive(command, null, &iter, options);
    helpExit(command, argv0, parsed, options);
    return parsed;
}

pub const ParseAllocError = ParseError || std.mem.Allocator.Error;

/// The allocator is only required for .count = .unlimited arguments.
/// If you don't have those, consider using parse instead.
///
/// This function has no side-effects unless enabled in options.
pub fn parseAlloc(
    comptime command: Command,
    arena: std.mem.Allocator,
    /// See std.process.Args.toSlice
    /// Index 0 is skipped (typically the program name). No args is a usage error.
    args: []const [:0]const u8,
    options: ParseOptions,
) ParseAllocError!Parsed(command) {
    var iter: Iterator = .init(args);
    const argv0 = iter.next() orelse return usageErrorExit(options, "missing first argument (typically program name)", .{});
    const parsed = try parseRecursive(command, arena, &iter, options);
    helpExit(command, argv0, parsed, options);
    return parsed;
}

test parseAlloc {
    const command: Command = .{
        .name = .git,
        .help =
        \\A version control system.
        \\
        \\Options:
        \\  --log-level   One of err, warn, info, debug.
        \\
        \\Subcommands:
        \\  branch: create a branch
        \\  commit: commit changes to the repository
        \\
        ,
        .named_args = &.{
            .init(.@"log-level", std.log.Level, .{ .default_value = .err }),
        },
        .subcommands = &.{
            .{
                .name = .branch,
                .positional_args = &.{
                    .init(.branch_name, []const u8, .{}),
                },
            },
            .{
                .name = .commit,
                .named_args = &.{
                    .init(.message, []const u8, .{ .short = 'm' }),
                },
            },
        },
    };
    const parsed = try parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{"git"},
        .{},
    );
    try std.testing.expect(parsed.kind.args.@"log-level" == .err);

    const parsed2 = try parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{ "git", "--help" },
        .{},
    );
    try std.testing.expect(parsed2.kind == .help);
    try std.testing.expect(parsed2.subcommand == null);

    const parsed3 = try parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{ "git", "--log-level=debug" },
        .{},
    );
    try std.testing.expectEqual(.debug, parsed3.kind.args.@"log-level");
    try std.testing.expect(parsed3.subcommand == null);

    const parsed4 = try parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{ "git", "commit", "-m", "std.cli" },
        .{},
    );
    try std.testing.expect(parsed4.subcommand.? == .commit);
    try std.testing.expectEqualStrings("std.cli", parsed4.subcommand.?.commit.kind.args.message);

    const parsed5 = try parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{ "git", "branch", "dev/std.cli" },
        .{},
    );
    try std.testing.expect(parsed5.subcommand.? == .branch);
    try std.testing.expectEqualStrings("dev/std.cli", parsed5.subcommand.?.branch.kind.args.branch_name);

    const parsed6 = parseAlloc(
        command,
        std.testing.failing_allocator,
        &.{ "git", "--not-an-option", "branch", "dev/std.cli" },
        .{},
    );
    try std.testing.expectError(error.Usage, parsed6);
}

fn helpExit(
    comptime command: Command,
    argv0: []const u8,
    parsed: Parsed(command),
    options: ParseOptions,
) void {
    if (helpWanted(parsed)) {
        switch (options.render_help) {
            .none => {},
            .verbatim => {
                var io_impl: std.Io.Threaded = .init_single_threaded;
                const io = io_impl.io();
                var buf: [1024]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(io, &buf);
                const writer: *std.Io.Writer = &stdout.interface;
                writeHelpVerbatim(command, parsed, writer) catch {};
                writer.flush() catch {};
            },
            .generated => {
                var io_impl: std.Io.Threaded = .init_single_threaded;
                const io = io_impl.io();
                var buf: [1024]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(io, &buf);
                const writer: *std.Io.Writer = &stdout.interface;
                writeHelpGenerated(command, argv0, parsed, writer) catch {};
                writer.flush() catch {};
            },
        }
    }

    if (options.exit_help and helpWanted(parsed)) {
        std.process.exit(0);
    }
}

fn parseRequiresAlloc(comptime command: Command) bool {
    inline for (command.named_args ++ command.positional_args) |arg| {
        switch (arg.count) {
            .unlimited => return true,
            .one => {},
        }
    }
    inline for (command.subcommands) |subcommand| {
        if (parseRequiresAlloc(subcommand)) return true;
    }
    return false;
}

test parseRequiresAlloc {
    const needs_alloc_named: Command = .{ .name = .@"an-executable", .named_args = &.{.init(.verbose, []bool, .{ .count = .unlimited })} };
    try std.testing.expect(parseRequiresAlloc(needs_alloc_named));
    const needs_alloc_pos: Command = .{ .name = .@"an-executable", .positional_args = &.{.init(.verbose, []bool, .{ .count = .unlimited })} };
    try std.testing.expect(parseRequiresAlloc(needs_alloc_pos));
    const no_needs_alloc_named: Command = .{ .name = .@"an-executable", .named_args = &.{.init(.verbose, bool, .{ .count = .one })} };
    try std.testing.expect(!parseRequiresAlloc(no_needs_alloc_named));
    const no_needs_alloc_pos: Command = .{ .name = .@"an-executable", .positional_args = &.{.init(.verbose, bool, .{ .count = .one })} };
    try std.testing.expect(!parseRequiresAlloc(no_needs_alloc_named));

    const sub_needs_alloc_named: Command = .{ .name = .@"an-executable", .subcommands = &.{needs_alloc_named} };
    try std.testing.expect(parseRequiresAlloc(sub_needs_alloc_named));
    const sub_needs_alloc_pos: Command = .{ .name = .@"an-executable", .subcommands = &.{needs_alloc_pos} };
    try std.testing.expect(parseRequiresAlloc(sub_needs_alloc_pos));
    const no_sub_needs_alloc_named: Command = .{ .name = .@"an-executable", .subcommands = &.{no_needs_alloc_named} };
    try std.testing.expect(!parseRequiresAlloc(no_sub_needs_alloc_named));
    const no_sub_needs_alloc_pos: Command = .{ .name = .@"an-executable", .subcommands = &.{no_needs_alloc_pos} };
    try std.testing.expect(!parseRequiresAlloc(no_sub_needs_alloc_pos));
}

fn validateCommand(comptime command: Command) void {
    inline for (command.named_args) |arg| {
        if (std.mem.eql(u8, arg.name, "help")) {
            @compileError("named argument --help is reserved by the parser and may not be used.");
        }
        if (arg.short == 'h') {
            @compileError("named short argument -h is reserved by the parser and may not be used.");
        }
    }

    // optional positional args must come after required args
    var seen_optional = false;
    inline for (command.positional_args) |arg| {
        if (seen_optional and !arg.isOptional()) {
            @compileError("Optional positional arguments must follow required positional arguments. Offender: " ++ arg.name);
        }
        if (arg.isOptional()) {
            seen_optional = true;
        }
    }

    // Multiple optional positionals makes parsing ambiguous.
    var last_optional_positional: ?[]const u8 = null;
    inline for (command.positional_args) |arg| {
        if (arg.attrs.defaultValue(arg.type) != null) {
            if (last_optional_positional) |other_optional_positional_name| {
                @compileError("multiple optional positional arguments is prohibited. Offenders: " ++
                    other_optional_positional_name ++
                    " " ++
                    arg.name);
            }
            last_optional_positional = arg.name;
        }
    }

    // Multiple unlimited positional args is ambiguous.
    var last_positional_unlimited: ?[]const u8 = null;
    inline for (command.positional_args) |arg| {
        if (arg.count == .unlimited) {
            if (last_positional_unlimited) |other_positional_unlimited_name| {
                @compileError("multiple unlimited positional arguments is prohibited. Offenders: " ++
                    other_positional_unlimited_name ++
                    ", " ++
                    arg.name);
            }
            last_positional_unlimited = arg.name;
        }
    }

    // Unlimited positional arguments must be the last argument.
    inline for (command.positional_args, 0..) |arg, i| {
        if (arg.count == .unlimited and i + 1 != command.positional_args.len) {
            @compileError("Unlimited positional argument must be the last positional argument. Offender: " ++ arg.name);
        }
    }

    // Require unique shorthand.
    inline for (command.positional_args ++ command.named_args, 0..) |lhs_arg, i| {
        inline for (command.positional_args ++ command.named_args, 0..) |rhs_arg, j| {
            if (i == j) continue;
            if (lhs_arg.short != null and rhs_arg.short != null and lhs_arg.short.? == rhs_arg.short.?) {
                @compileError("Arguments with the same shorthand are prohibited. Offenders: " ++
                    "--" ++ lhs_arg.name ++ " (-" ++ [_]u8{lhs_arg.short.?} ++
                    "), " ++
                    "--" ++ rhs_arg.name ++ " (-" ++ [_]u8{rhs_arg.short.?} ++ ")");
            }
        }
    }

    // Shorthand may not be dash.
    inline for (command.positional_args ++ command.named_args) |arg| {
        if (arg.short) |short| {
            if (short == '-') {
                @compileError("Argument with shorthand \"-\" is prohibited. Offender: " ++ "--" ++ arg.name);
            }
        }
    }

    // Subcommand may not start with "-", conflicts with named arguments.
    inline for (command.subcommands) |subcommand| {
        if (comptime std.mem.startsWith(u8, @tagName(subcommand.name), "-")) {
            @compileError("Subcommand name may not start with \"-\", offender: " ++ @tagName(subcommand.name));
        }
    }
}

fn usageErrorExit(options: ParseOptions, comptime format: []const u8, args: anytype) error{Usage} {
    if (options.render_usage_errors) {
        std.log.err(format, args);
        std.log.err("Provide only --help for help.", .{});
    }
    if (options.exit_usage_error) std.process.exit(1);
    return error.Usage;
}

/// Write the .help field of the active command to out verbatim.
pub fn writeHelpVerbatim(comptime command: Command, parsed: Parsed(command), out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (parsed.subcommand) |subcommand| {
        switch (subcommand) {
            inline else => |value, tag| {
                inline for (command.subcommands) |subcommand_config| {
                    if (comptime std.mem.eql(u8, @tagName(subcommand_config.name), @tagName(tag))) {
                        return writeHelpVerbatim(subcommand_config, value, out);
                    }
                }
            },
        }
        unreachable;
    } else return try out.writeAll(command.help);
}
/// Write generated help message to out for the active command.
///
/// For commands:
///
///     - .help interpreted as a "prologue" to the list of arguments.
///     - .help_short is a single-line help message in a list of subcommands.
///
/// For arguments:
///
///     - .help is a single-line help message in list of arguments.
///
pub fn writeHelpGenerated(
    comptime command: Command,
    /// Example: "git" in a help usage string like "git add [OPTIONS] <files ...>"
    program_name: []const u8,
    parsed: Parsed(command),
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const descent_path = descentPath(command, parsed);
    return writeHelpRecursive(
        command,
        program_name,
        descent_path,
        parsed,
        out,
    );
}

fn writeHelpRecursive(
    comptime command: Command,
    program_name: []const u8,
    descent_path: []const [:0]const u8,
    parsed: Parsed(command),
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (parsed.subcommand) |subcommand| {
        switch (subcommand) {
            inline else => |value, tag| {
                inline for (command.subcommands) |subcommand_config| {
                    if (comptime std.mem.eql(u8, @tagName(subcommand_config.name), @tagName(tag))) {
                        return writeHelpRecursive(
                            subcommand_config,
                            program_name,
                            descent_path,
                            value,
                            out,
                        );
                    }
                }
            },
        }
        unreachable;
    } else return writeCommandGeneratedHelp(
        command,
        program_name,
        descent_path,
        out,
    );
    comptime unreachable;
}

/// Looks like this:
///
/// ```
/// Usage: git add [OPTIONS] <files ...>
///
/// Stage files before committing.
///
/// POSITIONAL ARGUMENTS
///   files
///     List of files to stage.
///
/// OPTIONS
///   -n, --dry-run, --no-dry-run
///     Don't actually do anything.
///
/// ```
pub fn writeCommandGeneratedHelp(
    comptime command: Command,
    /// Example: "git" in a help usage string like "git add [OPTIONS] <files ...>"
    program_name: []const u8,
    /// See descentPath.
    descent_path: []const [:0]const u8,
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try out.writeAll("Usage: ");
    try writeCommandUsage(command, program_name, descent_path, out);
    try out.writeAll("\n");

    if (command.help.len > 0) {
        try out.writeAll("\n");
        try out.print("{s}", .{command.help});
    }

    if (command.positional_args.len > 0) {
        try out.writeAll("\n");
        try out.writeAll("POSITIONAL ARGUMENTS\n");
        inline for (command.positional_args) |positional| {
            try out.print("  {s}\n", .{positional.name});
            if (positional.help.len > 0) try writeIndented(positional.help, 4, out);
            if (positional.attrs.defaultValue(positional.type)) |default_value| {
                if (@typeInfo(@TypeOf(default_value)) != .optional) {
                    try out.writeAll("    Default:");
                    try writeArgumentDefaultValue(positional, out);
                    try out.writeAll("\n");
                }
            }
        }
    }

    try out.writeAll("\n");
    try out.writeAll("OPTIONS\n");
    try out.writeAll("  -h, --help\n");
    try out.writeAll("    Print this help and exit.\n");
    inline for (command.named_args) |named| {
        if (named.hidden) continue;
        try out.writeAll("\n");
        const Value = switch (named.count) {
            .one => named.type,
            .unlimited => std.meta.Child(named.type),
        };
        if (named.short) |short| try out.print("  -{c}, ", .{short}) else try out.writeAll("  ");
        if (@typeInfo(Value) == .bool) {
            try out.print("--{s}, --no-{s}\n", .{ named.name, named.name });
        } else {
            switch (@typeInfo(Value)) {
                .@"enum" => try out.print("--{s} {{{s}}}\n", .{ named.name, helpTypeName(Value) }),
                else => try out.print("--{s} <{s}>\n", .{ named.name, helpTypeName(Value) }),
            }
        }
        if (named.help.len > 0) try writeIndented(named.help, 4, out);
        if (named.attrs.defaultValue(named.type)) |default_value| {
            if (@typeInfo(@TypeOf(default_value)) != .optional) {
                try out.writeAll("    Default:");
                try writeArgumentDefaultValue(named, out);
                try out.writeAll("\n");
            }
        }
    }

    if (command.subcommands.len > 0) {
        try out.writeAll("\n");
        try out.writeAll("SUBCOMMANDS");
        inline for (command.subcommands) |subcommand| {
            if (subcommand.hidden) continue;
            try out.writeAll("\n");
            try out.print("  {s}\n", .{@tagName(subcommand.name)});
            try writeIndented(subcommand.help_short, 4, out);
        }
    }
}

// Warning: converts \r\n to \n.
fn writeIndented(buf: [:0]const u8, comptime spaces: u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    var iter = std.mem.tokenizeAny(u8, buf, "\r\n");
    while (iter.next()) |next| {
        const indent: [spaces]u8 = @splat(' ');
        try out.writeAll(&indent);
        try out.writeAll(next);
        try out.writeAll("\n");
    }
}

/// Example: `git clone [OPTIONS] <url>`
pub fn writeCommandUsage(
    comptime command: Command,
    program_name: []const u8,
    /// See descentPath.
    descent_path: []const [:0]const u8,
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try out.print("{s} ", .{program_name});
    if (descent_path.len > 1) {
        for (descent_path[1..]) |cmd| {
            try out.print("{s} ", .{cmd});
        }
    }

    try out.writeAll("[OPTIONS]");

    inline for (command.positional_args) |positional| {
        // [name_of_a_positional ...]
        const fragment = blk: {
            comptime var s: [:0]const u8 = " ";
            {
                s = s ++ if (positional.isOptional()) "[" else "<";
                defer s = s ++ if (positional.isOptional()) "]" else ">";

                s = s ++ positional.name;
                switch (positional.count) {
                    .one => {},
                    .unlimited => s = s ++ " ...",
                }
            }
            break :blk s;
        };
        try out.writeAll(fragment);
    }
    if (command.subcommands.len > 0) try out.writeAll(" [SUBCOMMAND]");
}

/// The path of subcommands leading to and including the active subcommand.
///
/// Example: the descent path for `git commit -m "std.cli"` is `&.{"git", "commit"}`, and the active subcommand is `commit`.
pub fn descentPath(comptime command: Command, parsed: Parsed(command)) []const [:0]const u8 {
    return descentPathRecursive(&.{}, command, parsed);
}

// separate function only to avoid exposing user to awkward accumulator parameter
fn descentPathRecursive(comptime accumulator: []const [:0]const u8, comptime command: Command, parsed: Parsed(command)) []const [:0]const u8 {
    const result = accumulator ++ [_][:0]const u8{@tagName(command.name)};
    if (parsed.subcommand) |subcommand| {
        switch (subcommand) {
            inline else => |value, tag| {
                inline for (command.subcommands) |subcommand_config| {
                    if (comptime std.mem.eql(u8, @tagName(subcommand_config.name), @tagName(tag))) {
                        return descentPathRecursive(result, subcommand_config, value);
                    }
                }
            },
        }
    }
    return result;
}

pub fn helpWanted(parsed: anytype) bool {
    switch (parsed.kind) {
        .help => return true,
        .args => {},
    }
    if (parsed.subcommand) |subcommand| {
        switch (subcommand) {
            inline else => |value| return helpWanted(value),
        }
    }
    return false;
}

const Iterator = struct {
    args: []const [:0]const u8,
    idx: usize,
    fn init(args: []const [:0]const u8) Iterator {
        return .{ .args = args, .idx = 0 };
    }
    fn next(self: *Iterator) ?[:0]const u8 {
        if (self.idx == self.args.len) return null;
        defer self.idx += 1;
        return self.args[self.idx];
    }
};

/// Generates a struct with fields of type ArrayList(T) for each unlimited argument.
/// During parsing, instances of unlimited arguments are accumulated in the corresponding
/// arraylist.
fn UnlimitedArgStruct(comptime command: Command) type {
    var num_unlimited: usize = 0;
    for (command.named_args ++ command.positional_args) |arg| {
        switch (arg.count) {
            .unlimited => num_unlimited += 1,
            .one => {},
        }
    }

    var field_types: [num_unlimited]type = undefined;
    var field_names: [num_unlimited][]const u8 = undefined;
    var field_attrs: [num_unlimited]std.builtin.Type.Struct.FieldAttributes = undefined;

    var num_populated: usize = 0;
    inline for (command.named_args ++ command.positional_args) |arg| {
        switch (arg.count) {
            .unlimited => {
                field_types[num_populated] = std.ArrayList(std.meta.Child(arg.type));
                field_names[num_populated] = arg.name;
                field_attrs[num_populated] = .{ .default_value_ptr = &std.ArrayList(std.meta.Child(arg.type)).empty };
                num_populated += 1;
            },
            .one => continue,
        }
    }
    comptime assert(num_populated == num_unlimited);

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

const Defined = enum { defined, undefined };

/// Generates a struct with fields of type Defined for each argument.
/// Used during parsing to track which arguments have been provided by the user
/// and enforce that required arguments are provided.
fn DefinedArgStruct(comptime command: Command) type {
    const num_args = command.named_args.len + command.positional_args.len;
    var field_types: [num_args]type = @splat(Defined);
    var field_names: [num_args][]const u8 = undefined;
    var field_attrs: [num_args]std.builtin.Type.Struct.FieldAttributes = @splat(.{ .default_value_ptr = &Defined.undefined });
    inline for (command.named_args ++ command.positional_args, &field_names) |arg, *field_name| {
        field_name.* = arg.name;
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn ParseRecursiveError(MaybeArena: type) type {
    return switch (MaybeArena) {
        std.mem.Allocator => ParseAllocError,
        @TypeOf(null) => ParseError,
        else => comptime unreachable,
    };
}

fn parseRecursive(
    comptime command: Command,
    /// Provide comptime null if we know we won't allocate,
    /// otherwise provide std.mem.Allocator (arena suggested).
    maybe_arena: anytype,
    iter: *Iterator,
    options: ParseOptions,
) ParseRecursiveError(@TypeOf(maybe_arena))!Parsed(command) {
    comptime assert(@TypeOf(maybe_arena) == @TypeOf(null) or
        @TypeOf(maybe_arena) == std.mem.Allocator);
    comptime validateCommand(command);

    // parsing will fill the resulting args one field at a time
    var result_args: @FieldType(@FieldType(Parsed(command), "kind"), "args") = undefined;
    // As we fill the args, track what we have defined so undefined is not leaked to return value.
    // This also tracks what args are provided, to allow "error: missing required argument...".
    var defined: DefinedArgStruct(command) = .{};
    var result_subcommand: @FieldType(Parsed(command), "subcommand") = null;
    var unlimited_args: UnlimitedArgStruct(command) = .{};

    // args with default values are not required so they are filled in here first.
    // If found during parsing later, the default values are overwritten with the user-provided values.
    inline for (command.named_args ++ command.positional_args) |arg| {
        @field(result_args, arg.name) = arg.attrs.defaultValue(arg.type) orelse continue;
        @field(defined, arg.name) = .defined;
    }

    var began_forced_positional: bool = false;
    var positional_idx: usize = 0;
    next_os_arg: while (iter.next()) |os_arg| {
        if (!began_forced_positional) {
            // encountering a lone "--" sigil means the rest of the args are positional
            if (std.mem.eql(u8, "--", os_arg)) {
                began_forced_positional = true;
                continue :next_os_arg;
            }

            if (std.mem.eql(u8, "--help", os_arg) or std.mem.eql(u8, "-h", os_arg)) {
                return .{ .kind = .help, .subcommand = result_subcommand };
            }

            // long args, like "--verbose"
            inline for (command.named_args) |arg| {
                const Value = switch (arg.count) {
                    .one => arg.type,
                    .unlimited => std.meta.Child(arg.type),
                };
                var value: union(enum) { found: Value, not_found } = .not_found;

                const long_token: []const u8 = "--" ++ arg.name; // like "--verbose"

                if (@typeInfo(Value) == .bool) {
                    const no_long_token: []const u8 = "--no-" ++ arg.name; // like "--no-verbose"

                    if (std.mem.eql(u8, os_arg, long_token)) {
                        value = .{ .found = true };
                    } else if (std.mem.eql(u8, os_arg, no_long_token)) {
                        value = .{ .found = false };
                    } else if (cutPrefixSentinel(u8, 0, os_arg, long_token ++ "=")) |suffix| {
                        value = .{ .found = try parseValue(options, Value, suffix) };
                    } else {
                        value = .not_found;
                    }
                } else {
                    if (std.mem.eql(u8, os_arg, long_token)) {
                        value = .{
                            .found = try parseValue(options, Value, iter.next() orelse return usageErrorExit(
                                options,
                                "Missing argument for option: {s}",
                                .{long_token},
                            )),
                        };
                    } else if (cutPrefixSentinel(u8, 0, os_arg, long_token ++ "=")) |suffix| {
                        value = .{ .found = try parseValue(options, Value, suffix) };
                    }
                }
                switch (value) {
                    .found => |found_value| {
                        switch (arg.count) {
                            .one => @field(result_args, arg.name) = found_value,
                            .unlimited => try @field(unlimited_args, arg.name).append(maybe_arena, found_value),
                        }
                        @field(defined, arg.name) = .defined;
                        continue :next_os_arg;
                    },
                    .not_found => {},
                }
            }

            // short clusters, like `-xvf` in `tar -xvf files.tar.gz`
            if (!std.mem.eql(u8, os_arg, "-") and
                std.mem.startsWith(u8, os_arg, "-") and
                !std.mem.startsWith(u8, os_arg, "--"))
            {
                const suffix = cutPrefixSentinel(u8, 0, os_arg, "-") orelse unreachable;
                assert(suffix.len > 0);

                next_char: for (suffix, 0..) |char, char_idx| {
                    const is_last: bool = char_idx + 1 == suffix.len;

                    inline for (command.named_args) |arg| {
                        const short = arg.short orelse continue;
                        if (char == short) {
                            const Value = switch (arg.count) {
                                .one => arg.type,
                                .unlimited => std.meta.Child(arg.type),
                            };

                            if (@typeInfo(Value) == .bool) {
                                switch (arg.count) {
                                    .one => @field(result_args, arg.name) = true,
                                    .unlimited => try @field(unlimited_args, arg.name).append(maybe_arena, true),
                                }
                                @field(defined, arg.name) = .defined;
                                continue :next_char;
                            } else {
                                if (!is_last) return usageErrorExit(options, "Short flag: {c} requires a value, so it must be in the last position of the short cluster: -{s}.", .{ short, suffix });
                                const value = try parseValue(options, Value, iter.next() orelse return usageErrorExit(options, "Missing argument for option: {c} in short cluster: -{s}", .{ short, suffix }));
                                switch (arg.count) {
                                    .one => @field(result_args, arg.name) = value,
                                    .unlimited => try @field(unlimited_args, arg.name).append(maybe_arena, value),
                                }
                                @field(defined, arg.name) = .defined;

                                assert(is_last);
                                continue :next_os_arg;
                            }
                        }
                    } else return usageErrorExit(options, "Invalid short flag: {c}", .{char});
                    comptime unreachable;
                }
                continue :next_os_arg;
            }

            inline for (command.subcommands) |subcommand| {
                if (std.mem.eql(u8, os_arg, @tagName(subcommand.name))) {
                    const U = std.meta.Child(@TypeOf(result_subcommand));
                    result_subcommand = @unionInit(U, @tagName(subcommand.name), try parseRecursive(subcommand, maybe_arena, iter, options));
                    continue :next_os_arg;
                }
            }
            // "-" is sometimes used as a positional argument to signify stdin, so it is allowed.
            // Otherwise the user is required to explicitly begin positional with sigil "--" if they want
            // to have a positional argument that begins with "-".
            if (std.mem.startsWith(u8, os_arg, "-") and !std.mem.eql(u8, os_arg, "-")) {
                return usageErrorExit(options, "unexpected argument: {s}", .{os_arg});
            }
        }
        inline for (command.positional_args, 0..) |arg, i| {
            if (i == positional_idx) {
                switch (arg.count) {
                    .one => {
                        const value = try parseValue(options, arg.type, os_arg);
                        @field(result_args, arg.name) = value;
                        @field(defined, arg.name) = .defined;
                        positional_idx += 1;
                        continue :next_os_arg;
                    },
                    .unlimited => {
                        comptime assert(i + 1 == command.positional_args.len); // unlimited positional must be last
                        // note: incrementing positional_idx during unlimited arg parsing is useless
                        const value = try parseValue(options, std.meta.Child(arg.type), os_arg);
                        try @field(unlimited_args, arg.name).append(maybe_arena, value);
                        @field(defined, arg.name) = .defined;

                        continue :next_os_arg;
                    },
                }
            }
        }

        return usageErrorExit(options, "unexpected argument: {s}", .{os_arg});
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(defined))) |arg_name| {
        switch (@field(defined, arg_name)) {
            .defined => {},
            .undefined => {
                inline for (command.named_args) |arg| {
                    if (comptime std.mem.eql(u8, arg.name, arg_name)) {
                        return usageErrorExit(options, "missing required named argument: {s}", .{"--" ++ arg.name});
                    }
                }
                inline for (command.positional_args) |arg| {
                    if (comptime std.mem.eql(u8, arg.name, arg_name)) {
                        return usageErrorExit(options, "missing required positional argument: {s}", .{arg.name});
                    }
                }
                comptime unreachable;
            },
        }
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(unlimited_args))) |field_name| {
        if (@field(unlimited_args, field_name).items.len > 0) {
            @field(result_args, field_name) = try @field(unlimited_args, field_name).toOwnedSlice(maybe_arena);
        }
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(defined))) |arg_name| {
        assert(@field(defined, arg_name) == .defined);
    }

    return .{
        .kind = .{ .args = result_args },
        .subcommand = result_subcommand,
    };
}

fn parseValue(options: ParseOptions, comptime T: type, buf: [:0]const u8) error{Usage}!T {
    switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, "true", buf)) return true;
            if (std.mem.eql(u8, "false", buf)) return false;
            if (std.mem.eql(u8, "1", buf)) return true;
            if (std.mem.eql(u8, "0", buf)) return false;
            return usageErrorExit(
                options,
                "Invalid input \"{s}\" for argument of type bool. Choose one of true|false|1|0.",
                .{buf},
            );
        },
        .int => return std.fmt.parseInt(T, buf, 0) catch return usageErrorExit(
            options,
            "Invalid input for argument of type {s}: {s}",
            .{ helpTypeName(T), buf },
        ),
        .float => return std.fmt.parseFloat(T, buf) catch return usageErrorExit(
            options,
            "Invalid input for argument of type {s}: {s}",
            .{ helpTypeName(T), buf },
        ),
        .pointer => |pointer| {
            switch (pointer.size) {
                .slice, .c, .many => {
                    if (pointer.child == u8) {
                        return buf;
                    } else comptime unreachable; // unsupported type for cli argument value parsing
                },
                else => comptime unreachable, // unsupported type for cli argument value parsing
            }
        },
        .@"enum" => return std.meta.stringToEnum(T, buf) orelse return usageErrorExit(
            options,
            "Invalid input \"{s}\". Choose one of {s}.",
            .{ buf, helpTypeName(T) },
        ),
        .optional => |info| return try parseValue(options, info.child, buf),
        else => comptime unreachable, // unsupported type for cli argument value parsing
    }
}

/// Intended to be very similar to parseValue.
/// Example: "integer" in these help lines:
///
/// ```
///   --retry [integer]
///     Retry requests n times.
/// ```
fn helpTypeName(comptime T: type) [:0]const u8 {
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => "integer",
        .float => "number",
        .pointer => |pointer| switch (pointer.size) {
            .slice, .c, .many => if (pointer.child == u8)
                "string"
            else
                comptime unreachable // unsupported type for cli argument value parsing
            ,
            else => comptime unreachable, // unsupported type for cli argument value parsing
        },
        .@"enum" => |info| blk: {
            comptime var s: [:0]const u8 = "";
            inline for (info.field_names, 0..) |field_name, i| {
                if (i == 0) {
                    s = s ++ field_name;
                    continue;
                }
                s = s ++ "|" ++ field_name;
            }
            break :blk s;
        },
        .optional => |info| return helpTypeName(info.child),
        else => comptime unreachable, // unsupported type for cli argument value parsing
    };
}

fn writeArgumentDefaultValue(comptime arg: Argument, out: *std.Io.Writer) std.Io.Writer.Error!void {
    const default_value = arg.attrs.defaultValue(arg.type) orelse comptime unreachable;
    switch (arg.count) {
        .one => {
            try out.writeAll(" ");
            try writeDefaultValue(@TypeOf(default_value), default_value, out);
        },
        .unlimited => {
            if (default_value.len > 0) {
                for (default_value) |v| {
                    try out.writeAll(" ");
                    try writeDefaultValue(@TypeOf(v), v, out);
                }
            } else try out.writeAll(" <empty>");
        },
    }
}

/// Intended to be very similar to parseValue.
/// Example: "3" in these help lines:
///
/// ```
///   --retry [integer]
///     Retry requests n times.
///     Default: 3
/// ```
fn writeDefaultValue(comptime T: type, value: T, out: *std.Io.Writer) std.Io.Writer.Error!void {
    return switch (@typeInfo(T)) {
        .bool, .int, .float => try out.print("{any}", .{value}),
        .pointer => |pointer| switch (pointer.size) {
            .slice, .c, .many => if (pointer.child == u8)
                try out.print("\"{s}\"", .{value})
            else
                comptime unreachable // unsupported type for cli argument value parsing
            ,
            else => comptime unreachable, // unsupported type for cli argument value parsing
        },
        .@"enum" => try out.writeAll(@tagName(value)),
        .optional => {
            comptime assert(value == null); // default value for optional args is always null
            try out.writeAll("null");
        },
        else => comptime unreachable, // unsupported type for cli argument value parsing
    };
}
