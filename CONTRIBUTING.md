# Contributing

## Requirements

- Zig 0.16.0
- Git
- A Turso SDK Kit native library built from the pinned `v0.7.1` source
- A C toolchain for native linking
- Rust and Cargo only when building the pinned Turso library or extension fixture from source

The synchronous safe adapter is implemented. Its parity gate classifies all 48
public C functions and 27 public typedefs, compile-references every exact Zig
API or internal adapter, and validates every cell in
[`docs/abi-parity.md`](docs/abi-parity.md). Read
[`docs/implementation-plan.md`](docs/implementation-plan.md) before changing API,
ownership, callback, or progress contracts.

The public `turso.c` namespace remains unstable and unsafe. Complete declaration
classification does not turn direct raw calls into safe adapter coverage.

## Development

Fork or clone the repository and create a focused branch. Set paths to the
matching native library and optional pinned regexp fixture, then run the same
gates as CI:

```sh
TURSO_LIB_DIR=/absolute/path/to/turso-v0.7.1/target/release
TURSO_EXTENSION_PATH=/absolute/path/to/liblimbo_regexp.so

zig build abi-parity \
  -Dturso-lib-dir="$TURSO_LIB_DIR" \
  -Dturso-linkage=dynamic
zig build test \
  -Dturso-lib-dir="$TURSO_LIB_DIR" \
  -Dturso-linkage=dynamic
zig build test \
  -Dturso-lib-dir="$TURSO_LIB_DIR" \
  -Dturso-linkage=dynamic \
  -Dturso-extension-path="$TURSO_EXTENSION_PATH"
zig build run-example \
  -Dturso-lib-dir="$TURSO_LIB_DIR" \
  -Dturso-linkage=dynamic
zig fmt --check build.zig src tests examples
git diff --check
```

The ordinary suite must pass without an extension fixture. The fixture suite
must use an absolute path to the pinned Linux dynamic extension and exercises
the explicit native-code trust boundary. `zig build run-example` runs both
`basic.zig` and `parity.zig`.

Behavior changes require a failing observable contract test before the fix.
Parity changes also require synthetic negative coverage for declaration or
document drift. Keep raw C pointers, C strings, and native ownership inside the
FFI boundary.

## Pull requests

Keep each pull request to one concern. Include:

- the user-visible contract being added or changed;
- C ABI ownership or lifetime implications;
- exact validation commands and results; and
- supported targets affected by the change.

Do not commit Turso native binaries, authentication tokens, local databases, or
Zig build output.

## Commit messages

Use a short imperative subject with an optional scope, for example:

```text
statement: copy text values before stepping
```

Explain the invariant or compatibility reason in the body when the subject is
not sufficient.
