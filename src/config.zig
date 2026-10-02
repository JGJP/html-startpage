//! Config schema and loading. Each YAML input file becomes one **workspace** —
//! a self-contained set of `groups` shown as its own switchable page. A file's
//! workspace `title` is its `title:` field (or, if absent, its file name); the
//! document `lang` is taken from the first file that sets it.

const std = @import("std");
const yaml = @import("yaml");

const Allocator = std.mem.Allocator;

pub const Link = struct {
    name: []const u8,
    url: []const u8,
    /// Optional icon override. An image reference (URL, `data:` URI, or path) is
    /// used directly as the favicon; anything else is shown as a text glyph
    /// (e.g. "▶"). When set, no favicon is fetched for this link.
    icon: ?[]const u8 = null,
};

pub const Group = struct {
    title: []const u8,
    links: []const Link,
};

/// One city in the world-clock strip at the foot of the page. `tz` is an IANA
/// time-zone name (e.g. `Asia/Tokyo`); the clock itself is computed client-side,
/// so this carries only the zone and its display `label`.
pub const Clock = struct {
    tz: []const u8,
    label: []const u8,
};

/// One switchable page of links, contributed by a single input file.
pub const Workspace = struct {
    title: []const u8,
    groups: []const Group,
};

pub const Config = struct {
    lang: []const u8 = "en",
    workspaces: []const Workspace = &.{},
    clocks: []const Clock = &.{},
};

// --- YAML parse shapes (all optional so files may contribute only some parts) ---

const RawLink = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    /// Accepted as an alias for `url`.
    uri: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

const RawGroup = struct {
    title: []const u8,
    links: []const RawLink,
};

const RawClock = struct {
    tz: ?[]const u8 = null,
    /// Accepted as an alias for `tz`.
    timezone: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

const FileConfig = struct {
    title: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    groups: ?[]const RawGroup = null,
    clocks: ?[]const RawClock = null,
};

/// One file's contribution after `uri`/`url` normalization. `title` is already
/// resolved (the file's `title:` or a name derived from its path).
const Parsed = struct {
    title: []const u8,
    lang: ?[]const u8 = null,
    groups: []const Group = &.{},
    clocks: []const Clock = &.{},
};

const MergeError = error{NoGroups} || Allocator.Error;

/// Reads and merges every path in `paths`. Returned strings/slices are owned by
/// `arena`; `gpa` is used only for transient per-file allocations.
///
/// User-facing failures are logged here and returned as `error.Reported`, so the
/// caller can exit non-zero without printing a second message or a stack trace.
pub fn load(gpa: Allocator, arena: Allocator, io: std.Io, paths: []const []const u8) !Config {
    const dir = std.Io.Dir.cwd();

    var files: std.ArrayList(Parsed) = .empty;

    for (paths) |path| {
        const src = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| {
            std.log.err("cannot read '{s}': {s}", .{ path, @errorName(err) });
            return error.Reported;
        };
        defer gpa.free(src);

        var doc: yaml.Yaml = .{ .source = src };
        defer doc.deinit(gpa);

        doc.load(gpa) catch |err| {
            if (doc.parse_errors.errorMessageCount() > 0) {
                doc.parse_errors.renderToStderr(io, .{}, .auto) catch {};
            }
            std.log.err("could not parse YAML in '{s}': {s}", .{ path, @errorName(err) });
            return error.Reported;
        };

        // An empty / whitespace-only / comment-only file contributes nothing.
        if (doc.docs.items.len == 0) continue;
        if (doc.docs.items.len > 1) {
            std.log.err("'{s}' contains {d} YAML documents; use one document per file (remove '---' separators or split into separate inputs)", .{ path, doc.docs.items.len });
            return error.Reported;
        }

        const fc = doc.parse(arena, FileConfig) catch |err| {
            std.log.err("'{s}' does not match the expected schema ({s}); every group needs 'title' and 'links', and every link needs 'name' and 'url' (or 'uri')", .{ path, @errorName(err) });
            return error.Reported;
        };

        try files.append(arena, .{
            .title = fc.title orelse deriveTitle(path),
            .lang = fc.lang,
            .groups = try normalizeGroups(arena, path, fc.groups orelse &.{}),
            .clocks = try normalizeClocks(arena, path, fc.clocks orelse &.{}),
        });
    }

    return combine(arena, files.items) catch |err| switch (err) {
        error.NoGroups => {
            std.log.err("no groups found across {d} file(s); nothing to render", .{paths.len});
            return error.Reported;
        },
        else => |e| return e,
    };
}

/// A workspace name derived from a file path: its base name without extension,
/// minus an optional leading ordering prefix like `01-` or `02_` (which lets
/// file names control workspace order without appearing in the label).
fn deriveTitle(path: []const u8) []const u8 {
    var base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    var i: usize = 0;
    while (i < base.len and std.ascii.isDigit(base[i])) i += 1;
    if (i > 0 and i < base.len and (base[i] == '-' or base[i] == '_')) base = base[i + 1 ..];
    return if (base.len == 0) "startpage" else base;
}

/// Converts parsed raw groups into `Group`s, resolving each link's `url`/`uri`.
fn normalizeGroups(arena: Allocator, path: []const u8, raw_groups: []const RawGroup) ![]const Group {
    const groups = try arena.alloc(Group, raw_groups.len);
    for (raw_groups, 0..) |rg, gi| {
        const links = try arena.alloc(Link, rg.links.len);
        for (rg.links, 0..) |rl, li| {
            const url = rl.url orelse rl.uri orelse {
                std.log.err("'{s}': link '{s}' in group '{s}' has no 'url' (or 'uri')", .{ path, rl.name, rg.title });
                return error.Reported;
            };
            links[li] = .{ .name = rl.name, .url = url, .icon = rl.icon };
        }
        groups[gi] = .{ .title = rg.title, .links = links };
    }
    return groups;
}

/// Converts parsed raw clocks into `Clock`s, resolving each `tz`/`timezone` and
/// defaulting a missing `label` to the zone name.
fn normalizeClocks(arena: Allocator, path: []const u8, raw_clocks: []const RawClock) ![]const Clock {
    const clocks = try arena.alloc(Clock, raw_clocks.len);
    for (raw_clocks, 0..) |rc, i| {
        const tz = rc.tz orelse rc.timezone orelse {
            std.log.err("'{s}': a clock has no 'tz' (or 'timezone')", .{path});
            return error.Reported;
        };
        clocks[i] = .{ .tz = tz, .label = rc.label orelse tz };
    }
    return clocks;
}

/// Pure merge of already-parsed files (no I/O). Each file with at least one
/// group becomes a workspace, in file order; `lang` and the world-clock strip
/// are each taken from the first file that sets them. Exposed for unit testing.
fn combine(arena: Allocator, files: []const Parsed) MergeError!Config {
    var lang: []const u8 = "en";
    var lang_set = false;
    var clocks: []const Clock = &.{};
    var workspaces: std.ArrayList(Workspace) = .empty;

    for (files) |file| {
        if (file.lang) |l| {
            if (!lang_set) {
                lang = l;
                lang_set = true;
            }
        }
        if (clocks.len == 0 and file.clocks.len > 0) clocks = file.clocks;
        // A file that contributes no groups (empty/comment-only) adds no page.
        if (file.groups.len == 0) continue;
        try workspaces.append(arena, .{ .title = file.title, .groups = file.groups });
    }

    if (workspaces.items.len == 0) return error.NoGroups;

    return .{ .lang = lang, .workspaces = try workspaces.toOwnedSlice(arena), .clocks = clocks };
}

// --- tests ---

const testing = std.testing;

fn oneLinkGroup(title: []const u8) Group {
    return .{ .title = title, .links = &.{.{ .name = "n", .url = "https://e" }} };
}

test "combine: each file with groups becomes a workspace, in file order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Parsed{
        .{ .title = "work", .groups = &.{ oneLinkGroup("a"), oneLinkGroup("b") } },
        .{ .title = "home", .groups = &.{oneLinkGroup("c")} },
    };
    const cfg = try combine(arena, &files);
    try testing.expectEqual(@as(usize, 2), cfg.workspaces.len);
    try testing.expectEqualStrings("work", cfg.workspaces[0].title);
    try testing.expectEqual(@as(usize, 2), cfg.workspaces[0].groups.len);
    try testing.expectEqualStrings("home", cfg.workspaces[1].title);
    try testing.expectEqualStrings("c", cfg.workspaces[1].groups[0].title);
}

test "combine: lang comes from the first file that sets it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Parsed{
        .{ .title = "a", .groups = &.{oneLinkGroup("a")} }, // no lang
        .{ .title = "b", .lang = "ja", .groups = &.{oneLinkGroup("b")} },
        .{ .title = "c", .lang = "de", .groups = &.{oneLinkGroup("c")} }, // ignored
    };
    const cfg = try combine(arena, &files);
    try testing.expectEqualStrings("ja", cfg.lang);
    try testing.expectEqual(@as(usize, 3), cfg.workspaces.len);
}

test "combine: files without groups add no workspace; NoGroups when none do" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mixed = [_]Parsed{
        .{ .title = "empty" }, // no groups: contributes no page
        .{ .title = "real", .groups = &.{oneLinkGroup("only")} },
    };
    const cfg = try combine(arena, &mixed);
    try testing.expectEqualStrings("en", cfg.lang);
    try testing.expectEqual(@as(usize, 1), cfg.workspaces.len);
    try testing.expectEqualStrings("real", cfg.workspaces[0].title);

    const none = [_]Parsed{.{ .title = "t" }};
    try testing.expectError(error.NoGroups, combine(arena, &none));
}

test deriveTitle {
    try testing.expectEqualStrings("personal", deriveTitle("personal.yaml"));
    try testing.expectEqualStrings("startale", deriveTitle("examples/workspaces/00-startale.yaml"));
    try testing.expectEqualStrings("home_2", deriveTitle("home_2.yml")); // no leading digits: nothing stripped
    try testing.expectEqualStrings("work", deriveTitle("10_work.yaml"));
}

test "combine: clocks come from the first file that sets them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Parsed{
        .{ .title = "a", .groups = &.{oneLinkGroup("a")} }, // no clocks
        .{ .title = "b", .groups = &.{oneLinkGroup("b")}, .clocks = &.{.{ .tz = "Asia/Tokyo", .label = "Tokyo" }} },
        .{ .title = "c", .groups = &.{oneLinkGroup("c")}, .clocks = &.{.{ .tz = "Europe/Zagreb", .label = "Zagreb" }} }, // ignored
    };
    const cfg = try combine(arena, &files);
    try testing.expectEqual(@as(usize, 1), cfg.clocks.len);
    try testing.expectEqualStrings("Asia/Tokyo", cfg.clocks[0].tz);
    try testing.expectEqualStrings("Tokyo", cfg.clocks[0].label);
}

test "normalizeClocks: timezone is an alias for tz; label defaults to the zone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = [_]RawClock{
        .{ .tz = "America/Chicago", .label = "Austin" },
        .{ .timezone = "Europe/Zagreb" },
    };
    const clocks = try normalizeClocks(arena, "<test>", &raw);
    try testing.expectEqualStrings("America/Chicago", clocks[0].tz);
    try testing.expectEqualStrings("Austin", clocks[0].label);
    try testing.expectEqualStrings("Europe/Zagreb", clocks[1].tz);
    try testing.expectEqualStrings("Europe/Zagreb", clocks[1].label); // defaulted
}

test "normalizeGroups: uri is accepted as an alias for url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = [_]RawGroup{.{ .title = "g", .links = &.{
        .{ .name = "a", .url = "https://a" },
        .{ .name = "b", .uri = "https://b" },
    } }};
    const groups = try normalizeGroups(arena, "<test>", &raw);
    try testing.expectEqualStrings("https://a", groups[0].links[0].url);
    try testing.expectEqualStrings("https://b", groups[0].links[1].url);
}
