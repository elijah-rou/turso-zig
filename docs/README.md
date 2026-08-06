# Zig SDK implementation notes

This directory contains design, parity, and release guidance. The implementation lives in `src/`.

- [`abi-parity.md`](abi-parity.md): cell-for-cell generated/validated classification of all 48 public functions and 27 public typedefs.
- [`implementation-plan.md`](implementation-plan.md): ordered implementation
  plan, API boundary, C-ABI ownership rules, and tests.
- [`distribution.md`](distribution.md): options for making the Turso native
  library available to Zig consumers and the release matrix.

The source-of-truth native interface is Turso's
vendored SDK Kit 0.7.1 `turso.h` (upstream tag [`v0.7.1`](https://github.com/tursodatabase/turso/blob/v0.7.1/sdk-kit/turso.h)).
Treat it as an ABI contract: do not infer ownership or valid handle state from
another language binding.
