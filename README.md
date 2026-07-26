# Turso for Zig

Pre-release scaffold for an idiomatic Zig 0.16.0 binding to Turso's embedded
database API. It is not an SDK yet: this repository intentionally contains no
FFI declarations, wrapper implementation, native binaries, or public database
API.

The binding should wrap Turso's [`sdk-kit/turso.h`](https://github.com/tursodatabase/turso/blob/main/sdk-kit/turso.h)
C ABI, not reach into Rust internals. That ABI already provides database creation,
connections, prepared statements, binding, row access, cleanup, callbacks, and
the low-level sync I/O-driving interface.

## Current layout

```text
turso-zig/
├── build.zig             # package scaffold; intentionally builds no artifact
├── build.zig.zon         # Zig 0.16.0 package metadata
├── docs/                 # implementation and distribution decisions
├── src/README.md         # proposed source boundaries
├── tests/README.md       # behavioral test direction
└── examples/README.md    # first-example scope
```

## Implement in this order

1. Choose how consumers obtain the Turso native library. See
   [`docs/distribution.md`](docs/distribution.md).
2. Implement only synchronous local databases first. The exact API, lifetime,
   and error requirements are in
   [`docs/implementation-plan.md`](docs/implementation-plan.md).
3. Add behavioral tests and an example before expanding the API surface.
4. Add cloud sync, user-defined functions, loadable extensions, and async-I/O
   driving as separately tested follow-up features.

## Non-goals for the first release

- A second SQL parser or database engine.
- Reimplementing the C ABI in Zig.
- Building Turso's Rust workspace implicitly on every consumer build.
- An async facade before a synchronous API has clear ownership and error
  semantics.

## Local checks

Install Zig 0.16.0, then validate the scaffold from the repository root:

```bash
zig fmt --check build.zig
zig build
git diff --check
```

`zig build` succeeding only confirms package metadata and build-script syntax;
it does not build a library until implementation begins.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting changes and
[`SECURITY.md`](SECURITY.md) for private vulnerability reporting. This project
is licensed under the [`MIT License`](LICENSE).
