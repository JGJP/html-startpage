const std = @import("std");
const config = @import("config.zig");
const favicon = @import("favicon.zig");
const writeback = @import("writeback.zig");
const render = @import("render.zig").render;

// Silence zig-yaml's scoped .debug tokenizer logging; keep warnings/errors.
pub const std_options: std.Options = .{ .log_level = .warn };

// Pull sibling files' tests into `zig build test`.
test {
    _ = @import("config.zig");
    _ = @import("render.zig");
    _ = @import("favicon.zig");
    _ = @import("writeback.zig");
}

const usage =
    \\startpage — generate a single self-contained HTML startpage from YAML.
    \\
    \\Usage:
    \\  startpage [options] <config.yaml> [more.yaml ...]
    \\
    \\Options:
    \\  -o, --output <file>   Write HTML to <file> (default: startpage.html).
    \\                        Use "-" to write to stdout.
    \\      --no-favicons     Do not fetch and bake site favicons.
    \\      --no-background   Do not add the rotating photo background.
    \\      --no-cache-icons  Do not write resolved favicons back into the source
    \\                        YAML (by default they are cached so links with a
    \\                        found favicon aren't refetched on the next build).
    \\  -h, --help            Show this help and exit.
    \\
    \\Favicons: by default each link's favicon is fetched once (preferring the
    \\site's dark-mode/SVG icon) and embedded inline as a data: URI. Links with an
    \\explicit 'icon:' glyph, non-http(s) URLs, and sites without a favicon are
    \\left without an image.
    \\
    \\Background: by default the page shows an auto-rotating photo background loaded
    \\from Unsplash at view time (the only thing the generated file fetches). Use
    \\--no-background for a plain black page with no external requests.
    \\
    \\Config schema (per file):
    \\  title: my home                 # optional; taken from the first file that sets it
    \\  lang: en                       # optional; document language (default "en")
    \\  groups:
    \\    - title: dev                 # required per group
    \\      links:
    \\        - name: github           # required
    \\          url: https://github.com  # required
    \\          icon: https://.../x.png  # optional; image URL/data:/path used as-is,
    \\                                   # or a glyph like "▶". Skips favicon fetch.
    \\
    \\Groups from every file are concatenated in the order given.
    \\
;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        // Expected failures are already reported with context via error.Reported.
        if (err != error.Reported) std.log.err("unexpected error: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);

    var inputs: std.ArrayList([]const u8) = .empty;
    var output: []const u8 = "startpage.html";
    var fetch_favicons = true;
    var with_background = true;
    var cache_icons = true;

    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try writeStdout(io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "--no-favicons")) {
            fetch_favicons = false;
        } else if (std.mem.eql(u8, arg, "--no-background")) {
            with_background = false;
        } else if (std.mem.eql(u8, arg, "--no-cache-icons")) {
            cache_icons = false;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) {
                std.log.err("missing filename after {s}", .{arg});
                return error.Reported;
            }
            output = argv[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            std.log.err("unknown option: {s}", .{arg});
            return error.Reported;
        } else {
            try inputs.append(arena, arg);
        }
    }

    if (inputs.items.len == 0) {
        try writeStdout(io, usage);
        return error.Reported;
    }

    const cfg = try config.load(gpa, arena, io, inputs.items);

    var favicons: favicon.Result = .{};
    if (fetch_favicons) favicons = favicon.resolve(gpa, arena, io, cfg);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(&out.writer, cfg, if (fetch_favicons) &favicons else null, with_background);
    const html = out.written();

    if (std.mem.eql(u8, output, "-")) {
        try std.Io.File.stdout().writeStreamingAll(io, html);
        return;
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = html }) catch |err| {
        std.log.err("cannot write '{s}': {s}", .{ output, @errorName(err) });
        return error.Reported;
    };

    // Cache resolved favicons back into the source YAML so they aren't refetched
    // next build. Non-fatal: a file we can't rewrite just isn't cached.
    var cached: usize = 0;
    if (fetch_favicons and cache_icons) {
        for (inputs.items) |path| {
            cached += writeback.cacheIcons(gpa, io, path, &favicons) catch |err| {
                std.log.warn("could not cache icons into '{s}': {s}", .{ path, @errorName(err) });
                continue;
            };
        }
    }

    // Success summary on stdout (stdout is otherwise unused when writing a file).
    const summary = try std.fmt.allocPrint(arena, "startpage: wrote {s} — {d} group(s), {d} link(s), {d} favicon(s), {d} bytes; cached {d} icon(s) into source\n", .{
        output, cfg.groups.len, countLinks(cfg), favicons.styles.len, html.len, cached,
    });
    try writeStdout(io, summary);
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn countLinks(cfg: config.Config) usize {
    var n: usize = 0;
    for (cfg.groups) |g| n += g.links.len;
    return n;
}
