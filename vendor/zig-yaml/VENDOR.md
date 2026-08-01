# Vendored: zig-yaml

- Upstream: <https://github.com/kubkon/zig-yaml>
- Version: `0.3.0`
- Commit: `84d747bc80937a08ea1cf76a63fee12c5fb1dd61`
- License: MIT (see `LICENSE`)

Only `src/` is vendored (the library module; entry point `src/lib.zig`).

## Why vendored instead of a package-manager dependency

zig-yaml 0.3.0 declares `minimum_zig_version = "0.16.0"` and its *library*
compiles cleanly on Zig 0.16. However, its `build.zig` unconditionally does
`@import("test/spec.zig")`, and that test file uses `std.StringArrayHashMap`,
which was **removed in Zig 0.16**. As a result `b.dependency("zig_yaml", ...)`
fails to evaluate the dependency's `build.zig` even though we only need the
library module. Vendoring `src/` sidesteps the broken build script entirely.

## Updating

1. `zig fetch git+https://github.com/kubkon/zig-yaml#<commit-or-tag>`
2. Copy the fetched package's `src/` and `LICENSE` over this directory.

Once upstream fixes the `build.zig` spec-test import on 0.16, this can be
switched back to a normal package-manager dependency:

```sh
zig fetch --save git+https://github.com/kubkon/zig-yaml
```

```zig
// build.zig
const yaml_dep = b.dependency("zig_yaml", .{ .target = target, .optimize = optimize });
// ... .imports = &.{ .{ .name = "yaml", .module = yaml_dep.module("yaml") } }
```
