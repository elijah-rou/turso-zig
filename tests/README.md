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
allocator. Managed scalar coverage includes fixed and variadic arity, both
determinism options, every callback value and result code, malformed ABI input,
OOM/oversize output, replacement/unregister/prepared-program/connection context
lifetime, repeated calls, and name/arity validation.

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
