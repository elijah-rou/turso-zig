# Turso for Zig

An early synchronous Zig 0.16.0 SDK for Turso embedded/local databases. The
implemented API opens local databases, prepares statements, binds positional
values, executes SQL, streams rows, copies typed values, exposes metadata and
transaction state, and retains native SQL diagnostics.

The first verified runtime is Ubuntu x86_64 with glibc and dynamic linking.
macOS, Windows, cloud sync, callbacks, extensions, and async I/O are not yet
supported.

## Native library requirement

This package vendors `turso.h` from Turso tag `v0.7.1`. Supply a
`turso_sdk_kit` library built from that same tag. A current `main` or 0.8
pre-release library is not ABI-compatible merely because it links.

Every build command requires an absolute library directory:

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
ending execution, close a connection when ending use, then call each owner's
`deinit` exactly once in reverse acquisition order.

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
