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
    \\  display: none;
    \\  width: fit-content;
    \\  margin: 0 0 0 auto;
    \\  min-height: 100vh;
    \\  background: #000;
    \\  padding: clamp(30px, 7vw, 72px) clamp(22px, 5vw, 40px);
    \\  padding-right: clamp(36px, 6vw, 60px);
    \\}
    \\.page.active { display: block; }
    \\.masthead { margin: 0 0 2.4rem; }
    \\.ws { display: flex; gap: 6px; margin-top: 0.7rem; }
    \\.ws .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--muted); opacity: 0.35; }
    \\.ws .dot.on { background: var(--accent); opacity: 1; }
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
    \\.clocks {
    \\  position: fixed;
    \\  left: 0;
    \\  bottom: 0;
    \\  z-index: 5;
    \\  padding: 12px 16px 14px;
    \\  font-size: 0.7rem;
    \\  line-height: 1.3;
    \\  background: linear-gradient(to top, rgba(0,0,0,0.88), rgba(0,0,0,0.78) 60%, rgba(0,0,0,0));
    \\  max-width: 100vw;
    \\  overflow-x: auto;
    \\  cursor: default;
    \\}
    \\.clocks:empty { display: none; }
    \\.clk-row { display: flex; align-items: center; gap: 12px; margin: 3px 0; white-space: nowrap; }
    \\.clk-label { display: flex; align-items: baseline; gap: 8px; width: 170px; min-width: 170px; }
    \\.clk-city { color: var(--fg); letter-spacing: 0.05em; }
    \\.clk-now { color: var(--accent); font-variant-numeric: tabular-nums; }
    \\.clk-zone { margin-left: auto; color: var(--muted); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; }
    \\.clk-cells { display: flex; }
    \\.clk-cell {
    \\  width: 22px;
    \\  min-width: 22px;
    \\  text-align: center;
    \\  padding: 3px 0;
    \\  color: var(--fg);
    \\  background: rgba(255,255,255,0.09);
    \\  border-right: 1px solid rgba(0,0,0,0.45);
    \\  font-variant-numeric: tabular-nums;
    \\}
    \\.clk-cell.night { background: rgba(255,255,255,0.02); color: var(--muted); }
    \\.clk-cell.day { box-shadow: inset 2px 0 0 var(--accent); color: var(--accent); }
    \\.clk-cell.cur { background: var(--accent); color: #000; }
    \\.clk-band { position: absolute; pointer-events: none; z-index: 2; display: none; border: 1px solid var(--accent); border-radius: 3px; box-shadow: 0 0 0 1px rgba(0,0,0,0.5); }
    \\@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
    \\
;

pub fn render(w: *Writer, cfg: Config, favicons: ?*const favicon.Result, with_background: bool) Writer.Error!void {
    const doc_title = if (cfg.workspaces.len > 0) cfg.workspaces[0].title else "startpage";

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
    try writeEscaped(w, doc_title);
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

    // Each workspace is its own page; only the active one is shown (left/right
    // arrows switch between them, wired up in the script). The first is active
    // so the page still works with scripting disabled.
    for (cfg.workspaces, 0..) |ws, wi| {
        try w.writeAll(if (wi == 0) "<main class=\"page active\">\n" else "<main class=\"page\">\n");
        try w.writeAll("<header class=\"masthead\"><h1>");
        try writeEscaped(w, ws.title);
        try w.writeAll("</h1>");
        try writeWorkspaceNav(w, wi, cfg.workspaces.len);
        try w.writeAll("</header>\n");

        for (ws.groups) |group| {
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
    }

    if (cfg.clocks.len > 0) try w.writeAll("<div class=\"clocks\" id=\"clocks\"></div>\n");
    try w.writeAll("<div class=\"compose\" id=\"compose\"></div>\n");
    try writeScript(w, with_background, cfg.clocks);
    try w.writeAll("</body>\n</html>\n");
}

/// A row of dots marking this workspace's position among `count` (with the
/// current one filled). Emits nothing for a single workspace.
fn writeWorkspaceNav(w: *Writer, active: usize, count: usize) Writer.Error!void {
    if (count < 2) return;
    try w.writeAll("<nav class=\"ws\" title=\"← → switch workspace\">");
    for (0..count) |j| {
        try w.writeAll(if (j == active) "<span class=\"dot on\"></span>" else "<span class=\"dot\"></span>");
    }
    try w.writeAll("</nav>");
}

/// Emits the page's client-side script: (optionally) a random background chosen
/// on load, workspace switching (left/right arrows swap the visible page), plus
/// keyboard navigation. Typing pops a centered compose box; Tab transfers the
/// query into the link filter, where up/down move the highlight, Enter opens it,
/// and Esc/Backspace edit or dismiss the query. The filter is scoped to the
/// active workspace, but on Tab a query that matches nothing there falls through
/// to the other workspaces, switching to the first one with a match; switching
/// workspaces keeps an active filter and re-applies it (highlighting its first
/// match).
fn writeScript(w: *Writer, with_background: bool, clocks: []const config.Clock) Writer.Error!void {
    try w.writeAll("<script>\n(function(){\n");

    try writeClocks(w, clocks);

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
        \\var pages=[].slice.call(document.querySelectorAll(".page"));
        \\pages.forEach(function(p){var h=p.querySelector(".masthead h1");p._t=h?h.textContent:"";});
        \\var box=document.getElementById("compose");
        \\var cur=0,A,G,mh,title,q="",c="",composing=false,filtering=false,vis=[],i=-1;
        \\function bind(){var p=pages[cur];A=[].slice.call(p.querySelectorAll(".group a"));A.forEach(function(a){a._n=(a.querySelector(".name")||a).textContent.toLowerCase();});G=[].slice.call(p.querySelectorAll(".group"));mh=p.querySelector(".masthead h1");title=p._t;}
        \\function highlight(){A.forEach(function(a){a.classList.remove("active");});if(i>=0&&vis[i]){vis[i].classList.add("active");vis[i].scrollIntoView({block:"nearest"});}}
        \\function filter(){var ql=q.toLowerCase();vis=[];A.forEach(function(a){var s=a._n.indexOf(ql)!==-1;a.parentNode.style.display=s?"":"none";if(s)vis.push(a);});G.forEach(function(g){var any=[].slice.call(g.querySelectorAll("a")).some(function(a){return a.parentNode.style.display!=="none";});g.style.display=any?"":"none";});if(mh){mh.textContent=q||title;mh.classList.toggle("filtering",!!q);}i=(q&&vis.length)?0:-1;highlight();}
        \\function pageMatches(p,ql){return [].slice.call(p.querySelectorAll(".group a")).some(function(a){return (a._n||(a._n=(a.querySelector(".name")||a).textContent.toLowerCase())).indexOf(ql)!==-1;});}
        \\function filterAcross(){filter();if(q&&!vis.length&&pages.length>1){var ql=q.toLowerCase();for(var k=1;k<pages.length;k++){var n=(cur+k)%pages.length;if(pageMatches(pages[n],ql)){show(n);break;}}}}
        \\function drawCompose(){box.textContent=c;box.classList.toggle("show",composing);}
        \\function reset(){q="";c="";composing=false;filtering=false;box.classList.remove("show");filter();}
        \\function show(n){pages[cur].classList.remove("active");cur=(n%pages.length+pages.length)%pages.length;var p=pages[cur];p.classList.add("active");if(!p.style.minWidth)p.style.minWidth=p.getBoundingClientRect().width+"px";bind();c="";composing=false;box.classList.remove("show");filter();}
        \\show(0);
        \\document.addEventListener("keydown",function(e){
        \\if(e.metaKey||e.ctrlKey||e.altKey)return;
        \\if(e.key==="ArrowLeft"&&pages.length>1){e.preventDefault();show(cur-1);return;}
        \\if(e.key==="ArrowRight"&&pages.length>1){e.preventDefault();show(cur+1);return;}
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
        \\if(e.key==="Tab"){e.preventDefault();q=c;c="";composing=false;box.classList.remove("show");filtering=true;filterAcross();return;}
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

/// Emits the world-clock strip's data and renderer into the page script: a
/// worldtimebuddy-style row per configured city with its current time and a
/// 24-column timeline whose columns are the same absolute instant across rows
/// (so you can read off what time it is everywhere at a glance). All time math
/// is done client-side with `Intl.DateTimeFormat`, so zones track DST at view
/// time. Emits nothing when no clocks are configured.
fn writeClocks(w: *Writer, clocks: []const config.Clock) Writer.Error!void {
    if (clocks.len == 0) return;

    try w.writeAll("var CK=[");
    for (clocks, 0..) |clock, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{tz:\"");
        try writeJsString(w, clock.tz);
        try w.writeAll("\",label:\"");
        try writeJsString(w, clock.label);
        try w.writeAll("\"}");
    }
    try w.writeAll(
        \\];
        \\var CEL=document.getElementById("clocks"),NOW=12,hovCol=-1;
        \\function pz(d,tz){var o={};new Intl.DateTimeFormat("en-US",{timeZone:tz,hourCycle:"h23",hour:"2-digit",minute:"2-digit",weekday:"short",day:"2-digit",month:"short",timeZoneName:"short"}).formatToParts(d).forEach(function(p){o[p.type]=p.value;});return o;}
        \\function esc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
        \\function off(tz,d){var o={};new Intl.DateTimeFormat("en-US",{timeZone:tz,hourCycle:"h23",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit"}).formatToParts(d).forEach(function(p){o[p.type]=p.value;});return (Date.UTC(o.year,o.month-1,o.day,o.hour,o.minute,o.second)-d.getTime())/60000;}
        \\function band(col){var b=document.getElementById("clkband");if(!b)return;var cells=col<0?[]:CEL.querySelectorAll('.clk-cell[data-c="'+col+'"]');if(!cells.length){b.style.display="none";return;}var o=CEL.getBoundingClientRect(),f=cells[0].getBoundingClientRect(),l=cells[cells.length-1].getBoundingClientRect();b.style.display="block";b.style.left=(f.left-o.left)+"px";b.style.top=(f.top-o.top)+"px";b.style.width=f.width+"px";b.style.height=(l.bottom-f.top)+"px";}
        \\function drawClocks(){
        \\var now=new Date();var base=new Date(now.getTime());base.setMinutes(0,0,0);base=new Date(base.getTime()-NOW*3600000);var h='<div class="clk-band" id="clkband"></div>';
        \\var order=CK.slice().sort(function(a,b){return off(b.tz,now)-off(a.tz,now);});
        \\for(var r=0;r<order.length;r++){var c=order[r],p=pz(now,c.tz),cells="";
        \\for(var j=0;j<24;j++){var hp=pz(new Date(base.getTime()+j*3600000),c.tz),hr=+hp.hour;
        \\var cls="clk-cell"+((hr<7||hr>=19)?" night":"")+(hr===0?" day":"")+(j===NOW?" cur":"");
        \\cells+='<span class="'+cls+'" data-c="'+j+'" title="'+esc(hp.weekday+" "+hp.day+" "+hp.month)+'">'+(hr===0?hp.day:hp.hour)+'</span>';}
        \\h+='<div class="clk-row"><div class="clk-label"><span class="clk-city">'+esc(c.label)+'</span><span class="clk-now">'+p.hour+':'+p.minute+'</span><span class="clk-zone">'+esc(p.weekday+" "+(p.timeZoneName||""))+'</span></div><div class="clk-cells">'+cells+'</div></div>';}
        \\CEL.innerHTML=h;band(hovCol);}
        \\CEL.addEventListener("mousemove",function(e){var c=e.target.closest?e.target.closest(".clk-cell"):null;var n=c?+c.getAttribute("data-c"):-1;if(n!==hovCol){hovCol=n;band(hovCol);}});
        \\CEL.addEventListener("mouseleave",function(){hovCol=-1;band(-1);});
        \\drawClocks();setInterval(drawClocks,1000);
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

/// Escapes a string for embedding in a double-quoted JavaScript string literal.
/// `<` becomes `\x3C` so a value can never spawn a `</script>` and break out.
fn writeJsString(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '<' => try w.writeAll("\\x3C"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
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

fn oneWorkspace(title: []const u8, groups: []const config.Group) config.Workspace {
    return .{ .title = title, .groups = groups };
}

test "render: single column, escaping, lang, skips empty groups (no background)" {
    const cfg = Config{
        .lang = "ja",
        .workspaces = &.{oneWorkspace("my <home>", &.{
            .{ .title = "dev", .links = &.{
                .{ .name = "gh", .url = "https://github.com" },
                .{ .name = "x\"y", .url = "https://e.com/?a=1&b=2", .icon = "▶" },
            } },
            .{ .title = "empty", .links = &.{} }, // must be skipped
        })},
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
    // the single workspace title is both the <title> and the masthead
    try testing.expect(std.mem.indexOf(u8, out, "<title>my &lt;home&gt;</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "my &lt;home&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a=1&amp;b=2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x&quot;y") != null);
    try testing.expect(std.mem.indexOf(u8, out, "▶") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">empty<") == null);
    // one workspace: page is active, but no workspace-switch dots are shown
    try testing.expect(std.mem.indexOf(u8, out, "<main class=\"page active\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "class=\"ws\"") == null);
}

test "render: multiple workspaces each get a page, only the first is active, with nav dots" {
    const cfg = Config{ .workspaces = &.{
        oneWorkspace("startale", &.{.{ .title = "g", .links = &.{.{ .name = "a", .url = "https://a.com" }} }}),
        oneWorkspace("personal", &.{.{ .title = "h", .links = &.{.{ .name = "b", .url = "https://b.com" }} }}),
    } };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    // first page active, second inactive; <title> is the first workspace
    try testing.expect(std.mem.indexOf(u8, out, "<title>startale</title>") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<main class=\"page active\">"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<main class=\"page\">"));
    try testing.expect(std.mem.indexOf(u8, out, ">startale</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">personal</h1>") != null);
    // a dot row per page, each marking its own position
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "<nav class=\"ws\""));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "<span class=\"dot on\">"));
    // arrow switching is wired up
    try testing.expect(std.mem.indexOf(u8, out, "ArrowLeft") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ArrowRight") != null);
}

test "render: background adds one photo layer + a load-time (non-rotating) script" {
    const cfg = Config{ .workspaces = &.{oneWorkspace("w", &.{
        .{ .title = "g", .links = &.{.{ .name = "e", .url = "https://e.com" }} },
    })} };
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

    const cfg = Config{ .workspaces = &.{oneWorkspace("w", &.{
        .{ .title = "g", .links = &.{.{ .name = "e", .url = "https://e.com" }} },
    })} };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, &result, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, ".fav-0{background-image:url(\"data:image/png;base64,AAAA\")}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span class=\"favicon fav-0\"></span>") != null);
}

test "render: image icon: is used directly; a symbol is a glyph" {
    const cfg = Config{ .workspaces = &.{oneWorkspace("w", &.{
        .{ .title = "g", .links = &.{
            .{ .name = "custom", .url = "https://e.com", .icon = "https://cdn.x/i.png" },
            .{ .name = "inline", .url = "https://f.com", .icon = "data:image/svg+xml,AAA" },
            .{ .name = "glyph", .url = "https://g.com", .icon = "★" },
        } },
    })} };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, "<img class=\"favimg\" alt=\"\" src=\"https://cdn.x/i.png\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "src=\"data:image/svg+xml,AAA\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span class=\"slot glyph\">★</span>") != null);
}

test "render: world-clock strip emits a data row per city, escaped and script-safe" {
    const cfg = Config{
        .workspaces = &.{oneWorkspace("w", &.{
            .{ .title = "g", .links = &.{.{ .name = "a", .url = "https://a.com" }} },
        })},
        .clocks = &.{
            .{ .tz = "America/Chicago", .label = "Austin" },
            .{ .tz = "Asia/Tokyo", .label = "Tokyo" },
            .{ .tz = "Europe/Zagreb", .label = "</script>" }, // must be neutralized
        },
    };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, "<div class=\"clocks\" id=\"clocks\"></div>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{tz:\"America/Chicago\",label:\"Austin\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{tz:\"Asia/Tokyo\",label:\"Tokyo\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Intl.DateTimeFormat") != null);
    // the label can never close the script element early
    try testing.expect(std.mem.indexOf(u8, out, "label:\"</script>\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "label:\"\\x3C/script>\"") != null);
}

test "render: no clocks means no strip and no clock script" {
    const cfg = Config{ .workspaces = &.{oneWorkspace("w", &.{
        .{ .title = "g", .links = &.{.{ .name = "a", .url = "https://a.com" }} },
    })} };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try render(&buf.writer, cfg, null, false);
    const out = buf.written();

    try testing.expect(std.mem.indexOf(u8, out, "class=\"clocks\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "drawClocks") == null);
}

test isImageIcon {
    try testing.expect(isImageIcon("https://x/i.png"));
    try testing.expect(isImageIcon("data:image/png;base64,AA"));
    try testing.expect(isImageIcon("/local/icon.svg"));
    try testing.expect(isImageIcon("icon.ICO"));
    try testing.expect(!isImageIcon("★"));
    try testing.expect(!isImageIcon("mail"));
}
