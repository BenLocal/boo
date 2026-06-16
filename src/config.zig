//! Startup configuration: a flat `key = value` file (a TOML subset).
//!
//! `Config.load` resolves a config path ($BOO_CONFIG, else
//! $XDG_CONFIG_HOME/boo/config.toml, else ~/.config/boo/config.toml),
//! reads it, and parses it into a typed `Config`. Parsing is lenient: an
//! unknown key, a malformed line, or a value of the wrong type is warned
//! about and skipped, so a typo never blocks startup. A missing file
//! yields defaults; only an unreadable explicit $BOO_CONFIG is fatal.

const std = @import("std");
const builtin = @import("builtin");

/// Scrollback budget in BYTES (not lines). ghostty-vt's
/// `Terminal.max_scrollback` is a byte budget rounded up to its page
/// size; 512 KiB matches the value boo hardcoded before this was
/// configurable.
pub const default_max_scrollback: usize = 512 * 1024;

/// Largest config file we will read.
const max_file_bytes: usize = 64 * 1024;

pub const Config = struct {
    max_scrollback: usize = default_max_scrollback,

    /// Owned backing buffer the parse borrowed from. Empty when no file
    /// was read; freed by `deinit`.
    source: []u8 = &.{},

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.source.len > 0) alloc.free(self.source);
        self.* = undefined;
    }

    const Presence = enum { required, optional };

    /// Resolve the config path and parse it. Order: $BOO_CONFIG, then
    /// $XDG_CONFIG_HOME/boo/config.toml, then $HOME/.config/boo/config.toml.
    /// A missing file at the XDG/HOME location yields defaults; an
    /// unreadable explicit $BOO_CONFIG is fatal.
    pub fn load(alloc: std.mem.Allocator) !Config {
        if (envNonEmpty("BOO_CONFIG")) |path| {
            return loadPath(alloc, path, .required);
        }
        if (envNonEmpty("XDG_CONFIG_HOME")) |base| {
            const path = try std.fs.path.join(alloc, &.{ base, "boo", "config.toml" });
            defer alloc.free(path);
            return loadPath(alloc, path, .optional);
        }
        if (envNonEmpty("HOME")) |home| {
            const path = try std.fs.path.join(alloc, &.{ home, ".config", "boo", "config.toml" });
            defer alloc.free(path);
            return loadPath(alloc, path, .optional);
        }
        return .{};
    }

    /// Read and parse a specific file. `optional` swallows a missing file
    /// (returns defaults); `required` propagates the error.
    fn loadPath(alloc: std.mem.Allocator, path: []const u8, presence: Presence) !Config {
        const bytes = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
            error.FileNotFound => return if (presence == .optional) .{} else err,
            else => return err,
        };
        return parseBytes(path, bytes);
    }

    /// Parse in-memory config bytes. Takes ownership of `bytes`: the
    /// returned Config keeps them as its backing buffer. `path` is used
    /// only to format warning messages.
    pub fn parseBytes(path: []const u8, bytes: []u8) Config {
        var cfg: Config = .{ .source = bytes };
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (line.len == 0) continue; // blank or comment-only
            if (line[0] == '[') continue; // [table] header — reserved for future use
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                warn(path, line_no, "ignored: expected 'key = value'", .{});
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "max_scrollback")) {
                cfg.max_scrollback = std.fmt.parseInt(usize, value, 10) catch {
                    warn(path, line_no, "key '{s}': expected a non-negative integer", .{key});
                    continue;
                };
            } else {
                warn(path, line_no, "ignored unknown key '{s}'", .{key});
            }
        }
        return cfg;
    }
};

fn envNonEmpty(name: []const u8) ?[]const u8 {
    const v = std.posix.getenv(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// Drop a trailing `# comment` from a line. Values here are integers, so
/// a literal `#` never appears inside one; a plain cut at the first `#`
/// is enough.
fn stripComment(line: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
}

fn warn(path: []const u8, line_no: usize, comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return; // keep `zig test` output pristine
    std.debug.print("boo: config {s}:{d}: ", .{ path, line_no });
    std.debug.print(fmt ++ "\n", args);
}

test "parseBytes: max_scrollback integer" {
    const alloc = std.testing.allocator;
    var cfg = Config.parseBytes("<test>", try alloc.dupe(u8, "max_scrollback = 33554432\n"));
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 33554432), cfg.max_scrollback);
}

test "parseBytes: empty input yields default" {
    const alloc = std.testing.allocator;
    var cfg = Config.parseBytes("<test>", try alloc.dupe(u8, ""));
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(default_max_scrollback, cfg.max_scrollback);
}

test "parseBytes: comments, blank lines, surrounding whitespace" {
    const alloc = std.testing.allocator;
    var cfg = Config.parseBytes("<test>", try alloc.dupe(u8,
        \\# scrollback budget in bytes
        \\
        \\   max_scrollback = 1048576   # 1 MiB
        \\
    ));
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1048576), cfg.max_scrollback);
}

test "parseBytes: lenient — unknown key, malformed line, bad value skipped" {
    const alloc = std.testing.allocator;
    var cfg = Config.parseBytes("<test>", try alloc.dupe(u8,
        \\bogus = 1
        \\no equals here
        \\max_scrollback = not_a_number
        \\
    ));
    defer cfg.deinit(alloc);
    // Every line is bad, so the default is retained.
    try std.testing.expectEqual(default_max_scrollback, cfg.max_scrollback);
}

test "parseBytes: section header skipped, later key still applies" {
    const alloc = std.testing.allocator;
    var cfg = Config.parseBytes("<test>", try alloc.dupe(u8,
        \\[general]
        \\max_scrollback = 42
        \\
    ));
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 42), cfg.max_scrollback);
}

test "loadPath: missing optional file -> defaults; present file parses; missing required -> error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const missing = try std.fs.path.join(alloc, &.{ base, "nope.toml" });
    defer alloc.free(missing);
    {
        var cfg = try Config.loadPath(alloc, missing, .optional);
        defer cfg.deinit(alloc);
        try std.testing.expectEqual(default_max_scrollback, cfg.max_scrollback);
    }

    try tmp.dir.writeFile(.{ .sub_path = "config.toml", .data = "max_scrollback = 4096\n" });
    const present = try std.fs.path.join(alloc, &.{ base, "config.toml" });
    defer alloc.free(present);
    {
        var cfg = try Config.loadPath(alloc, present, .optional);
        defer cfg.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 4096), cfg.max_scrollback);
    }

    try std.testing.expectError(error.FileNotFound, Config.loadPath(alloc, missing, .required));
}
