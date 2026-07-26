# Native-library distribution

The Zig package is a safe API layer over a caller-supplied native Turso
library. v0 vendors `vendor/turso-sdk-kit-0.7.1/turso.h` from Turso tag
`v0.7.1` and requires a `turso_sdk_kit` library built from that exact tag for
the same target ABI. A current Turso `main` or 0.8 pre-release library must not
be substituted.

## Implemented caller-supplied model

Every compile or run command requires a directory containing the native library:

```bash
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
zig build run-example \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
```

`-Dturso-lib-dir` is required. `-Dturso-linkage` accepts `dynamic` or `static`
and defaults to `dynamic`. The build restricts lookup to the supplied library
directory, adds its runtime search path for dynamic builds, does not use
`pkg-config`, and never invokes Cargo.

<<<<<<< HEAD
This keeps the first Zig package small and makes ABI compatibility visible. It
is appropriate for SDK development and CI. Package discovery (`zig build --help`)
and the artifact-free default step do not require the option; every compile or
run step fails unless the native-library directory is supplied.
=======
Dynamic Ubuntu x86_64 with glibc is the only runtime-qualified distribution
path today. Static selection requests `libturso_sdk_kit.a`, but static support
is not complete until its Rust and platform system-library dependencies are
enumerated and tested. No macOS or Windows runtime support is claimed.
>>>>>>> f5da640 (docs: add synchronous SDK example and usage)

The tests and example call `turso_version()` and accept only `0.7.1` followed
by end of string, `-`, or `+`. This catches obvious mismatches but cannot prove
full ABI identity. Artifact provenance and exact header/source matching remain
release requirements.

## CI provenance

Ubuntu CI shallow-clones Turso tag `v0.7.1`, verifies that the checkout is
exactly that tag and expected commit, byte-compares its `sdk-kit/turso.h` with
the vendored header, and builds only the `turso_sdk_kit` package with Cargo
under a bounded timeout. Cargo is maintainer-side CI setup, not consumer
`build.zig` behavior. CI then sets the loader path and runs formatting, the
full tests, the basic example, and an exact base-to-head `git diff --check` against that artifact.

## Future published artifacts

A future artifact package should pin wrapper and native source together and
select by operating system, architecture, and libc. For every artifact, record:

- Turso tag and immutable source revision;
- Rust toolchain, target triple, libc baseline, and release profile;
- SHA-256 checksum and build provenance;
- dynamic/static filename and loader instructions; and
- required operating-system libraries.

Do not claim a target until a Zig consumer has linked and run the local database
smoke path there. Browser/WASM needs a separate storage and packaging design.

## Ownership at the package boundary

The native artifact owns opaque database, connection, and statement handles;
the Zig wrappers release them explicitly in reverse order. Row text/blob values
and metadata are copied into caller-owned Zig allocations. Turso diagnostics
are copied, released with `turso_str_deinit`, and retained by the relevant
wrapper until its next fallible operation or `deinit`. Construction failures
carry their own allocated diagnostic and require explicit deinitialization.
