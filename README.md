# Turso for Zig

An early synchronous Zig 0.16.0 SDK for Turso embedded/local databases. The
implemented API exposes the runtime version and process-global tracing setup,
opens local databases, prepares statements, binds positional values, executes
SQL, streams rows, copies typed values, exposes metadata and transaction state,
registers managed scalar and aggregate functions and collations, and retains
native diagnostics.

The first verified runtime is Ubuntu x86_64 with glibc and dynamic linking.
macOS, Windows, cloud sync, loadable extensions, and async I/O are not yet
supported. Process-global tracing callbacks and managed scalar, aggregate, and
collation SQL callbacks are supported as described below.

## Native library requirement

This package vendors `turso.h` from Turso tag `v0.7.1`. Supply a
`turso_sdk_kit` library built from that same tag. A current `main` or 0.8
pre-release library is not ABI-compatible merely because it links.

Every compile or run command requires an absolute library directory:

```bash
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
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

Connections and statements are exclusive-use. The API is synchronous and adds
no locking or hidden thread synchronization. Database sharing is limited to
what the C API permits, and a database must outlive all of its connections.

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
