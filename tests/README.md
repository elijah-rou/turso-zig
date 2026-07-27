# SDK tests

`tests/sdk_test.zig` exercises the public synchronous API against the supplied
Turso SDK Kit runtime. Dedicated `setup_*.zig` executables isolate native
process-global, non-resettable tracing state. Together they verify the safe
0.7.1 runtime version accessor, exhaustive log levels, owned invalid-setup
diagnostics, token validation and input-lifetime handling, logger records and
replacement, rejected setup reentry, and first-successful-level behavior, plus
the raw ABI smoke
path, database/connection/statement cleanup, positional values (including
NULL and empty text/blob), copied-value lifetime, metadata, reset and reuse,
prepare tails, transaction state, diagnostics, constraint errors, file reopen
persistence, and early row-loop cleanup under Zig's leak-detecting test
allocator. Caller-driven coverage includes the public progress contract and an
internal test root for pending/retry transitions, status-before-diagnostic
ordering, repeated or failed `runIo`, reset/deinit quiescence, row invalidation,
and terminal open/finalize state. Managed scalar coverage includes arity
mismatch, fixed arity 127,
variadic multi-argument calls, both determinism options, runtime scalar values,
JSON argument subtype loss, JSON results, every result code, malformed defensive
ABI input (including source-level JSON/error tags), OOM/oversize output,
replacement/unregister/prepared-program/connection context lifetime, reentry
through connection and statement operations, and name/arity validation.
Managed aggregate coverage adds group-state retirement and exact state/context
cleanup. Managed collation coverage includes ASCII, non-ASCII UTF-8, empty
text, equality and ordering, per-connection scope, name validation,
replacement/unregister/teardown ownership, allocation failure, prepared and
partially executed statement mutation gates, malformed ABI inputs, and
comparator/deinitializer reentry. Extension coverage includes the per-connection
SQL capability gate, the explicitly unsafe direct-loader signature, absolute
UTF-8 path validation at the 4095-byte boundary, isolated missing-path errors,
and prepared binding of the pinned positive fixture path. The positive fixture
runs in a dedicated executable; tests never continue after a loaded extension
reports failure. Turso 0.7.1 cannot supply managed ERROR callback arguments at
SQL runtime.

Run the complete suite with Zig 0.16.0 and a native library built from Turso
tag `v0.7.1`:

```bash
zig build test \
  -Dturso-lib-dir=/absolute/path/to/turso-v0.7.1/target/release \
  -Dturso-linkage=dynamic
```

The vendored 0.7.1 header and loaded library are one ABI unit. Do not use a
library built from current Turso `main`. Dynamic Ubuntu x86_64 is the verified
configuration; static and other operating systems are not runtime-qualified.

Tests focus on observable wrapper ownership, conversion, lifetime, and error
contracts. SQL engine conformance belongs in Turso's SQL conformance suites,
not in symbol-presence tests here.
