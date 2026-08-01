//! Fetches each site's favicon at generation time and returns them as inline
//! `data:` URIs, deduplicated per host and per identical icon.
//!
//! To get an icon that reads well on a dark page, each host is resolved by:
//!   1. fetching the homepage and picking the best declared `<link rel=icon>`
//!      (preferring SVG / `media=dark` icons),
//!   2. trying that icon's `-dark` sibling (e.g. `favicon.svg` -> `favicon-dark.svg`),
//!   3. falling back to `<host>/favicon.ico`.
//!
//! Never fatal: unreachable hosts or hosts without a usable icon are omitted.
//! Only `http`/`https` links are fetched; links with an explicit `icon:` glyph
//! are skipped (the glyph wins).

const std = @import("std");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const StringMap = std.StringHashMapUnmanaged;

pub const Result = struct {
    /// Unique data: URIs. The CSS class for entry `i` is `fav-<i>`.
    styles: []const []const u8 = &.{},
    /// Maps a link's `url` to its index into `styles`.
    index_of: StringMap(usize) = .empty,

    pub fn classOf(self: *const Result, url: []const u8) ?usize {
        return self.index_of.get(url);
    }
};

const max_icon_bytes = 256 * 1024;
const max_html_bytes = 3 * 1024 * 1024;
const read_buffer_size = 64 * 1024; // 8 KiB default is far too small for slow hosts
const user_agent = "Mozilla/5.0 (compatible; startpage/0.1; +https://github.com)";

pub fn resolve(gpa: Allocator, arena: Allocator, io: std.Io, cfg: config.Config) Result {
    var client: std.http.Client = .{ .allocator = gpa, .io = io, .read_buffer_size = read_buffer_size };
    defer client.deinit();

    var by_host: StringMap(?[]const u8) = .empty; // "scheme://authority" -> data URI or null
    defer {
        var it = by_host.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        by_host.deinit(gpa);
    }

    var styles: std.ArrayList([]const u8) = .empty;
    var uri_index: StringMap(usize) = .empty; // data URI -> index into styles (dedup identical icons)
    defer uri_index.deinit(gpa);
    var index_of: StringMap(usize) = .empty;

    for (cfg.workspaces) |ws| {
        for (ws.groups) |group| {
            for (group.links) |link| {
                if (link.icon != null) continue; // explicit glyph overrides the favicon
                const uri = hostFavicon(gpa, arena, &client, &by_host, link.url) orelse continue;

                const idx = uri_index.get(uri) orelse blk: {
                    const i = styles.items.len;
                    styles.append(arena, uri) catch continue;
                    uri_index.put(gpa, uri, i) catch {};
                    break :blk i;
                };
                index_of.put(arena, link.url, idx) catch {};
            }
        }
    }

    return .{ .styles = styles.toOwnedSlice(arena) catch styles.items, .index_of = index_of };
}

fn hostFavicon(
    gpa: Allocator,
    arena: Allocator,
    client: *std.http.Client,
    by_host: *StringMap(?[]const u8),
    url: []const u8,
) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;

    const host = componentText(uri.host orelse return null);
    if (host.len == 0) return null;

    var abuf: [1024]u8 = undefined;
    const authority = if (uri.port) |port|
        std.fmt.bufPrint(&abuf, "{s}:{d}", .{ host, port }) catch return null
    else
        host;

    var kbuf: [1100]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "{s}://{s}", .{ uri.scheme, authority }) catch return null;

    if (by_host.get(key)) |cached| return cached;

    const result = resolveForBase(gpa, arena, client, uri.scheme, authority);
    const owned_key = gpa.dupe(u8, key) catch return result;
    by_host.put(gpa, owned_key, result) catch gpa.free(owned_key);
    return result;
}

fn resolveForBase(gpa: Allocator, arena: Allocator, client: *std.http.Client, scheme: []const u8, authority: []const u8) ?[]const u8 {
    var buf: [1200]u8 = undefined;

    // 1) Parse the homepage for a good (ideally dark/SVG) declared icon.
    const home = std.fmt.bufPrint(&buf, "{s}://{s}/", .{ scheme, authority }) catch return null;
    if (fetchBytes(gpa, client, home, max_html_bytes)) |html| {
        defer gpa.free(html);
        if (pickIconHref(gpa, html, scheme, authority)) |href| {
            defer gpa.free(href);
            if (darkVariant(gpa, href)) |dark| {
                defer gpa.free(dark);
                if (fetchIconUri(gpa, arena, client, dark)) |uri| return uri;
            }
            if (fetchIconUri(gpa, arena, client, href)) |uri| return uri;
        }
    }

    // 2) Fallback: the classic /favicon.ico.
    const fav = std.fmt.bufPrint(&buf, "{s}://{s}/favicon.ico", .{ scheme, authority }) catch return null;
    return fetchIconUri(gpa, arena, client, fav);
}

/// Fetches a URL body into a gpa-owned slice (caller frees). Returns null on any
/// error, non-200 status, empty body, or a body larger than `max`.
fn fetchBytes(gpa: Allocator, client: *std.http.Client, url: []const u8, max: usize) ?[]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch return null;

    if (res.status != .ok and res.status != .partial_content) return null;
    const bytes = body.written();
    if (bytes.len == 0 or bytes.len > max) return null;
    return gpa.dupe(u8, bytes) catch null;
}

fn fetchIconUri(gpa: Allocator, arena: Allocator, client: *std.http.Client, url: []const u8) ?[]const u8 {
    const bytes = fetchBytes(gpa, client, url, max_icon_bytes) orelse return null;
    defer gpa.free(bytes);
    const mime = sniff(bytes) orelse return null;
    return encodeDataUri(arena, mime, bytes) catch null;
}

/// Picks the best `<link rel=icon>` href from HTML, resolved to an absolute URL
/// (gpa-owned). Prefers SVG and `media=dark` icons.
fn pickIconHref(gpa: Allocator, html: []const u8, scheme: []const u8, authority: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null; // slice into html
    var best_score: i32 = -1;

    var pos: usize = 0;
    while (indexOfIgnoreCasePos(html, pos, "<link")) |start| {
        const gt = std.mem.indexOfScalarPos(u8, html, start, '>') orelse break;
        const tag = html[start..gt];
        pos = gt + 1;

        const rel = getAttr(tag, "rel") orelse continue;
        if (!containsIgnoreCase(rel, "icon")) continue;
        if (containsIgnoreCase(rel, "mask-icon")) continue; // monochrome tint target, not a real icon
        const href = getAttr(tag, "href") orelse continue;
        if (href.len == 0) continue;

        var score: i32 = 0;
        if (getAttr(tag, "type")) |t| {
            if (containsIgnoreCase(t, "svg")) score += 100;
        }
        if (endsWithIgnoreCase(stripQuery(href), ".svg")) score += 100;
        if (getAttr(tag, "media")) |m| {
            if (containsIgnoreCase(m, "dark")) score += 60;
        }
        if (containsIgnoreCase(rel, "apple-touch")) score += 25;
        if (getAttr(tag, "sizes")) |s| score += sizeBonus(s);

        if (score > best_score) {
            best_score = score;
            best = href;
        }
    }

    const href = best orelse return null;
    return resolveHref(gpa, scheme, authority, href);
}

/// Builds the `-dark` sibling of an SVG/PNG icon URL (gpa-owned), or null.
fn darkVariant(gpa: Allocator, url: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path = url[0..q];
    if (!endsWithIgnoreCase(path, ".svg") and !endsWithIgnoreCase(path, ".png")) return null;
    if (containsIgnoreCase(path, "-dark")) return null;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    return std.fmt.allocPrint(gpa, "{s}-dark{s}{s}", .{ path[0..dot], path[dot..], url[q..] }) catch null;
}

fn resolveHref(gpa: Allocator, scheme: []const u8, authority: []const u8, href: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(href, "http://") or std.ascii.startsWithIgnoreCase(href, "https://"))
        return gpa.dupe(u8, href) catch null;
    if (std.mem.startsWith(u8, href, "//"))
        return std.fmt.allocPrint(gpa, "{s}:{s}", .{ scheme, href }) catch null;
    if (std.mem.startsWith(u8, href, "/"))
        return std.fmt.allocPrint(gpa, "{s}://{s}{s}", .{ scheme, authority, href }) catch null;
    return std.fmt.allocPrint(gpa, "{s}://{s}/{s}", .{ scheme, authority, href }) catch null;
}

/// Reads the value of `name="..."` (or `name='...'` or unquoted) from a tag,
/// requiring the attribute name to be at a token boundary.
fn getAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (indexOfIgnoreCasePos(tag, i, name)) |p| {
        i = p + name.len;
        if (p == 0 or !isSpace(tag[p - 1])) continue;

        var j = i;
        while (j < tag.len and isSpace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and isSpace(tag[j])) j += 1;
        if (j >= tag.len) return null;

        const c = tag[j];
        if (c == '"' or c == '\'') {
            const e = std.mem.indexOfScalarPos(u8, tag, j + 1, c) orelse return null;
            return tag[j + 1 .. e];
        }
        var e = j;
        while (e < tag.len and !isSpace(tag[e])) e += 1;
        return tag[j..e];
    }
    return null;
}

fn sizeBonus(sizes: []const u8) i32 {
    var n: i32 = 0;
    for (sizes) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(i32, c - '0');
            if (n >= 512) break;
        } else if (n != 0) break;
    }
    return @min(n, 512) >> 5; // up to +16 for large icons
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn stripQuery(u: []const u8) []const u8 {
    return u[0 .. std.mem.indexOfScalar(u8, u, '?') orelse u.len];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCasePos(haystack, 0, needle) != null;
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    return haystack.len >= suffix.len and std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn componentText(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}

/// Detects the image type from magic bytes, returning the MIME type or null if
/// the bytes are not a recognized image (e.g. an HTML error page).
fn sniff(b: []const u8) ?[]const u8 {
    if (b.len >= 4 and std.mem.eql(u8, b[0..4], &[_]u8{ 0, 0, 1, 0 })) return "image/x-icon";
    if (b.len >= 4 and std.mem.eql(u8, b[0..4], &[_]u8{ 0x89, 'P', 'N', 'G' })) return "image/png";
    if (b.len >= 4 and std.mem.eql(u8, b[0..4], "GIF8")) return "image/gif";
    if (b.len >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF) return "image/jpeg";
    if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return "image/webp";
    if (b.len >= 2 and std.mem.eql(u8, b[0..2], "BM")) return "image/bmp";
    if (looksLikeSvg(b)) return "image/svg+xml";
    return null;
}

fn looksLikeSvg(b: []const u8) bool {
    const n = @min(b.len, 256);
    var lower: [256]u8 = undefined;
    for (b[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, lower[0..n], "<svg") != null;
}

fn encodeDataUri(arena: Allocator, mime: []const u8, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const prefix = "data:";
    const mid = ";base64,";
    const total = prefix.len + mime.len + mid.len + enc.calcSize(bytes.len);

    const out = try arena.alloc(u8, total);
    var i: usize = 0;
    @memcpy(out[i..][0..prefix.len], prefix);
    i += prefix.len;
    @memcpy(out[i..][0..mime.len], mime);
    i += mime.len;
    @memcpy(out[i..][0..mid.len], mid);
    i += mid.len;
    _ = enc.encode(out[i..], bytes);
    return out;
}

// --- tests ---

const testing = std.testing;

test sniff {
    try testing.expectEqualStrings("image/x-icon", sniff(&[_]u8{ 0, 0, 1, 0, 9, 9 }).?);
    try testing.expectEqualStrings("image/png", sniff(&[_]u8{ 0x89, 'P', 'N', 'G', 1, 2 }).?);
    try testing.expectEqualStrings("image/svg+xml", sniff("<svg xmlns='...'></svg>").?);
    try testing.expect(sniff("<!doctype html><html>404</html>") == null);
    try testing.expect(sniff("xx") == null);
}

test encodeDataUri {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const uri = try encodeDataUri(arena_state.allocator(), "image/png", "hello");
    try testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", uri);
}

test getAttr {
    const tag = "<link rel=\"icon\" type='image/svg+xml' href=/favicon.svg sizes=32x32";
    try testing.expectEqualStrings("icon", getAttr(tag, "rel").?);
    try testing.expectEqualStrings("image/svg+xml", getAttr(tag, "type").?);
    try testing.expectEqualStrings("/favicon.svg", getAttr(tag, "href").?);
    try testing.expectEqualStrings("32x32", getAttr(tag, "sizes").?);
    try testing.expect(getAttr(tag, "media") == null);
}

test "pickIconHref prefers svg and resolves relative urls" {
    const html =
        "<html><head>" ++
        "<link rel=\"icon\" href=\"/favicon.ico\">" ++
        "<link rel=\"icon\" type=\"image/svg+xml\" href=\"https://cdn.x/favicon.svg\">" ++
        "</head></html>";
    const href = pickIconHref(testing.allocator, html, "https", "x.com").?;
    defer testing.allocator.free(href);
    try testing.expectEqualStrings("https://cdn.x/favicon.svg", href);
}

test darkVariant {
    const d = darkVariant(testing.allocator, "https://cdn.x/favicon.svg").?;
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("https://cdn.x/favicon-dark.svg", d);
    try testing.expect(darkVariant(testing.allocator, "https://x/favicon.ico") == null);
}
