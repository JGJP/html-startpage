//! Caches resolved favicons back into the source YAML: for every link that
//! doesn't already declare an `icon:`, the data: URI fetched this run is written
//! in as `icon: "data:..."`. On the next build that link is skipped by the
//! fetcher (an explicit `icon:` wins) and baked directly, so nothing is fetched
//! twice. Only new lines are inserted — existing lines, order and comments are
//! left untouched.

const std = @import("std");
const favicon = @import("favicon.zig");

const Allocator = std.mem.Allocator;

/// Rewrites `path` in place, inserting `icon:` lines for links whose favicon was
/// resolved this run. Returns the number of icons written (0 = file unchanged,
/// nothing written).
pub fn cacheIcons(gpa: Allocator, io: std.Io, path: []const u8, favicons: *const favicon.Result) !usize {
    const dir = std.Io.Dir.cwd();
    const src = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(src);

    const result = try insertIcons(gpa, src, favicons);
    defer gpa.free(result.text);
    if (result.count == 0) return 0;

    try dir.writeFile(io, .{ .sub_path = path, .data = result.text });
    return result.count;
}

const Insertion = struct { text: []u8, count: usize };

/// Pure core of `cacheIcons`: returns a new YAML string with `icon:` lines added
/// (caller owns it) and how many were inserted. When nothing changes, `text` is
/// a copy of `src` and `count` is 0.
fn insertIcons(gpa: Allocator, src: []const u8, favicons: *const favicon.Result) !Insertion {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var count: usize = 0;

    for (lines.items, 0..) |line, idx| {
        try out.writer.writeAll(line);
        if (idx + 1 < lines.items.len) try out.writer.writeByte('\n');

        const key = keyOf(line) orelse continue;
        if (!std.mem.startsWith(u8, key.text, "url:") and !std.mem.startsWith(u8, key.text, "uri:")) continue;

        const value = scalarValue(key.text[3..]); // from the ':' onward
        if (value.len == 0) continue;
        const style = favicons.classOf(value) orelse continue;
        if (style >= favicons.styles.len) continue;
        if (itemHasIcon(lines.items, idx, key.indent)) continue;

        // Separate the icon line from the url line above (the url line only got
        // its own newline when it wasn't the file's last line), and terminate it
        // the same way — preserving whether the file ends in a trailing newline.
        if (idx + 1 >= lines.items.len) try out.writer.writeByte('\n');
        try out.writer.splatByteAll(' ', key.indent);
        try out.writer.print("icon: \"{s}\"", .{favicons.styles[style]});
        if (idx + 1 < lines.items.len) try out.writer.writeByte('\n');
        count += 1;
    }

    return .{ .text = try out.toOwnedSlice(), .count = count };
}

const Key = struct { indent: usize, text: []const u8 };

/// The mapping key on a line, with the column it sits at. Handles both a bare
/// key (`  url: x`) and the first key of a block-sequence item (`  - url: x`),
/// so the returned `indent` is where sibling keys of the same item align.
/// Returns null for blank lines and comments.
fn keyOf(line: []const u8) ?Key {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i < line.len and line[i] == '-' and i + 1 < line.len and line[i + 1] == ' ') {
        i += 1;
        while (i < line.len and line[i] == ' ') i += 1;
    }
    if (i >= line.len or line[i] == '#') return null;
    return .{ .indent = i, .text = line[i..] };
}

/// Extracts a scalar value, unquoting `"..."`/`'...'` and stripping a trailing
/// ` # comment` from a plain scalar.
fn scalarValue(after_colon: []const u8) []const u8 {
    const v = std.mem.trim(u8, after_colon[1..], " \t\r"); // skip the ':'
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
        if (std.mem.indexOfScalarPos(u8, v, 1, v[0])) |e| return v[1..e];
    }
    var end = v.len;
    if (std.mem.indexOf(u8, v, " #")) |h| end = h;
    return std.mem.trim(u8, v[0..end], " \t\r");
}

/// True if the block-mapping item containing the `url:` line at `url_idx`
/// already has a sibling `icon:` key (at column `indent`).
fn itemHasIcon(lines: []const []const u8, url_idx: usize, indent: usize) bool {
    var k = url_idx;
    while (k > 0) { // backward to the item's `- ` line (inclusive)
        k -= 1;
        if (siblingIcon(lines[k], indent)) |found| {
            if (found) return true;
        } else break; // dedent or item boundary
        if (isSeqItem(lines[k])) break;
    }
    k = url_idx + 1;
    while (k < lines.len) : (k += 1) { // forward until the next item / dedent
        if (isSeqItem(lines[k])) break;
        if (siblingIcon(lines[k], indent)) |found| {
            if (found) return true;
        } else break;
    }
    return false;
}

fn isSeqItem(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i < line.len and line[i] == '-' and i + 1 < line.len and line[i + 1] == ' ';
}

/// For a line belonging to the same item (a key at `indent`, or a blank/comment
/// line which is transparent), reports whether that key is `icon:`. Returns null
/// when the line is not part of the item (a shallower/deeper key).
fn siblingIcon(line: []const u8, indent: usize) ?bool {
    const key = keyOf(line) orelse return false; // blank/comment: transparent
    if (key.indent != indent) return null;
    return std.mem.startsWith(u8, key.text, "icon:");
}

// --- tests ---

const testing = std.testing;

fn fakeResult(map: *std.StringHashMapUnmanaged(usize), styles: []const []const u8) favicon.Result {
    return .{ .styles = styles, .index_of = map.* };
}

test "insertIcons: adds icon for a link that lacks one, skips those that have one" {
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "https://github.com", 0);
    try map.put(testing.allocator, "https://example.com", 0);
    const fav = fakeResult(&map, &.{"data:image/png;base64,AAAA"});

    const src =
        \\groups:
        \\  - title: dev
        \\    links:
        \\      - name: github
        \\        url: https://github.com
        \\      - name: custom
        \\        url: https://example.com
        \\        icon: "▶"
        \\
    ;
    const r = try insertIcons(testing.allocator, src, &fav);
    defer testing.allocator.free(r.text);

    try testing.expectEqual(@as(usize, 1), r.count);
    try testing.expect(std.mem.indexOf(u8, r.text, "        url: https://github.com\n        icon: \"data:image/png;base64,AAAA\"\n") != null);
    // the custom link already had an icon: no second data URI is written
    try testing.expect(std.mem.indexOf(u8, r.text, "data:image/png;base64,AAAA") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.text, "data:"));
    try testing.expect(std.mem.indexOf(u8, r.text, "icon: \"▶\"") != null);
}

test "insertIcons: no favicon for a url leaves the file untouched" {
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    defer map.deinit(testing.allocator);
    const fav = fakeResult(&map, &.{});

    const src =
        \\  - name: x
        \\    uri: https://unresolved.example
        \\
    ;
    const r = try insertIcons(testing.allocator, src, &fav);
    defer testing.allocator.free(r.text);
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expectEqualStrings(src, r.text);
}

test "insertIcons: uri alias and a trailing comment on the value" {
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "https://youtube.com", 0);
    const fav = fakeResult(&map, &.{"data:x"});

    const src = "      - name: yt\n        uri: https://youtube.com   # media\n";
    const r = try insertIcons(testing.allocator, src, &fav);
    defer testing.allocator.free(r.text);
    try testing.expectEqual(@as(usize, 1), r.count);
    try testing.expect(std.mem.indexOf(u8, r.text, "        icon: \"data:x\"\n") != null);
    // the comment on the uri line is preserved
    try testing.expect(std.mem.indexOf(u8, r.text, "# media") != null);
}

test scalarValue {
    try testing.expectEqualStrings("https://a", scalarValue(": https://a"));
    try testing.expectEqualStrings("https://a", scalarValue(": https://a   # c"));
    try testing.expectEqualStrings("https://a", scalarValue(": \"https://a\""));
    try testing.expectEqualStrings("https://a", scalarValue(": 'https://a'"));
}
