# Implementing the Zig binding

## 1. Frozen v0 contract

v0 is an **embedded/local, synchronous** binding built with Zig 0.16.0. The
first verified target is x86_64 Linux with glibc; other targets are unsupported
until their matching native artifact and loader behavior pass runtime tests.
The package supports the core prepared-statement workflow:

- open `:memory:` or a filesystem path;
- create a connection;
- prepare exactly one SQL statement;
- bind `null`, integers, floats, text, and blobs by position;
- execute mutations or step query rows;
- expose row values as a tagged Zig union; and
- release statement, connection, and database handles explicitly.

Public fallible operations return one exhaustive Zig error set. Each owning
wrapper retains the latest Turso diagnostic as allocator-owned bytes for
inspection until the next fallible operation or `deinit`. Before every fallible
operation, the wrapper frees and clears its previous diagnostic. A construction
failure has no wrapper in which to retain a message, so constructors return a
small failure payload containing the Zig error category and the owned Turso
diagnostic. The caller owns that payload and must deinitialize it.

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

Defer cloud sync, user-defined scalar/aggregate functions, collations,
loadable extensions, and async I/O. Each requires a separate ownership,
scheduler, or trust-boundary design.

## 2. Treat `turso.h` as the ABI source of truth

Read the vendored header copied unchanged from Turso
[`v0.7.1`](https://github.com/tursodatabase/turso/blob/v0.7.1/sdk-kit/turso.h)
beside any FFI work. The relevant groups are:

| Need | C ABI entry points |
| --- | --- |
| Process configuration | `turso_setup`, `turso_version` |
| Database lifecycle | `turso_database_new`, `turso_database_open`, `turso_database_connect`, `turso_database_deinit` |
| Connection lifecycle | `turso_connection_prepare_single`, `turso_connection_close`, `turso_connection_deinit` |
| Execution | `turso_statement_execute`, `turso_statement_step`, `turso_statement_reset`, `turso_statement_finalize`, `turso_statement_run_io` |
| Binding | `turso_statement_bind_positional_*`, `turso_statement_named_position` |
| Results | `turso_statement_row_value_*`, `turso_statement_column_*` |
| Allocated diagnostics/metadata | `turso_str_deinit` |

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
- A statement returned through `turso_connection_prepare_single` is owned until
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

## 5. Add behavioral tests

Use a temporary database or `:memory:` and test these externally visible
contracts, in order:

1. Create/open/close and a simple DDL statement.
2. Bind and read every supported value class, including `NULL`, empty text, and
   an empty blob.
3. Iterate multiple rows, then reset and reuse a statement.
4. Report SQL and constraint failures without leaking returned diagnostics.
5. Transactions: rollback and commit observable data changes.
6. Invalid usage the safe API claims to reject, such as a dead wrapper or an
   out-of-range column index.

For SQLite-compatible SQL semantics, add scenarios to
`sqlite/conformance/sqlite-sqltests/` when they exercise an engine behavior.
Keep Zig tests focused on the binding's public ownership, conversion, and error
contract.

## 6. Expand only with dedicated designs

- **Cloud sync:** map remote URL, auth token, push/pull/checkpoint, and sync
  statistics after identifying the corresponding supported C ABI surface.
- **Callbacks:** scalar functions, aggregates, and collations require stable
  callback trampolines, context ownership, and panic containment across the C
  boundary. Design this separately.
- **Extensions:** default disabled; enabling loading changes the application's
  trust boundary.
- **Async I/O:** expose progress without blocking an event loop and define
  cancellation plus cleanup behavior.
