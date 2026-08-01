//! Renders a `Config` into a single HTML document: a scrollable black column of
//! links (with inline, deduplicated favicons) over an auto-rotating photo
//! background (Bonjourr-style, loaded from Unsplash at view time).

const std = @import("std");
const config = @import("config.zig");
const favicon = @import("favicon.zig");
const Config = config.Config;

const Writer = std.Io.Writer;

// Inline SVG favicon (an accent block) for the browser tab.
const page_icon =
    "<link rel=\"icon\" href=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3' fill='%230c0c0f'/%3E%3Crect x='4' y='3' width='3' height='10' fill='%238be9c8'/%3E%3C/svg%3E\">\n";

// Curated Unsplash photos (scenic, Bonjourr-style). Rotated client-side.
const backgrounds = [_][]const u8{
    "https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1470071459604-3b5ec3a7fe05?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1441974231531-c6227db76b6e?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1470252649378-9c29740c9fa8?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1501785888041-af3ef285b470?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1439853949127-fa647821eba0?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1472214103451-9374bd1c798e?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1519681393784-d120267933ba?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1454496522488-7a8e488e8606?w=2400&q=80&auto=format&fit=crop",
    "https://images.unsplash.com/photo-1426604966848-d7adac402bff?w=2400&q=80&auto=format&fit=crop",
};

const css =
    \\:root {
    \\  --fg: #e7e7ec;
    \\  --muted: #9a9aa8;
    \\  --accent: #8be9c8;
    \\  --mono: "Berkeley Mono", ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
    \\}
    \\* { box-sizing: border-box; }
    \\html, body { margin: 0; }
    \\body {
    \\  min-height: 100vh;
    \\  background: #000;
    \\  color: var(--fg);
    \\  font-family: var(--mono);
    \\  font-size: 14px;
    \\  line-height: 1.9;
    \\  -webkit-font-smoothing: antialiased;
    \\  text-rendering: optimizeLegibility;
    \\}
    \\.bg {
    \\  position: fixed;
    \\  inset: 0;
    \\  background-size: cover;
    \\  background-position: center;
    \\  z-index: -1;
    \\}
    \\.page {
    \\  width: fit-content;
    \\  margin: 0 0 0 auto;
    \\  min-height: 100vh;
    \\  background: #000;
    \\  padding: clamp(30px, 7vw, 72px) clamp(22px, 5vw, 40px);
    \\  padding-right: clamp(36px, 6vw, 60px);
    \\}
    \\.masthead { margin: 0 0 2.4rem; }
    \\.masthead h1 {
    \\  margin: 0;
    \\  font-size: 0.8rem;
    \\  font-weight: 400;
    \\  letter-spacing: 0.05em;
    \\  color: var(--muted);
    \\  white-space: nowrap;
    \\}
    \\.masthead h1.filtering { color: var(--accent); }
    \\.masthead h1.filtering::after { content: "▏"; }
    \\.group { margin: 0 0 2rem; }
    \\.group:last-child { margin-bottom: 0; }
    \\.group h2 {
    \\  margin: 0 0 0.7rem;
    \\  font-size: 0.68rem;
    \\  font-weight: 500;
    \\  text-transform: uppercase;
    \\  letter-spacing: 0.2em;
    \\  color: var(--muted);
    \\}
    \\.group ul { list-style: none; margin: 0; padding: 0; }
    \\.group li { margin: 0; }
    \\.group a {
    \\  display: flex;
    \\  align-items: center;
    \\  gap: 0.75ch;
    \\  padding: 0.12rem 0;
    \\  color: var(--fg);
    \\  text-decoration: none;
    \\  transition: color 0.12s ease;
    \\}
    \\.group a:hover,
    \\.group a:focus-visible,
    \\.group a.active {
    \\  color: var(--accent);
    \\  text-decoration: underline;
    \\  text-underline-offset: 3px;
    \\  text-decoration-thickness: 1px;
    \\  outline: none;
    \\}
    \\.slot { width: 16px; min-width: 16px; flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center; }
    \\.slot.glyph { color: var(--muted); }
    \\.group a:hover .slot.glyph,
    \\.group a:focus-visible .slot.glyph,
    \\.group a.active .slot.glyph { color: var(--accent); }
    \\.favicon { width: 16px; height: 16px; border-radius: 3px; background-size: contain; background-repeat: no-repeat; background-position: center; }
    \\.favimg { width: 16px; height: 16px; border-radius: 3px; object-fit: contain; }
    \\.name { white-space: nowrap; }
    \\.compose {
    \\  position: fixed;
    \\  top: 50%;
    \\  left: 50%;
    \\  transform: translate(-50%, -50%);
    \\  max-width: 80vw;
    \\  padding: clamp(22px, 5vw, 40px);
    \\  background: #000;
    \\  color: var(--fg);
    \\  white-space: pre-wrap;
    \\  overflow-wrap: anywhere;
    \\  z-index: 10;
    \\  display: none;
    \\}
    \\.compose.show { display: block; }
    \\.compose::after { content: "▏"; color: var(--accent); }
    \\@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
    \\
;

pub fn render(w: *Writer, cfg: Config, favicons: ?*const favicon.Result, with_background: bool) Writer.Error!void {
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"");
    try writeEscaped(w, cfg.lang);
    try w.writeAll(
        \\">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<meta name="color-scheme" content="dark">
        \\
    );
    try w.writeAll(page_icon);
    try w.writeAll("<title>");
    try writeEscaped(w, cfg.title);
    try w.writeAll("</title>\n<style>\n");
    try w.writeAll(css);
    if (favicons) |fav| {
        // One rule per unique icon; base64 data URIs contain no CSS-breaking chars.
        for (fav.styles, 0..) |data_uri, i| {
            try w.print(".fav-{d}{{background-image:url(\"{s}\")}}\n", .{ i, data_uri });
        }
    }
    try w.writeAll(
        \\</style>
        \\</head>
        \\<body>
        \\
    );

    if (with_background) try w.writeAll("<div class=\"bg\" id=\"bg\"></div>\n");

    try w.writeAll("<main class=\"page\">\n<header class=\"masthead\"><h1>");
    try writeEscaped(w, cfg.title);
    try w.writeAll("</h1></header>\n");

    for (cfg.groups) |group| {
        if (group.links.len == 0) continue; // no orphan headings
        try w.writeAll("<section class=\"group\">\n<h2>");
        try writeEscaped(w, group.title);
        try w.writeAll("</h2>\n<ul>\n");
        for (group.links) |link| {
            try w.writeAll("<li><a href=\"");
            try writeEscaped(w, link.url);
            try w.writeAll("\">");
            try writeSlot(w, link, favicons);
            try w.writeAll("<span class=\"name\">");
            try writeEscaped(w, link.name);
            try w.writeAll("</span></a></li>\n");
        }
        try w.writeAll("</ul>\n</section>\n");
    }

    try w.writeAll("</main>\n");
    try w.writeAll("<div class=\"compose\" id=\"compose\"></div>\n");
    try writeScript(w, with_background);
    try w.writeAll("</body>\n</html>\n");
}

/// Emits the page's client-side script: (optionally) a random background chosen
/// on load, plus keyboard navigation. Typing pops a centered compose box; Tab
/// transfers the query into the link filter, where up/down move the highlight,
/// Enter opens it, and Esc/Backspace edit or dismiss the query.
fn writeScript(w: *Writer, with_background: bool) Writer.Error!void {
    try w.writeAll("<script>\n(function(){\n");

    if (with_background) {
        try w.writeAll("var I=[");
        for (backgrounds, 0..) |url, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(url); // curated URLs contain no quotes or </script>
            try w.writeAll("\"");
        }
        try w.writeAll("];\ndocument.getElementById(\"bg\").style.backgroundImage='url(\"'+I[Math.floor(Math.random()*I.length)]+'\")';\n");
    }

    try w.writeAll(
        \\var A=[].slice.call(document.querySelectorAll(".group a"));
        \\A.forEach(function(a){a._n=(a.querySelector(".name")||a).textContent.toLowerCase();});
        \\var G=[].slice.call(document.querySelectorAll(".group"));
        \\var mh=document.querySelector(".masthead h1"),title=mh?mh.textContent:"";
        \\var box=document.getElementById("compose");
        \\var page=document.querySelector(".page");if(page)page.style.minWidth=page.getBoundingClientRect().width+"px";
        \\var q="",c="",composing=false,filtering=false,vis=A.slice(),i=-1;
        \\function highlight(){A.forEach(function(a){a.classList.remove("active");});if(i>=0&&vis[i]){vis[i].classList.add("active");vis[i].scrollIntoView({block:"nearest"});}}
        \\function filter(){var ql=q.toLowerCase();vis=[];A.forEach(function(a){var s=a._n.indexOf(ql)!==-1;a.parentNode.style.display=s?"":"none";if(s)vis.push(a);});G.forEach(function(g){var any=[].slice.call(g.querySelectorAll("a")).some(function(a){return a.parentNode.style.display!=="none";});g.style.display=any?"":"none";});if(mh){mh.textContent=q||title;mh.classList.toggle("filtering",!!q);}i=(q&&vis.length)?0:-1;highlight();}
        \\function drawCompose(){box.textContent=c;box.classList.toggle("show",composing);}
        \\function reset(){q="";c="";composing=false;filtering=false;box.classList.remove("show");filter();}
        \\document.addEventListener("keydown",function(e){
        \\if(e.metaKey||e.ctrlKey||e.altKey)return;
        \\if(filtering){
        \\if(e.key==="ArrowDown"){e.preventDefault();if(vis.length){i=i<0?0:(i+1)%vis.length;highlight();}}
        \\else if(e.key==="ArrowUp"){e.preventDefault();if(vis.length){i=i<0?vis.length-1:(i-1+vis.length)%vis.length;highlight();}}
        \\else if(e.key==="Enter"){if(i>=0&&vis[i])vis[i].click();}
        \\else if(e.key==="Escape"){e.preventDefault();reset();}
        \\else if(e.key==="Backspace"){e.preventDefault();q=q.slice(0,-1);if(q)filter();else reset();}
        \\else if(e.key.length===1){e.preventDefault();q+=e.key;filter();}
        \\return;
        \\}
        \\if(e.key==="Enter"){if(composing&&c){e.preventDefault();location.href="https://www.google.com/search?q="+encodeURIComponent(c);}return;}
        \\if(e.key==="Tab"){e.preventDefault();q=c;c="";composing=false;box.classList.remove("show");filtering=true;filter();return;}
        \\if(e.key==="Escape"){if(composing){e.preventDefault();composing=false;c="";drawCompose();}return;}
        \\if(e.key==="Backspace"){if(composing){e.preventDefault();c=c.slice(0,-1);if(!c)composing=false;drawCompose();}return;}
        \\if(e.key.length===1){e.preventDefault();composing=true;c+=e.key;drawCompose();}
        \\});
        \\document.addEventListener("paste",function(e){
        \\var t=((e.clipboardData||window.clipboardData).getData("text")||"").replace(/[\r\n]+/g," ").trim();
        \\if(!t)return;
        \\e.preventDefault();
        \\if(filtering){q+=t;filter();}else{composing=true;c+=t;drawCompose();}
        \\});
        \\})();
        \\</script>
        \\
    );
}

/// Writes the leading icon slot. An explicit `icon:` wins (and is never fetched):
/// an image reference is used directly as an <img>, anything else is a glyph.
/// Otherwise, in favicon mode, the fetched favicon (or an empty, aligned slot).
fn writeSlot(w: *Writer, link: config.Link, favicons: ?*const favicon.Result) Writer.Error!void {
    if (link.icon) |icon| {
        if (isImageIcon(icon)) {
            try w.writeAll("<span class=\"slot\"><img class=\"favimg\" alt=\"\" src=\"");
            try writeEscaped(w, icon);
            try w.writeAll("\"></span>");
        } else {
            try w.writeAll("<span class=\"slot glyph\">");
            try writeEscaped(w, icon);
            try w.writeAll("</span>");
        }
        return;
    }
    const fav = favicons orelse return;
    try w.writeAll("<span class=\"slot\">");
    if (fav.classOf(link.url)) |i| {
        try w.print("<span class=\"favicon fav-{d}\"></span>", .{i});
    }
    try w.writeAll("</span>");
}

/// True if an `icon:` value is an image reference (URL / `data:` URI / path /
/// filename with an image extension) rather than a text glyph.
fn isImageIcon(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '/') != null) return true; // urls, data: URIs, paths
    const exts = [_][]const u8{ ".png", ".svg", ".ico", ".jpg", ".jpeg", ".gif", ".webp", ".bmp" };
    for (exts) |ext| {
        if (s.len >= ext.len and std.ascii.eqlIgnoreCase(s[s.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Escapes text for both HTML element content and double-quoted attributes.
fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

// --- tests ---

const testing = std.testing;

test writeEscaped {
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeEscaped(&buf.writer, "a<b>&\"'\"x");
    try testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#39;&quot;x", buf.written());
}

test "render: single column, escaping, lang, skips empty groups (no background)" {
    const cfg = Config{
        .title = "my <home>",
        .lang = "ja",
        .groups = &.{
            .{ .title = "dev", .links = &.{
                .{ .name = "gh", .url = "https://github.com" },
                .{ .name = "x\"y", .url = "https://e.com/?a=1&b=2", .icon = "▶" },
            } },
            .{ .title = "empty", .links = &.{} }, // must be skipped
        },
    };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    try testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, out, "<html lang=\"ja\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Berkeley Mono") != null);
    // keyboard/filter nav is always present; the background (and its network use) is not
    try testing.expect(std.mem.indexOf(u8, out, "addEventListener(\"keydown\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "images.unsplash.com") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<div class=\"bg\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "my &lt;home&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a=1&amp;b=2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x&quot;y") != null);
    try testing.expect(std.mem.indexOf(u8, out, "▶") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">empty<") == null);
}

test "render: background adds one photo layer + a load-time (non-rotating) script" {
    const cfg = Config{ .groups = &.{
        .{ .title = "g", .links = &.{.{ .name = "e", .url = "https://e.com" }} },
    } };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, true);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, "<div class=\"bg\" id=\"bg\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<script>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "images.unsplash.com") != null);
    try testing.expect(std.mem.indexOf(u8, out, "setInterval") == null); // no rotation while viewing
    try testing.expect(std.mem.indexOf(u8, out, "addEventListener(\"keydown\"") != null);
}

test "render embeds fetched favicons as deduped CSS-class icons" {
    var index_of: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_of.deinit(testing.allocator);
    try index_of.put(testing.allocator, "https://e.com", 0);
    const result = favicon.Result{
        .styles = &.{"data:image/png;base64,AAAA"},
        .index_of = index_of,
    };

    const cfg = Config{ .groups = &.{
        .{ .title = "g", .links = &.{.{ .name = "e", .url = "https://e.com" }} },
    } };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, &result, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, ".fav-0{background-image:url(\"data:image/png;base64,AAAA\")}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span class=\"favicon fav-0\"></span>") != null);
}

test "render: image icon: is used directly; a symbol is a glyph" {
    const cfg = Config{ .groups = &.{
        .{ .title = "g", .links = &.{
            .{ .name = "custom", .url = "https://e.com", .icon = "https://cdn.x/i.png" },
            .{ .name = "inline", .url = "https://f.com", .icon = "data:image/svg+xml,AAA" },
            .{ .name = "glyph", .url = "https://g.com", .icon = "★" },
        } },
    } };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, "<img class=\"favimg\" alt=\"\" src=\"https://cdn.x/i.png\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "src=\"data:image/svg+xml,AAA\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span class=\"slot glyph\">★</span>") != null);
}

test isImageIcon {
    try testing.expect(isImageIcon("https://x/i.png"));
    try testing.expect(isImageIcon("data:image/png;base64,AA"));
    try testing.expect(isImageIcon("/local/icon.svg"));
    try testing.expect(isImageIcon("icon.ICO"));
    try testing.expect(!isImageIcon("★"));
    try testing.expect(!isImageIcon("mail"));
}
