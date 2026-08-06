# Native-library distribution

The Zig package is a safe API layer over a native Turso library. v0 vendors the
Turso 0.7.1 header and requires consumers to supply the matching library for
their target explicitly.

## Recommended rollout

### Phase 1: caller-supplied native library

The package vendors `turso.h` from Turso v0.7.1 and requires callers to
provide a directory containing the matching native library:

```bash
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/lib \
  -Dturso-linkage=dynamic
```

`-Dturso-lib-dir` is required. `-Dturso-linkage` accepts only `dynamic` or
`static` and defaults to `dynamic`. Dynamic linking is the first exercised
mode. Static mode is parsed and selects the static artifact, but callers remain
responsible for its platform system-library requirements. The build uses only
the supplied directory, does not fall back to `pkg-config` or an arbitrary
system Turso library, and never invokes Cargo implicitly.

This keeps the first Zig package small and makes ABI compatibility visible. It
is appropriate for SDK development and CI. Package discovery (`zig build --help`)
and the artifact-free default step do not require the option; every compile or
run step fails unless the native-library directory is supplied.

### Phase 2: published, pinned platform artifacts

Publish a separate Zig package or artifact package containing prebuilt Turso
libraries. Pin the wrapper and native artifact to the same Turso release and
select artifacts by operating system, CPU architecture, and libc variant.

At minimum, the release process needs to answer for every artifact:

- which Turso source revision and Rust toolchain produced it;
- target triple, libc baseline, linker mode, and debug/release configuration;
- SHA-256 checksum and provenance;
- library filename and whether it is static or dynamically loaded; and
- required operating-system libraries and deployment instructions.

Do not claim cross-platform support until each published artifact is exercised
by a Zig consumer build and runtime smoke test.

### Do not start with implicit Rust builds

Having `zig build` invoke Cargo against the full Turso workspace would couple
consumer builds to a Rust toolchain, Cargo's dependency network/cache, and the
host/target cross-compilation setup. It is useful for contributor automation,
but should remain an explicit maintainer command, not the default SDK-consumer
path.

## ABI compatibility rules

- Build the wrapper and Turso library for the same target ABI.
- Compile against the exact `sdk-kit/turso.h` release that exported the
  library.
- Keep a compatibility test that compiles a small Zig translation unit against
  the shipped header and links the shipped artifact.
- Version any breaking wrapper API or C-ABI change deliberately. A library that
  loads successfully can still be unsafe if the header and binary disagree.
- Run a local database smoke test after linking: create `:memory:`, execute
  DDL, bind a value, read it back, and deinitialize every handle.

## Suggested CI matrix once artifacts exist

Start with the targets Turso itself supports and can test reliably:

| Platform | Architectures | Notes |
| --- | --- | --- |
| Linux | x86_64, aarch64 | Test GNU and musl separately if both are distributed. |
| macOS | aarch64, x86_64 | Validate universal packaging only if it is actually shipped. |
| Windows | x86_64, aarch64 | Test the selected MSVC ABI and DLL discovery path. |

Add browser/WASM only with a deliberate WASM-specific build and storage design;
a native C-ABI package is not automatically a browser SDK.
