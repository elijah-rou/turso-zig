# Native-library distribution

The Zig package is an API layer over a caller-supplied native Turso library.
Managed wrappers enforce their documented safety contracts; the explicitly
unsafe native-extension loader is a full ABI trust boundary. v0 vendors
`vendor/turso-sdk-kit-0.7.1/turso.h` from Turso tag
`v0.7.1` and requires a `turso_sdk_kit` library built from that exact tag for
the same target ABI. `zig build abi-parity` proves exact classification and compile references for all 48 public functions and 27 public typedefs; see [`abi-parity.md`](abi-parity.md). A current Turso `main` or 0.8 pre-release library must not
be substituted.

## Implemented caller-supplied model

Every compile or run command requires a directory containing the native library:

```bash
zig build abi-parity \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
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
`pkg-config`, and never invokes Cargo. The optional
`-Dturso-extension-path=<absolute path>` enables only the isolated extension
integration executable. It is not imported by the consumer module, and omitting
it leaves ordinary tests available without an extension fixture.

Package discovery (`zig build --help`) and the artifact-free default step do
not require the option; every compile or run step fails unless the native-library
directory is supplied.


Dynamic Ubuntu x86_64 with glibc is the only runtime-qualified distribution
path today. Static selection requests `libturso_sdk_kit.a`, but static support
is not complete until its Rust and platform system-library dependencies are
enumerated and tested. No macOS or Windows runtime support is claimed.

The tests and example call `turso_version()` and accept only `0.7.1` followed
by end of string, `-`, or `+`. This catches obvious runtime mismatches. The compile-time parity audit additionally checks imported declarations, callback calling conventions, enum tags, and critical layouts, but cannot prove that an arbitrary binary was built from the claimed source. Artifact provenance and exact header/source matching remain
release requirements.

## CI provenance

Ubuntu CI shallow-clones Turso tag `v0.7.1`, verifies that the checkout is
exactly that tag and expected commit, byte-compares its `sdk-kit/turso.h` with
the vendored header, and builds the `turso_sdk_kit` package with Cargo under a
bounded timeout. CI also builds the workspace's exact `limbo_regexp` package
with `--locked --profile release-official`, verifies the resulting Linux shared
library exports `register_extension`, and passes its absolute path to the
extension parity test. Cargo is maintainer-side CI setup, not consumer
<<<<<<< HEAD
`build.zig` behavior. CI then sets the loader path and runs formatting, the
full tests, the basic example, and an exact base-to-head `git diff --check`
against those artifacts.
=======
`build.zig` behavior. CI then sets the loader path and runs the ABI parity gate before runtime tests, followed by formatting, the
full tests, the basic example, and `git diff --check` against those artifacts.
>>>>>>> 9a6033d (docs: publish complete 0.7.1 adapter parity)

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
