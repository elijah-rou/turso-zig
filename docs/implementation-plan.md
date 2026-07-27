# Implementing the Zig binding

## 1. Implemented v0 contract

v0 is an **embedded/local, synchronous** binding built with Zig 0.16.0. The
first verified target is x86_64 Linux with glibc and dynamic linkage; other
targets are unsupported until their matching native artifact and loader
behavior pass runtime tests. Static artifact selection exists but its native
system-library closure has not been qualified. The package supports the core
prepared-statement workflow:

- open `:memory:` or a filesystem path;
- create a connection;
- prepare exactly one SQL statement;
- bind `null`, integers, floats, text, and blobs by position;
- execute mutations or step query rows;
- expose row values as a tagged Zig union; and
- release statement, connection, and database handles explicitly.

Public fallible operations return one exhaustive Zig error set. Each owning
wrapper retains the latest Turso diagnostic as allocator-owned bytes for
inspection until the next operation on that owner which can return a Turso
diagnostic, or `deinit`. Before such an operation, the wrapper frees and clears
its previous diagnostic. A construction failure has no wrapper in which to
retain a message, so constructors return a small failure payload containing the
Zig error category and the owned Turso diagnostic. The caller owns that payload
and must deinitialize it.

Text and blob row values are copied with the caller's allocator before another
statement operation can invalidate the C memory. The caller explicitly
deinitializes copied values. Bound text and blob slices remain caller-owned and
need only remain valid for the binding call.

Database handles may be shared only where the C contract permits. Connections
and statements are exclusive-use and the Zig API adds no hidden synchronization.
All owning handles require explicit cleanup in reverse acquisition order.
Statements must be deinitialized before their connection, and connections
before their database. Programmer misuse such as use after `deinit` fails
loudly in safe builds.

The native library is caller-supplied through required
`-Dturso-lib-dir=<path>`. `-Dturso-linkage=dynamic|static` selects linkage and
defaults to dynamic. Builds never invoke Cargo implicitly. The vendored 0.7.1
header and a library built from Turso v0.7.1 are one ABI unit. Runtime smoke
tests require `turso_version()` to start with the exact `0.7.1` core followed
only by end of string, `-`, or `+`.

The public surface exports `version`, `setup`, `SetupConfig`, `SetupResult`,
`SetupFailure`, `Logger`, `Log`, `LogLevel`, `Database`, `Connection`,
`Statement`, `Value`, managed scalar and aggregate callback value/result/context types,
`Arity`, `ExtensionResultCode`, `ExtensionTextSubtype`, `Step`, `ColumnKind`,
`Error`, `ConstructionFailure`, and the explicitly unstable raw `c` namespace. Setup validates bounded strings and
returns owned native diagnostics. Its first successful process-global level
wins; later successful setup calls may replace only the process-lifetime plain
logger function pointer. Logger calls may be concurrent, record slices are
invocation-borrowed, and malformed or same-thread reentrant records are
dropped. Database configuration covers the local path and
the optional 0.7.1 experimental-feature, VFS, and encryption strings while
forcing `async_io = 0`. Connection methods expose prepare-first/single, busy
timeout, autocommit, last insert rowid, close, and deinit. Statement methods
cover positional binds, execute/step, parameter and column metadata, copied row
values, changes, reset, finalize, and deinit.

Managed scalar functions use heap-stable typed contexts and bounded borrowed
arguments. Native ownership is authoritative only after raw `TURSO_OK`; earlier
failure leaves context cleanup with the caller. A heap-stable connection guard
blocks callback and context-deinitializer reentry through every connection and
statement operation without another native call. Replacement, unregister,
delayed prepared-program release, and connection teardown determine context
destruction. Turso 0.7.1 loses JSON subtype on SQL callback arguments and cannot
supply ERROR arguments; those decoder cases remain ABI-defensive. JSON results
and text/blob/error results are copied into at most 16 MiB of package-owned
backing and released by the always-supplied value destructor.

Managed aggregates add a typed per-group state initialized into heap-stable
boxes. Step/final callbacks reuse the scalar argument/result codec and always
supply the value destructor. Turso 0.7.1 statement reset and teardown can
replace aggregate registers without invoking `aggregate_destructor`, so each
registration owns a bounded 4096-live-state registry. Native destruction
removes and frees normal state exactly once; registration destruction runs only
after native programs can no longer refer to the boxes and reclaims abandoned
state. Repeated step/final calls and pointers absent from the live registry
return managed errors without dereferencing the candidate state.

Defer cloud sync, collations, loadable extensions, and async I/O. Each deferred
area requires a separate ownership, scheduler, or trust-boundary design.

## 2. Treat `turso.h` as the ABI source of truth

Read the vendored header copied unchanged from Turso
[`v0.7.1`](https://github.com/tursodatabase/turso/blob/v0.7.1/sdk-kit/turso.h)
beside any FFI work. The relevant groups are:

| Need | C ABI entry points |
| --- | --- |
| Process configuration | `turso_setup`, `turso_version` |
| Database lifecycle | `turso_database_new`, `turso_database_open`, `turso_database_connect`, `turso_database_deinit` |
| Connection lifecycle | `turso_connection_prepare_first`, `turso_connection_prepare_single`, `turso_connection_close`, `turso_connection_deinit` |
| Execution | `turso_statement_execute`, `turso_statement_step`, `turso_statement_reset`, `turso_statement_finalize`, `turso_statement_run_io` |
| Binding | `turso_statement_bind_positional_*`, `turso_statement_named_position` |
| Results | `turso_statement_row_value_*`, `turso_statement_column_*` |
| Allocated diagnostics/metadata | `turso_str_deinit` |

The 0.7.1 native `turso_connection_prepare_single` accepts a second statement
and silently ignores it despite the header's single-statement wording. The safe
Zig `prepareSingle` wrapper therefore uses `turso_connection_prepare_first`,
checks that the returned byte offset is within the input, and rejects non-space
trailing SQL. `prepareFirst` exposes the same checked byte offset directly.

Start with `@cImport` of the header, compiled with the same target ABI as the
native Turso library. Do not hand-transcribe C enums, structs, function-pointer
signatures, or `size_t` widths merely to make the first build pass. A
hand-maintained Zig declaration layer is reasonable later, but it needs an ABI
comparison test against `turso.h`.

## 3. Make ownership explicit at the FFI boundary

The C API uses opaque pointers. Zig wrappers should contain only the native
pointer and should be non-copyable by convention and API design.

- A database returned through `turso_database_new` is owned until
  `turso_database_deinit`.
- A connection returned through `turso_database_connect` is owned until
  `turso_connection_deinit`; call `turso_connection_close` when the public API
  needs an explicit early-close operation.
- A statement returned through either prepare function is owned until
  `turso_statement_deinit`. Use `reset` for reuse and `finalize` when ending
  execution, according to the documented statement state machine.
- Strings returned by metadata functions and error out-parameters must be
  released with `turso_str_deinit` after copying them into Zig-owned memory.
- Text/blob pointers from `turso_statement_row_value_bytes_ptr` are borrowed
  only until the next statement operation. Copy before stepping, resetting,
  finalizing, or deinitializing.
- Text/blob values passed to positional bind functions are borrowed for the
  call. Keep the slice valid through that call and check its length fits the C
  `size_t` parameter.

Every public wrapper method must map a non-success `turso_status_code_t` into a
Zig error and, if supplied, copy and free `error_opt_out`. Never expose that
pointer to application code.

Use `defer` immediately after acquiring each native handle in examples and
tests. Assert local invariants at the boundary: a handle is non-null, indexes
fit the ABI type, only valid value tags are decoded, and a wrapper is not used
after `deinit`.

## 4. Keep v0 synchronous

Set `turso_database_config_t.async_io` to zero for v0. The C API may return
`TURSO_IO` when async I/O is enabled; progress then requires repeated,
state-aware calls to `turso_statement_run_io`. That state machine should be a
separate feature with its own executor integration and tests. Do not hide it in
a blocking retry loop.

## 5. Verification

`tests/sdk_test.zig` implements the observable contract matrix: lifecycle and
raw ABI smoke coverage; all supported values including NULL and empty
text/blob; copied-value lifetime; row iteration and reset; metadata; parse and
constraint diagnostics; commit/rollback state; file persistence; invalid
indexes; close ordering; and early row-loop cleanup.

Run the full supported workflow with Zig 0.16.0 and a matching v0.7.1 library:

```bash
zig build test -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release -Dturso-linkage=dynamic
zig build run-example -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release -Dturso-linkage=dynamic
zig fmt --check build.zig src tests examples
git diff --check
```

For SQLite-compatible SQL semantics, add scenarios to Turso's SQL conformance
suite when they exercise engine behavior. Keep Zig tests focused on the
binding's public ownership, conversion, and error contract.

## 6. Expand only with dedicated designs

- **Cloud sync:** map remote URL, auth token, push/pull/checkpoint, and sync
  statistics after identifying the corresponding supported C ABI surface.
- **Callbacks:** collations require a separate ordering and ownership design;
  scalar and aggregate support does not imply that contract.
- **Extensions:** default disabled; enabling loading changes the application's
  trust boundary.
- **Async I/O:** expose progress without blocking an event loop and define
  cancellation plus cleanup behavior.
