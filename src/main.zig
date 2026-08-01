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
    \\  startpage [options] [<config.yaml | dir> ...]
    \\
    \\With no path given, reads config/ (your real workspaces), falling back to
    \\examples/workspaces/ when config/ has no .yaml files.
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
    \\Workspaces: each input file is a separate workspace (a switchable page of
    \\links); on the page, the left/right arrow keys move between them. A directory
    \\argument is expanded to the *.yaml/*.yml files it contains, sorted by name, so
    \\dropping a new file into it adds a workspace. A leading order prefix in the
    \\file name (e.g. 01-work.yaml) sets the order without showing in the label.
    \\
    \\Config schema (per file):
    \\  title: my home                 # optional; the workspace label (default: file name)
    \\  lang: en                       # optional; document language (default "en"),
    \\                                 # taken from the first file that sets it
    \\  groups:
    \\    - title: dev                 # required per group
    \\      links:
    \\        - name: github           # required
    \\          url: https://github.com  # required
    \\          icon: https://.../x.png  # optional; image URL/data:/path used as-is,
    \\                                   # or a glyph like "▶". Skips favicon fetch.
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

    // With no path given, default to config/ (your real workspaces), falling
    // back to examples/workspaces/ when config/ has no config files.
    if (inputs.items.len == 0) {
        const def = defaultInput(io) orelse {
            try writeStdout(io, usage);
            std.log.err("no input given, and neither config/ nor examples/workspaces/ has any .yaml files", .{});
            return error.Reported;
        };
        try inputs.append(arena, def);
    }

    // Expand directory arguments into their sorted *.yaml/*.yml files, so each
    // resulting file is picked up as its own workspace.
    const files = try collectInputs(arena, io, inputs.items);
    if (files.len == 0) {
        std.log.err("no .yaml/.yml files found in the given input(s)", .{});
        return error.Reported;
    }

    const cfg = try config.load(gpa, arena, io, files);

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
        for (files) |path| {
            cached += writeback.cacheIcons(gpa, io, path, &favicons) catch |err| {
                std.log.warn("could not cache icons into '{s}': {s}", .{ path, @errorName(err) });
                continue;
            };
        }
    }

    // Success summary on stdout (stdout is otherwise unused when writing a file).
    const summary = try std.fmt.allocPrint(arena, "startpage: wrote {s} — {d} workspace(s), {d} group(s), {d} link(s), {d} favicon(s), {d} bytes; cached {d} icon(s) into source\n", .{
        output, cfg.workspaces.len, countGroups(cfg), countLinks(cfg), favicons.styles.len, html.len, cached,
    });
    try writeStdout(io, summary);
}

/// The directory used when no path is given: `config/` if it holds any config
/// files, otherwise `examples/workspaces/`, otherwise null (nothing to render).
fn defaultInput(io: std.Io) ?[]const u8 {
    if (dirHasYaml(io, "config")) return "config";
    if (dirHasYaml(io, "examples/workspaces")) return "examples/workspaces";
    return null;
}

fn dirHasYaml(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .directory and hasYamlExt(entry.name)) return true;
    }
    return false;
}

/// Expands each input path: a directory yields its `*.yaml`/`*.yml` files sorted
/// by name (each becomes a workspace); anything else is passed through as-is.
fn collectInputs(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const cwd = std.Io.Dir.cwd();

    for (args) |arg| {
        const stat = cwd.statFile(io, arg, .{}) catch {
            try out.append(arena, arg); // let the later read report a clear error
            continue;
        };
        if (stat.kind != .directory) {
            try out.append(arena, arg);
            continue;
        }

        var dir = cwd.openDir(io, arg, .{ .iterate = true }) catch |err| {
            std.log.err("cannot open directory '{s}': {s}", .{ arg, @errorName(err) });
            return error.Reported;
        };
        defer dir.close(io);

        const start = out.items.len;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!hasYamlExt(entry.name)) continue;
            const path = try std.fs.path.join(arena, &.{ arg, entry.name });
            try out.append(arena, path);
        }
        // Directory order is unspecified; sort so workspace order is stable.
        std.mem.sort([]const u8, out.items[start..], {}, lessThanStr);
    }

    return out.toOwnedSlice(arena);
}

fn hasYamlExt(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".yaml") or std.ascii.endsWithIgnoreCase(name, ".yml");
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn countGroups(cfg: config.Config) usize {
    var n: usize = 0;
    for (cfg.workspaces) |ws| n += ws.groups.len;
    return n;
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn countLinks(cfg: config.Config) usize {
    var n: usize = 0;
    for (cfg.workspaces) |ws| {
        for (ws.groups) |g| n += g.links.len;
    }
    return n;
}
