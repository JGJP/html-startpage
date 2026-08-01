# startpage

A tiny generator that turns one or more YAML files into a **single HTML startpage**:
a minimal, scrollable **black column of links** over an **auto-rotating photo
background** (Bonjourr-style). Each link shows its site's favicon — preferring the
dark-mode variant so icons read well on black — fetched at build time and baked
inline. Point your browser's home / new-tab page at the generated file.

Written in Zig (0.16), rendered in [Berkeley Mono](https://berkeleygraphics.com/typefaces/berkeley-mono/)
when installed (falling back to the system monospace stack).

```
        ░░ rotating photo background ░░
        ┌───────────────────┐
        │ home              │
        │                   │
        │ REPOS             │
        │  github         │   ← favicons baked inline
        │  gitlab         │     (dark-mode variant on black)
        │                   │
        │ MEDIA             │
        │  youtube         │
        └───────────────────┘
         single scrollable column, on black
```

## Build

Requires **Zig 0.16.0**.

```sh
zig build                 # builds ./zig-out/bin/startpage
zig build run -- config.yaml -o startpage.html
zig build example         # renders examples/startpage.yaml to zig-out/startpage.html
zig build test            # run unit tests, then build & open startpage.html in your browser
```

## Usage

```sh
startpage [options] <config.yaml> [more.yaml ...]
```

| Option | Description |
| --- | --- |
| `-o, --output <file>` | Write HTML to `<file>` (default `startpage.html`). Use `-` for stdout. |
| `--no-favicons` | Don't fetch/bake favicons. |
| `--no-background` | Don't add the rotating background (plain black page, no external requests). |
| `--no-cache-icons` | Don't write resolved favicons back into the source YAML (see [Favicons](#favicons)). |
| `-h, --help` | Show help. |

For a fast, fully-offline build, combine both: `startpage config.yaml --no-favicons --no-background`.

Examples:

```sh
startpage config.yaml                     # -> startpage.html
startpage config.yaml -o ~/home.html      # custom output path
startpage work.yaml personal.yaml -o -    # merge two files, print to stdout
```

## Config format

Each file may define an optional `title`, an optional `lang` (default `en`), and
a list of `groups`. Every group has a `title` and a list of `links`; each link
has a `name`, a `url` (`uri` is accepted as an alias), and an optional `icon`.
The `icon` is either an **image reference** (URL, `data:` URI, or path) used
directly as the favicon, or a short **glyph**. Setting `icon` overrides and skips
favicon fetching for that link.

```yaml
title: home
lang: en

groups:
  - title: dev
    links:
      - name: github
        url: https://github.com
      - name: youtube
        uri: https://youtube.com   # `uri` works too
      - name: custom
        url: https://example.com
        icon: https://example.com/icon.svg   # image used as-is (no fetch)
      - name: notes
        url: https://notes.example
        icon: "✎"                  # a glyph also works
```

See [`examples/startpage.yaml`](examples/startpage.yaml) for a fuller example.

> **Block style only.** Use indented block syntax (as above). The vendored
> parser does not support YAML flow style (`links: [{name: x, url: y}]`), and
> each file must contain a single YAML document (no `---` separators).

## Favicons

By default each link's favicon is fetched once per host at generation time and
embedded inline as a `data:` URI, deduplicated so many links to the same site
cost a single copy. To read well on the black column, each host is resolved by:

1. fetching the homepage and picking the best declared `<link rel="icon">`
   (preferring SVG and `media="(prefers-color-scheme: dark)"` icons),
2. trying that icon's `-dark` sibling (e.g. `favicon.svg` → `favicon-dark.svg`,
   which is how GitHub serves its white logo),
3. falling back to `<host>/favicon.ico`.

No third-party favicon services are used — only the sites you link to are
contacted. A link with an explicit `icon:` is never fetched (its icon is used
directly). Links whose site has no usable favicon and non-`http(s)` URLs are left
without an image (the slot stays aligned). Pass `--no-favicons` to skip fetching
entirely.

### Icon caching

After a build, each resolved favicon is written back into the source YAML as an
`icon: "data:..."` on the link that lacked one (existing lines and comments are
left untouched). Because an explicit `icon:` is used directly and never fetched,
the next build reuses the baked icon instead of hitting the network again — so a
first build populates the cache and subsequent builds are offline for those
links. Only links with a *found* favicon are cached; links whose site had no
usable icon stay uncached and are retried next time. Pass `--no-cache-icons` to
leave the YAML untouched.

## Background

By default the page shows an auto-rotating photo background (a curated set of
Unsplash photos, Bonjourr-style), crossfading every 30s starting from a random
one. This is the one thing the generated file loads at view time — the photos are
referenced by URL (not baked), so the background needs network access to display
and uses a small amount of JavaScript to rotate. Pass `--no-background` for a
plain black page that makes no external requests. The photo set is defined in
`src/render.zig` (`backgrounds`).

### Multiple files

You can pass several YAML files. Their `groups` are **concatenated in order**,
and `title`/`lang` are taken from the **first file that sets them**. This lets
you keep, say, `work.yaml` and `personal.yaml` separate and combine them at
build time.

All text (titles, names, URLs, icons) is HTML-escaped, so arbitrary content is
safe to include.

## Project layout

```
build.zig            build script (vendored yaml module + run/example/test steps)
build.zig.zon        package manifest
src/
  main.zig           CLI: argument parsing and orchestration
  config.zig         YAML schema + multi-file loading/merging
  favicon.zig        fetches + bakes site favicons as inline data: URIs
  render.zig         HTML/CSS generation and escaping
examples/
  startpage.yaml     sample config
vendor/zig-yaml/     vendored YAML parser (see vendor/zig-yaml/VENDOR.md)
```

## Notes

- **Dependencies:** the [zig-yaml](https://github.com/kubkon/zig-yaml) parser is
  vendored under `vendor/zig-yaml/` rather than fetched via the package manager,
  because its upstream `build.zig` does not currently compile on Zig 0.16. See
  [`vendor/zig-yaml/VENDOR.md`](vendor/zig-yaml/VENDOR.md) for details and how to
  switch back once upstream is fixed.
- The output is a single file with inline CSS and inline favicons. With
  `--no-background` it has no scripts and makes no external requests (fully
  offline); otherwise it loads rotating background photos from Unsplash at view
  time.
- Favicon fetching happens at generation time only. For a fast, fully-offline
  build and file, use `--no-favicons --no-background`.

## License

MIT — see [`LICENSE`](LICENSE). Vendored zig-yaml is MIT
([`vendor/zig-yaml/LICENSE`](vendor/zig-yaml/LICENSE)).
