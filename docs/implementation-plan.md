# Implementing the Zig binding

## 1. Fix the v0 contract before writing FFI

The initial package should be an **embedded/local** database binding, matching
the core prepared-statement workflow:

- open `:memory:` or a filesystem path;
- create a connection;
- prepare exactly one SQL statement;
- bind `null`, integers, floats, text, and blobs by position;
- execute mutations or step query rows;
- expose row values as a tagged Zig union; and
- release statement, connection, and database handles deterministically.

Defer cloud sync, user-defined scalar/aggregate functions, collations,
loadable extensions, and an async facade. Each introduces callbacks, retained
context, or scheduler concerns that should not obscure the basic ownership
model.

Before implementation, choose and document:

1. Confirm the scaffold's minimum Zig version and the supported target triples.
2. Whether public methods return errors only, or errors plus Turso's diagnostic
   message.
3. Whether rows borrow statement memory or copy text/blob data. For v0, copy
   them. This is safer and matches the C ABI lifetime.
4. The concurrency contract. The C header says connections and statements are
   exclusive-use handles. Do not market the Zig wrapper as thread-safe without
   an explicit synchronization design.

## 2. Treat `turso.h` as the ABI source of truth

Read Turso's [`sdk-kit/turso.h`](https://github.com/tursodatabase/turso/blob/main/sdk-kit/turso.h)
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
