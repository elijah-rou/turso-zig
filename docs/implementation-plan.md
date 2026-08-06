# Implementing the Zig binding

## 1. Implemented v0 contract

v0 is an **embedded/local** binding built with Zig 0.16.0. Library-driven
synchronous I/O is the default, with explicit opt-in caller-driven statement
progress. The
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
`Statement`, `Value`, managed scalar and aggregate callback value/result/context
types, `Collation`, `Arity`, `ExtensionResultCode`, `ExtensionTextSubtype`,
`Step`, `ColumnKind`, `IoMode`, the progress result types, `Error`,
`ConstructionFailure`, and the explicitly
unstable raw `c` namespace. Setup validates bounded strings and
returns owned native diagnostics. Its first successful process-global level
wins; later successful setup calls may replace only the process-lifetime plain
logger function pointer. Logger calls may be concurrent, record slices are
invocation-borrowed, and malformed or same-thread reentrant records are
dropped. Database configuration covers the local path and
the optional 0.7.1 experimental-feature, VFS, and encryption strings plus an
I/O mode that maps explicitly to `async_io`. Connection methods expose
prepare-first/single, busy timeout, autocommit, last
insert rowid, managed collation registration/unregistration, per-connection SQL
extension gating, explicitly unsafe direct trusted-extension loading, close,
and deinit.
Statement methods cover positional binds, synchronous and caller-progress
execute/step/finalize, one-step `runIo`, parameter and column metadata, copied
row values, changes, reset, and deinit.

Managed scalar functions use heap-stable typed contexts and bounded borrowed
arguments. Native ownership is authoritative only after raw `TURSO_OK`; earlier
failure leaves context cleanup with the caller. A heap-stable connection guard
blocks callback and context-deinitializer reentry through every connection and
statement operation without another native call. Replacement, unregister, and
connection teardown determine context destruction. Turso 0.7.1 prepared
programs copy function entries without
retaining registration ownership, so the safe API rejects every scalar or
aggregate registration, replacement, and unregister operation while any
statement exists on that connection. Turso 0.7.1 loses JSON subtype on SQL
callback arguments and cannot supply ERROR arguments; those decoder cases
remain ABI-defensive. JSON results
and text/blob/error results are copied into at most 16 MiB of package-owned
backing and released by the always-supplied value destructor.

Managed aggregates add a typed per-group state initialized into heap-stable
boxes. Step/final callbacks reuse the scalar argument/result codec and always
supply the value destructor. Turso 0.7.1 can reuse aggregate state after an
`aggregate_destructor` notification in window programs and can omit that
notification during reset or teardown. Each registration therefore owns a
bounded registry of 4096 stable state boxes until all statements are gone.
Destructor notifications are idempotent, later window step/final calls remain
valid, and statement quiescence runs each state deinitializer exactly once
before freeing its box. Zero-statement context destruction also performs
reclamation before removing its registration from the explicit heap-stable
connection list. The 4097th retained state fails with managed out-of-range
before initialization or allocation.

Managed collations use heap-stable typed contexts and invocation-borrowed UTF-8
comparison inputs. Native owns a context only after raw `TURSO_OK` registration;
replacement, explicit unregistration, and connection teardown destroy it
exactly once. Comparator and context-deinitializer reentry through the owning
connection or its statements is rejected before native access, with neutral
getter sentinels recording a callback violation. Every collation table mutation
is rejected while any statement exists, preventing native programs from
retaining a retired context. The verified SQL scope is expression comparison
and explicit sorting. Schema declarations, indexes, uniqueness constraints,
and persisted schemas that name managed collations remain explicitly unclaimed.

Extension loading is disabled through SQL by default and enabled per
connection only through `setSqlExtensionLoadingEnabledUnsafe`. Enabling it
authorizes every SQL submitter on that connection to execute native code.
`loadExtensionUnsafe` bypasses the SQL gate and is the full
ABI trust-boundary adapter, not a safe recoverable wrapper. It requires a
nonempty absolute UTF-8 path of at most 4095 bytes without NUL. SQL arguments
have no Zig absolute-path restriction. Native resolution checks the supplied
path and may append the platform shared-library suffix when the path is absent
and has no such suffix.

Both controls reject managed-callback reentry and active-statement mutation.
Loading executes arbitrary native code that Zig cannot make memory-safe; there
is no sandbox or unload operation. Turso v0.7.1 registration and schema refresh
are nontransactional. Registration may partially mutate native tables and then
fail while unloading the library, and schema refresh may fail after successful
registration. Any failure after native loaded a library requires process
termination rather than continued use of the connection or registrations.
Successful libraries remain loaded for process lifetime. Runtime qualification
is limited to Linux dynamic linking with the pinned v0.7.1 regexp fixture.

Defer cloud sync and executor integration. Each deferred area requires a
separate ownership or scheduler design.

## 2. Treat `turso.h` as the ABI source of truth

Read the vendored header copied unchanged from Turso
[`v0.7.1`](https://github.com/tursodatabase/turso/blob/v0.7.1/sdk-kit/turso.h)
beside any FFI work. The relevant groups are:

| Need | C ABI entry points |
| --- | --- |
| Process configuration | `turso_setup`, `turso_version` |
| Database lifecycle | `turso_database_new`, `turso_database_open`, `turso_database_connect`, `turso_database_deinit` |
| Connection lifecycle | `turso_connection_prepare_first`, `turso_connection_prepare_single`, `turso_connection_close`, `turso_connection_deinit` |
| Extension controls | `turso_connection_enable_load_extension`, `turso_connection_load_extension` |
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

## 4. Keep I/O ownership explicit

Keep `async_io = 0` for the default `.library_driven` mode. Caller-driven mode
sets it to one and exposes each native statement progress operation as one call.
After `TURSO_IO`, require one `turso_statement_run_io` call returning `TURSO_OK`,
then a retry of the same operation. Record native I/O, completion, finalization,
and database-open states before fallible diagnostic handling. Do not map
`TURSO_OK` to statement completion and do not hide retries in progress methods.
Pinned library-driven operations and native reset/drop internals may drain I/O
in loops.

Caller-driven `reset` and `deinit` are explicit cancellation/teardown routes
for awaiting-I/O and retry-required operations. Native reset/drop internals may
synchronously drain I/O while aborting, so only the progress methods guarantee
one native iteration per call. `reset` clears sidecar progress after native
success; `deinit` always removes and frees the sidecar after native teardown.

The 0.7.1 C ABI has no database I/O driver even though `turso_database_open`
can return `TURSO_IO`. Restrict caller-driven configurations to default,
`memory`, and `syscall` source-proven backends; reject asynchronous and custom
VFS choices. If open still returns `TURSO_IO`, surface terminal
`needs_io_without_driver`, retain a diagnostic, and forbid connection. Track the
ABI fix in [tursodatabase/turso#8043](https://github.com/tursodatabase/turso/issues/8043).

## 5. Verification

`tests/sdk_test.zig` implements the observable contract matrix: lifecycle and
raw ABI smoke coverage; all supported values including NULL and empty
text/blob; copied-value lifetime; row iteration and reset; metadata; parse and
constraint diagnostics; commit/rollback state; file persistence; invalid
indexes; close ordering; and early row-loop cleanup.

Run the full supported workflow with Zig 0.16.0 and a matching v0.7.1 library:

```bash
zig build test -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release -Dturso-linkage=dynamic
zig build test -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release -Dturso-linkage=dynamic -Dturso-extension-path=/absolute/path/to/liblimbo_regexp.so
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
- **Callbacks:** extend only after defining ownership and mutation safety for
  each additional callback family; managed scalar, aggregate, and collation
  contracts do not imply support for other callback ABIs.
- **I/O executors:** integrate explicit progress with event loops only after
  defining cancellation and cleanup behavior; never add hidden retries.
