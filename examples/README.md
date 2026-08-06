# Examples

`basic.zig` is the runnable synchronous SDK example. It initializes a
leak-checking allocator, rejects a loaded runtime outside the 0.7.1-compatible
version family, opens `:memory:`, creates a table, inserts positional text and
integer values, streams rows, inspects and frees copied `Value`s, and prints an
owner's retained SQL diagnostic when a native operation fails.

The example finalizes and deinitializes statements, then closes and
deinitializes the connection, then deinitializes the database. This
reverse-acquisition order is required because each native owner must outlive
its children. Owners are non-copyable by contract and connections/statements
are synchronous, exclusive-use values.

Run with Zig 0.16.0 and a matching Turso tag `v0.7.1` dynamic library:

```bash
zig build run-example \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
```

The consumer build does not invoke Cargo. Dynamic Ubuntu x86_64 is verified;
static linkage and other operating systems are not runtime-qualified. The
example contains no authentication tokens, remote URLs, or generated native
binaries.
