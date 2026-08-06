# Turso SDK Kit 0.7.1 ABI parity

This audit classifies all **48 public functions** and **27 public typedefs** in the vendored 554-line `turso.h`. `zig build abi-parity` compile-references every raw declaration and mapped Zig API, checks declaration-set equality, ABI layout/tags/callback calling conventions, and verifies this table against `src/abi_parity.zig`.

Ordinary raw function signatures come from `@cImport` of that header; CI byte-compares the header with pinned upstream source. The manifest independently checks mapped Zig adapter signatures, but does not duplicate all 48 C prototypes as a second signature source.

No callable C entry point is silently raw-only. `prepare_single` deliberately maps to the safer prepare-first adapter. Internal ownership rows are implementation carriers used only behind safe public operations.

## Functions

| C declaration | Disposition | Zig API(s) | Rationale | Issue/exception |
| --- | --- | --- | --- | --- |
| `turso_connection_close` | `safe_wrapper` | `Connection.close` | Checked close ordering and retained diagnostics. | none |
| `turso_connection_deinit` | `internal_ownership` | `Connection.deinit` | Owning handle teardown in reverse acquisition order. | none |
| `turso_connection_enable_load_extension` | `trust_boundary_adapter` | `Connection.setSqlExtensionLoadingEnabledUnsafe` | Explicit unsafe capability grant to every SQL submitter on the connection. | unsafe native-code trust boundary |
| `turso_connection_get_autocommit` | `safe_wrapper` | `Connection.autocommit` | Reentry-safe transaction-state accessor. | none |
| `turso_connection_last_insert_rowid` | `safe_wrapper` | `Connection.lastInsertRowid` | Reentry-safe rowid accessor. | none |
| `turso_connection_load_extension` | `trust_boundary_adapter` | `Connection.loadExtensionUnsafe` | Explicit arbitrary-native-code trust boundary; no sandbox or safe alias. | unsafe native-code trust boundary |
| `turso_connection_prepare_first` | `safe_wrapper` | `Connection.prepareFirst` | Checked tail offset and owned statement. | none |
| `turso_connection_prepare_single` | `safer_adapter` | `Connection.prepareSingle` | Deliberately uses prepare_first and rejects trailing SQL because native prepare_single ignores it. | none |
| `turso_connection_register_aggregate_function` | `safe_wrapper` | `Connection.registerAggregateFunction` | Managed typed context and bounded per-group state ownership. | none |
| `turso_connection_register_collation` | `safe_wrapper` | `Connection.registerCollation` | Managed typed comparator context. | none |
| `turso_connection_register_scalar_function` | `safe_wrapper` | `Connection.registerScalarFunction` | Managed typed callback context and copied results. | none |
| `turso_connection_set_busy_timeout_ms` | `safe_wrapper` | `Connection.setBusyTimeoutMs` | Checked unsigned-to-signed duration conversion. | none |
| `turso_connection_unregister_collation` | `safe_wrapper` | `Connection.unregisterCollation` | Checked mutation and context ownership. | none |
| `turso_connection_unregister_function` | `safe_wrapper` | `Connection.unregisterFunction` | Checked mutation and callback context ownership. | none |
| `turso_database_connect` | `safe_wrapper` | `Database.connect` | Validates returned handle and tracks child ownership. | none |
| `turso_database_deinit` | `internal_ownership` | `Database.deinit` | Owning handle teardown after child-count assertion. | none |
| `turso_database_new` | `safe_wrapper` | `Database.create` | Owns configuration strings and construction diagnostics. | none |
| `turso_database_open` | `safe_wrapper` | `Database.open / Database.openProgress` | Synchronous wrapper plus explicit caller-driven terminal gap result. | no database run_io in 0.7.1 |
| `turso_setup` | `safe_wrapper` | `setup` | Validated process-global setup with owned failures. | none |
| `turso_statement_bind_positional_blob` | `safe_wrapper` | `Statement.bindBlob` | Call-borrowed slice with checked position. | none |
| `turso_statement_bind_positional_double` | `safe_wrapper` | `Statement.bindReal` | Checked positional binding. | none |
| `turso_statement_bind_positional_int` | `safe_wrapper` | `Statement.bindInteger` | Checked positional binding. | none |
| `turso_statement_bind_positional_null` | `safe_wrapper` | `Statement.bindNull` | Checked positional binding. | none |
| `turso_statement_bind_positional_text` | `safe_wrapper` | `Statement.bindText` | Call-borrowed slice with checked position. | none |
| `turso_statement_column_array_dimensions` | `safe_wrapper` | `Statement.columnArrayDimensions` | Bounds-checked metadata accessor. | none |
| `turso_statement_column_base_type` | `safe_wrapper` | `Statement.columnBaseType` | Copies and releases optional native text. | none |
| `turso_statement_column_count` | `safe_wrapper` | `Statement.columnCount` | Validates signed count. | none |
| `turso_statement_column_declared_name` | `safe_wrapper` | `Statement.columnDeclaredName` | Copies and releases optional native text. | none |
| `turso_statement_column_decltype` | `safe_wrapper` | `Statement.columnDeclaredType` | Copies and releases optional native text. | none |
| `turso_statement_column_kind` | `safe_wrapper` | `Statement.columnKind` | Exhaustive stable-tag conversion. | none |
| `turso_statement_column_name` | `safe_wrapper` | `Statement.columnName` | Copies and releases required native text. | none |
| `turso_statement_deinit` | `internal_ownership` | `Statement.deinit` | Owning teardown that can cancel and drain pending native work. | none |
| `turso_statement_execute` | `safe_wrapper` | `Statement.execute / Statement.executeProgress` | Synchronous and single-step progress adapters. | none |
| `turso_statement_finalize` | `safe_wrapper` | `Statement.finalize / Statement.finalizeProgress` | Synchronous and single-step progress adapters. | none |
| `turso_statement_n_change` | `safe_wrapper` | `Statement.changes` | Reentry-safe accessor. | none |
| `turso_statement_named_position` | `safe_wrapper` | `Statement.namedPosition` | NUL validation and optional checked index. | none |
| `turso_statement_parameter_name` | `safe_wrapper` | `Statement.parameterName` | Copies and releases optional native text. | none |
| `turso_statement_parameters_count` | `safe_wrapper` | `Statement.parameterCount` | Validates signed count. | none |
| `turso_statement_reset` | `safe_wrapper` | `Statement.reset` | Explicit cancellation that may drain pending native work. | none |
| `turso_statement_row_value_bytes_count` | `internal_ownership` | `Statement.value` | Validated with pointer before allocator-owned copy. | none |
| `turso_statement_row_value_bytes_ptr` | `internal_ownership` | `Statement.value` | Borrowed bytes are copied before invalidation. | none |
| `turso_statement_row_value_double` | `safe_wrapper` | `Statement.value` | Decoded through the row-value tagged union. | none |
| `turso_statement_row_value_int` | `safe_wrapper` | `Statement.value` | Decoded through the row-value tagged union. | none |
| `turso_statement_row_value_kind` | `safe_wrapper` | `Statement.value` | Exhaustive tag dispatch. | none |
| `turso_statement_run_io` | `safe_wrapper` | `Statement.runIo` | Exactly one caller-driven I/O iteration with state enforcement. | none |
| `turso_statement_step` | `safe_wrapper` | `Statement.step / Statement.stepProgress` | Synchronous and single-step progress adapters. | none |
| `turso_str_deinit` | `internal_ownership` | `errors.copyAndFreeDiagnostic` | Always paired immediately after native allocated-string reads. | none |
| `turso_version` | `safe_wrapper` | `version` | Bounded validation of process-lifetime native text. | none |

## Typedefs

| C declaration | Disposition | Zig API(s) | Rationale | Issue/exception |
| --- | --- | --- | --- | --- |
| `turso_agg_ctx_t` | `internal_ownership` | `aggregate_function.StateBox` | Heap-stable managed aggregate state carrier. | none |
| `turso_aggregate_final_function_t` | `internal_ownership` | `aggregate_function.finalTrampoline` | C-callconv trampoline into managed final callback. | none |
| `turso_aggregate_init_function_t` | `internal_ownership` | `aggregate_function.initTrampoline` | C-callconv trampoline into managed state initializer. | none |
| `turso_aggregate_step_function_t` | `internal_ownership` | `aggregate_function.stepTrampoline` | C-callconv trampoline into managed step callback. | none |
| `turso_collation_function_t` | `internal_ownership` | `collation.compareTrampoline` | C-callconv trampoline with invocation-borrowed UTF-8. | none |
| `turso_column_kind_t` | `safe_wrapper` | `ColumnKind` | Exhaustive stable-tag conversion. | none |
| `turso_config_t` | `safe_wrapper` | `SetupConfig / setup.loggerTrampoline` | Validated setup strings and logger adapter. | none |
| `turso_connection_t` | `internal_ownership` | `Connection` | Opaque owning handle. | none |
| `turso_context_destructor_t` | `internal_ownership` | `connection.scalarContextDestructor / aggregate_function.contextDestructor / aggregate_function.stateDestructor / collation.contextDestructor` | C-callconv ownership trampoline with exactly-once contracts. | none |
| `turso_database_config_t` | `configuration_exception` | `Database.Config` | async_io is mapped to IoMode; database open has no ABI run_io driver (upstream #8043). | upstream #8043 |
| `turso_database_t` | `internal_ownership` | `Database` | Opaque owning handle. | none |
| `turso_extension_blob_t` | `internal_ownership` | `callback_value.decodeArgs / callback_value.encodeResult` | Invocation-borrowed callback blob decoded with bounds. | none |
| `turso_extension_error_t` | `internal_ownership` | `ManagedError / callback_value.decodeArgs / callback_value.encodeResult` | Defensive callback error decoding and copied result encoding. | none |
| `turso_extension_result_code_t` | `safe_wrapper` | `ExtensionResultCode` | Exhaustive callback result-code mapping. | none |
| `turso_extension_text_subtype_t` | `safe_wrapper` | `ExtensionTextSubtype` | Exhaustive text/JSON subtype mapping. | none |
| `turso_extension_text_t` | `internal_ownership` | `BorrowedText / callback_value.decodeArgs / callback_value.encodeResult` | Invocation-borrowed callback text decoded with bounds. | none |
| `turso_extension_value_data_t` | `internal_ownership` | `callback_value.decodeArgs / callback_value.encodeResult` | ABI union decoded and encoded by tag. | none |
| `turso_extension_value_type_t` | `internal_ownership` | `callback_value.decodeArgs / callback_value.encodeResult` | Exhaustive callback value-tag dispatch. | none |
| `turso_log_t` | `safe_wrapper` | `Log / setup.loggerTrampoline` | Invocation-borrowed validated logging record. | none |
| `turso_scalar_function_t` | `internal_ownership` | `connection.scalarTrampoline` | C-callconv trampoline with managed context and result. | none |
| `turso_slice_ref_t` | `abi_carrier_exception` | `none (unused ABI carrier)` | Unused raw ABI carrier: no public function in 0.7.1 accepts or returns it. | unused ABI carrier |
| `turso_statement_t` | `internal_ownership` | `Statement` | Opaque owning handle. | none |
| `turso_status_code_t` | `safe_wrapper` | `errors.statusToError / OpenProgress / ExecuteProgress / StepProgress / FinalizeProgress` | Exhaustive status/error/progress conversion. | none |
| `turso_tracing_level_t` | `safe_wrapper` | `LogLevel / setup.loggerTrampoline` | Exhaustive tracing-level conversion. | none |
| `turso_type_t` | `safe_wrapper` | `Value / Statement.value` | Exhaustive row-value conversion. | none |
| `turso_value_destructor_t` | `internal_ownership` | `callback_value.destroyResult` | C-callconv release after native copies managed callback results. | none |
| `turso_value_t` | `internal_ownership` | `callback_value.decodeArgs / callback_value.encodeResult` | Tagged callback value carrier with checked layout. | none |

## Explicit limitations

1. **Database open driver.** `Database.Config.io_mode = .caller_driven` maps `database_config.async_io`, but SDK Kit 0.7.1 exposes no database-level `run_io`. If open requests I/O, `Database.openProgress` returns terminal `.needs_io_without_driver`. This configuration-mode exception is tracked by [tursodatabase/turso#8043](https://github.com/tursodatabase/turso/issues/8043).
2. **Arbitrary native extension code.** `Connection.loadExtensionUnsafe` is an explicit trust-boundary adapter. It can execute trusted native code with full process privileges; Zig cannot provide memory safety, recovery, sandboxing, or unload semantics for that code.

`turso_slice_ref_t` is separately classified as an unavoidable unused raw ABI carrier: no 0.7.1 public function accepts or returns it, so there is no callable behavior to wrap.

## Callback boundary

Managed scalar, aggregate, and collation callbacks and all associated deinitializers must not panic. A panic cannot unwind across the C calling convention boundary. They also must not re-enter their owning connection or statements; the wrapper rejects reentry and converts active callback violations to managed SQL errors where a result channel exists. Borrowed callback inputs are valid only for the invocation; copy anything that must outlive it.
