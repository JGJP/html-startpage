//! Config schema and loading. Each YAML input file is parsed and merged into a
//! single `Config`: `title` and `lang` are taken from the first file that sets
//! them, and every file's `groups` are concatenated in the order given.

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

pub const Config = struct {
    title: []const u8 = "startpage",
    lang: []const u8 = "en",
    groups: []const Group = &.{},
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

const FileConfig = struct {
    title: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    groups: ?[]const RawGroup = null,
};

/// One file's contribution after `uri`/`url` normalization.
const Parsed = struct {
    title: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    groups: []const Group = &.{},
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
            .title = fc.title,
            .lang = fc.lang,
            .groups = try normalizeGroups(arena, path, fc.groups orelse &.{}),
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

/// Pure merge of already-parsed files (no I/O). Exposed for unit testing.
fn combine(arena: Allocator, files: []const Parsed) MergeError!Config {
    var title: []const u8 = "startpage";
    var title_set = false;
    var lang: []const u8 = "en";
    var lang_set = false;
    var groups: std.ArrayList(Group) = .empty;

    for (files) |file| {
        if (file.title) |t| {
            if (!title_set) {
                title = t;
                title_set = true;
            }
        }
        if (file.lang) |l| {
            if (!lang_set) {
                lang = l;
                lang_set = true;
            }
        }
        try groups.appendSlice(arena, file.groups);
    }

    if (groups.items.len == 0) return error.NoGroups;

    return .{ .title = title, .lang = lang, .groups = try groups.toOwnedSlice(arena) };
}

// --- tests ---

const testing = std.testing;

fn oneLinkGroup(title: []const u8) Group {
    return .{ .title = title, .links = &.{.{ .name = "n", .url = "https://e" }} };
}

test "combine: title and lang come from the first file that sets them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Parsed{
        .{ .groups = &.{oneLinkGroup("a")} }, // no title/lang
        .{ .title = "second", .lang = "ja", .groups = &.{oneLinkGroup("b")} },
        .{ .title = "third", .lang = "de" }, // ignored: already set
    };
    const cfg = try combine(arena, &files);
    try testing.expectEqualStrings("second", cfg.title);
    try testing.expectEqualStrings("ja", cfg.lang);
}

test "combine: groups concatenate in file order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Parsed{
        .{ .groups = &.{ oneLinkGroup("a"), oneLinkGroup("b") } },
        .{ .groups = &.{oneLinkGroup("c")} },
    };
    const cfg = try combine(arena, &files);
    try testing.expectEqual(@as(usize, 3), cfg.groups.len);
    try testing.expectEqualStrings("a", cfg.groups[0].title);
    try testing.expectEqualStrings("b", cfg.groups[1].title);
    try testing.expectEqualStrings("c", cfg.groups[2].title);
}

test "combine: defaults apply and NoGroups is returned when nothing contributes groups" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_groups = [_]Parsed{.{ .groups = &.{oneLinkGroup("only")} }};
    const cfg = try combine(arena, &with_groups);
    try testing.expectEqualStrings("startpage", cfg.title);
    try testing.expectEqualStrings("en", cfg.lang);

    const no_groups = [_]Parsed{.{ .title = "t" }}; // title but no groups
    try testing.expectError(error.NoGroups, combine(arena, &no_groups));
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
