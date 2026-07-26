# Test plan

Do not add tests that merely prove wrapper internals exist. Start with observable
behavior against a local Turso database, then run the same SQL scenarios through
SQLite where the behavior is expected to be compatible.

The ordered test matrix is in
[`../docs/implementation-plan.md`](../docs/implementation-plan.md#5-add-behavioral-tests).
