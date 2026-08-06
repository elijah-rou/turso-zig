# Turso for Zig

An early Zig 0.16.0 SDK for Turso embedded/local databases. Synchronous
library-driven I/O remains the default; caller-driven statement progress is an
explicit opt-in. The implemented API exposes the runtime version and process-global tracing setup,
opens local databases, prepares statements, binds positional values, executes
SQL, streams rows, copies typed values, exposes metadata and transaction state,
registers managed scalar and aggregate functions and collations, controls SQL
extension loading, exposes an explicitly unsafe native-extension trust boundary,
and retains native diagnostics.

The first verified runtime is Ubuntu x86_64 with glibc and dynamic linking.
Loadable extensions are qualified only on that Linux dynamic path. macOS,
Windows and cloud sync are not yet supported. Caller-driven I/O is qualified
only for the backend limits described below. Process-global tracing callbacks
and managed scalar, aggregate, and collation SQL callbacks are supported.

## Native library requirement

This package vendors `turso.h` from Turso tag `v0.7.1`. Supply a
`turso_sdk_kit` library built from that same tag. A current `main` or 0.8
pre-release library is not ABI-compatible merely because it links.

Every compile or run command requires an absolute library directory:

```bash
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
# Optional maintainer parity fixture, used only by the extension test executable:
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic \
  -Dturso-extension-path=/absolute/path/to/liblimbo_regexp.so
zig build run-example \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
zig fmt --check build.zig src tests examples
git diff --check
```

`-Dturso-linkage` defaults to `dynamic`. Dynamic linking is runtime-tested on
Ubuntu. Static selection is implemented, but its Rust and platform system
library closure is not enumerated or supported yet. `build.zig` never invokes
Cargo, falls back to `pkg-config`, or searches for an arbitrary system Turso
library. Tests and the example reject a runtime version outside the 0.7.1 ABI
version family (`0.7.1`, `0.7.1-*`, or `0.7.1+*`).

## Native extension controls

`Connection.setSqlExtensionLoadingEnabledUnsafe` controls the SQL
`load_extension()` function per connection. It is disabled by default, enabling
one connection does not affect another, and disabling it restores rejection.
Enabling the gate authorizes every component that can submit SQL on that
connection to execute native code. It is not a per-statement or per-caller
capability.

`Connection.loadExtensionUnsafe` is the direct ABI trust-boundary adapter and
deliberately bypasses the SQL gate. It executes trusted arbitrary native code
with the process's full privileges; Zig cannot make extension code memory-safe.
It requires a nonempty absolute UTF-8 path of at most 4095 bytes with no NUL.
There is no safe alias, sandbox, or unload operation. Both controls reject
callback/deinitializer reentry and mutation while any statement exists.

Turso's native resolution first checks the supplied path and, when it is absent
and has no shared-library suffix, may append the platform suffix. The direct Zig
method still requires that supplied path to be absolute. SQL `load_extension()`
passes SQL text through native resolution without that programmatic absolute-path
restriction, so relative or bare SQL arguments remain native behavior. Neither
path invokes Cargo or searches arbitrary library directories.

Native v0.7.1 loading is not transactional. Extension registration can mutate
function/module tables before reporting failure, after which native code may be
unloaded; schema refresh can also fail after a successful registration. Any
failure after a library was loaded is not safely recoverable. Terminate the
process without using the connection or partially registered symbols. A
successful library is retained for process lifetime, so connection close does
not unload it.

Positive integration is qualified only for Linux dynamic linking with the exact
Turso v0.7.1 `limbo_regexp` cdylib. Consumer builds never run Cargo. Ordinary
`zig build test` remains available without the optional fixture path; CI always
builds the pinned fixture and supplies its absolute path to the isolated
extension test executable.

## Caller-driven I/O

`Database.Config.io_mode` defaults to `.library_driven`, preserving the
synchronous `open`, `Statement.execute`, `step`, and `finalize` behavior. Opt in
with `.caller_driven`, then use `openProgress`, `executeProgress`,
`stepProgress`, `finalizeProgress`, and one-step `runIo`. Progress methods never
loop: an operation returning `.needs_io` must be followed by exactly one
successful `runIo`, then a retry of that same operation. `runIo` returning
success does not mean the SQL operation is done. `reset` and `deinit` are the
explicit cancellation/teardown routes for pending native work. Unlike progress
methods, Turso 0.7.1 cleanup may synchronously drain pending I/O before aborting;
`reset` clears wrapper progress only after native success, while `deinit` always
releases the native statement and sidecar. A statement operation invalidates the
current row even when it is rejected or reports `.needs_io`.

Caller-driven construction accepts only the source-proven default, `memory`,
or `syscall` VFS selection. It rejects `io_uring`,
`experimental_win_iocp`, and extension or unknown VFS names. Turso SDK Kit
0.7.1 can return `TURSO_IO` from `turso_database_open`, but its C ABI exposes no
database `run_io`. Therefore `openProgress` returns the terminal
`.needs_io_without_driver` result if opening needs I/O, retains an explicit
diagnostic, and does not permit `connect`. It does not retry, block, or spin.
This ABI gap is tracked upstream in
[tursodatabase/turso#8043](https://github.com/tursodatabase/turso/issues/8043).
The in-memory backend is runtime-tested and currently completes without a
runtime I/O transition; tests do not claim that `runIo` path as observed there.

## Setup and logging

`version()` returns the native process-lifetime version string after validating
the native pointer and a bounded terminator. `setup(allocator, config)` returns
either `.success` or an allocator-owned `SetupFailure`; deinitialize failures
with the same allocator. `log_level` accepts `error`, `warn`, `info`, `debug`,
or `trace` and rejects embedded NUL bytes.

Setup is process-global. The first successful call fixes the native level
filter; later successful calls may replace the logger but cannot change that
filter. `Logger` is a plain process-lifetime function pointer with no captured
context. Native threads may call it concurrently. Each `Log` string slice is
borrowed only for that invocation, so copy data that must outlive the call. A
logger must be thread-safe, non-panicking, and must not retain borrowed slices.
The wrapper drops malformed, unknown-level, and same-thread reentrant records.

```zig
fn logger(log: turso.Log) void {
    std.debug.print("[{s}] {s}\n", .{ @tagName(log.level), log.message });
}

var setup_result = try turso.setup(allocator, .{
    .log_level = "info",
    .logger = logger,
});
switch (setup_result) {
    .success => {},
    .failure => |*failure| {
        defer failure.deinit(allocator);
        return failure.category;
    },
}
```

## Managed scalar functions

`Connection.registerScalarFunction` installs fixed-arity or variadic callbacks
with an owned typed context. Runtime callback arguments are invocation-borrowed
NULL, integer, float, text, or blob values. Turso 0.7.1 loses JSON subtype on
arguments and cannot deliver a managed ERROR as an argument; the decoder still
handles both ABI tags defensively. Returned text, JSON, blob, and error messages
are copied into at most 16 MiB of allocator-owned backing and released after
Turso copies them.

Callbacks and context deinitializers must not panic or re-enter their owning
connection or its statements. Reentry is rejected without crossing the C
boundary and makes an active callback return a managed SQL error. Native ownership begins only after successful registration. Before success, the
caller retains context ownership. Because Turso 0.7.1 prepared programs copy
function entries without retaining their registration ownership, every scalar
or aggregate registration, replacement, and `unregisterFunction` call returns
`InvalidState` while any statement exists on the connection. After all
statements are deinitialized, replacement, unregister, or connection teardown
calls the context deinitializer exactly once.

## Managed aggregate functions

`Connection.registerAggregateFunction` takes an `AggregateFunction(Context,
State)`. Its typed registration context initializes one heap-stable state per
SQL group; `step` receives invocation-borrowed arguments, `final` returns a
copied managed result, and optional state/context deinitializers run exactly
once. A null initializer result or wrapper allocation failure becomes a managed
SQL error rather than a null dereference.

Turso 0.7.1 can repeat an aggregate destructor for window programs, reuse the
same state afterward, and discard an external aggregate register during reset
or teardown without invoking that destructor. Each registration therefore
retains a bounded registry of at most 4096 stable state boxes. Native destructor
notifications are idempotent; state remains usable for later window step/final
calls and its deinitializer runs exactly once when the connection's active
statement count reaches zero or during zero-statement context destruction.
Exhausting the retained-state bound returns a managed out-of-range error before
state initialization or allocation.
Aggregate callbacks and both deinitializers share the same non-reentry and
non-panicking contract as scalar callbacks.

## Managed collations

The public `Collation(Context)` export defines a typed context, comparison
callback, and optional context deinitializer. `Connection.registerCollation`
installs or replaces a named collation for that connection;
`Connection.unregisterCollation` removes it and succeeds when the name is
absent. Native ownership begins only after successful registration. Replacement,
unregistration, or connection teardown invokes the context deinitializer
exactly once.

Comparison inputs are invocation-borrowed UTF-8 slices. Comparison callbacks
and context deinitializers must not panic or re-enter the owning connection or
any of its statements. Reentry is rejected before another native call; getter
paths return their documented neutral sentinel and record the violation.
Registration, replacement, and unregistration return `InvalidState` while any
statement exists on the connection, so native cannot retain a retired context.

Managed collations are verified for expression comparison and explicit
`ORDER BY ... COLLATE` sorting. Schema declarations, indexes, uniqueness
constraints, and persisted schema behavior using managed collation names are
not supported or claimed by this contract.

## Basic use

```zig
var result = try turso.Database.create(allocator, .{ .path = ":memory:" });
var database = switch (result) {
    .success => |value| value,
    .failure => |*failure| {
        defer failure.deinit(allocator);
        return failure.category;
    },
};
defer database.deinit();
try database.open();

var connection = try database.connect();
defer connection.deinit();
var statement = try connection.prepareSingle("SELECT ?1");
defer statement.deinit();
try statement.bindText(1, "hello");
if (try statement.step() == .row) {
    var value = try statement.value(0);
    defer value.deinit(allocator);
}
try statement.finalize();
```

See [`examples/basic.zig`](examples/basic.zig) for a runnable program with
runtime-version checking and diagnostic reporting.

## Ownership and scope

`Database`, `Connection`, and `Statement` are owning, non-copyable-by-contract
values. Pass pointers to them after construction; copying an active owner would
alias a native handle and is forbidden. Destroy statements before their
connection and connections before their database. Finalize a statement when
ending execution. `Connection.close` is an optional early shutdown that prevents
later operations; `Connection.deinit` also closes and always releases the handle.
Call each owner's `deinit` exactly once in reverse acquisition order.

Connections and statements are exclusive-use. The API adds no locking or hidden
thread synchronization. Caller-driven progress methods perform one native step
and never loop; pinned library-driven operations and native reset/drop internals
may loop while draining I/O. Database sharing is limited to what the C API
permits, and a database must outlive all of its connections.

`Statement.value` returns a `Value`. Text and blob variants are allocator-owned
copies that remain valid across later statement operations; call `Value.deinit`
to free them. Bound text/blob slices are borrowed only for the bind call.
Copied metadata strings are also caller-owned and must be freed with the
statement allocator.

Before an operation that can return a Turso diagnostic, its owner clears the
previous diagnostic, then retains a copied diagnostic on failure until the
next such operation or `deinit`. Read it with `latestDiagnostic()`. Database
construction failures instead return an owned `ConstructionFailure`; call its
`deinit`.

See [`docs/implementation-plan.md`](docs/implementation-plan.md) for the exact
v0 contract and [`docs/distribution.md`](docs/distribution.md) for native
artifact requirements. This project is licensed under the [MIT License](LICENSE).
