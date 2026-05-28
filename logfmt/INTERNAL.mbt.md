# moonbit-community/tracing/logfmt Internal Design

This document explains the internals of the logfmt backend. The package converts tracing records from the root package into one logfmt record per line and writes them to any `@io.Writer` through a background writer runtime.

## Package Role

`logfmt` is the built-in backend for human-readable output and traditional log collection. It uses nearly the same runtime architecture as `jsonl`, but its output is space-separated `key=value` text.

The package exposes two kinds of entry points:

- `with_logfmt_writer`, `with_logfmt_stdout`, and `with_logfmt_stderr`: scoped helpers that create a root context and shut the runtime down on exit.
- `LogfmtRuntime::start_in`: an explicit runtime for callers that need to own flush, shutdown, or stats reads.

## File Responsibilities

`runtime.mbt` contains options, stats, error types, logfmt encoding, subscriber implementation, background writer, control commands, and helpers.

`stdio.mbt` only wraps stdout and stderr entry points. It is compiled only for native targets.

`runtime_test.mbt` covers logfmt parsing helpers, field-name escaping, duplicate fields, complex values, runtime control, errors, and timeouts.

## Relationship To The jsonl Backend

`logfmt` and `jsonl` share the same concurrency and lifecycle model:

- The subscriber synchronously encodes records and enqueues without blocking.
- The record queue is bounded, and records are dropped when it is full.
- The wake queue coalesces background writer wakeups.
- The control queue and ack queue handle flush and shutdown.
- The control gate serializes concurrent control calls.
- The scoped helper uses protected shutdown to drain as much accepted work as possible.

The main difference is the encoding layer: `logfmt` must put every value on one text line and must make field names safe as logfmt keys.

## logfmt Output Model

Each record is one line with key/value pairs separated by one space. Fixed metadata uses ordinary keys:

- `kind`
- `trace_id`
- `span_id`
- `parent_span_id`
- `level`
- `name`
- `target`
- `loc`
- `message`
- `status`
- `error`
- `follows_from_trace_id`
- `follows_from_span_id`

User fields always use the `field.` prefix so they cannot collide with fixed keys. For example, the tracing field `request_id` becomes `field.request__id` because underscores have a dedicated escape rule.

Fixed text values are quoted and escaped by `append_logfmt_string`. Boolean and numeric fields are emitted without quotes when possible so log processors can keep their basic scalar meaning. Complex fields, including strings, bytes, arrays, and objects, are emitted as quoted text.

## Field Name Escaping

logfmt keys must be readable and collision-free. `append_field_name` uses these rules:

- An empty field name becomes `_empty`.
- ASCII letters, digits, `.`, and `-` are preserved.
- `_` becomes `__`, avoiding ambiguity with the Unicode escape prefix.
- Every other character becomes `_u<hex>_`, where `<hex>` is the character code point in hexadecimal without extra leading zeroes.

Examples:

- `user id` becomes `user_u20_id`
- `user/id` becomes `user_u2f_id`
- `user_id` becomes `user__id`
- a U+4E2D field name becomes `_u4e2d_`

This design lets different original field names map to different logfmt keys and avoids collisions from simple character replacement.

## Value Encoding

`append_value` maps root-package `@tracing.Value` values into logfmt values:

- `Null` emits `null`.
- `Bool` emits `true` or `false`.
- `Int`, `Int64`, `UInt`, and `UInt64` emit decimal text.
- `Double` emits a number; NaN and infinity emit `null`.
- `String` emits a quoted and escaped string.
- `Bytes` are base64-encoded and then emitted as a quoted string.
- `Array` and `Object` are first converted to JSON text with `Value::to_json_string`, then emitted as quoted strings.

This mapping keeps simple scalar values readable while preserving complex structures as JSON that downstream systems can parse.

## Record Encoding

`span_start` emits kind, trace/span id, optional parent span id, metadata, and start fields.

`span_record` emits kind, trace/span id, and late fields. Late fields are not merged back into the start line; this follows the root package record protocol.

`event` emits kind, trace id, optional span id, metadata, optional message, and fields.

`span_end` emits kind, trace/span id, status, and optional error.

`span_link` emits the current span identity and the follows-from trace/span id. Links may cross traces, so both follows-from ids are emitted.

## Runtime State

`LogfmtRuntime` mirrors the JSON runtime's internal fields:

- `dispatch`: used by root `TraceContext` values.
- `control_queue`, `ack_queue`, and `wake_queue`: background writer control and wakeup.
- `control_gate`: serializes flush and shutdown.
- `next_command_id`: assigns control command ids.
- `dropped_records`, `writer_errors`, and `unclosed_spans`: stats refs.
- `accepting`: whether new records are accepted.
- `shutdown_state`: running, shutting down, succeeded, or failed.
- `command_timeout_ms` and `shutdown_timeout_ms`: control wait timeout and helper shutdown timeout.

`LogfmtSubscriber` owns the open span set and record queue. It does not touch the writer directly.

## Background Writer

The background `writer_loop` uses `@io.BufferedWriter`. It waits on the wake queue, then handles control commands before ordinary records.

`Flush(id)` drains accepted records, flushes the buffer, and acknowledges success or writer failure.

`Shutdown(id)` drains, flushes, refreshes the unclosed span count at shutdown time, acknowledges, and exits the worker.

Ordinary record handling writes a line and newline only while `writer_error_text` is empty. Once the writer fails, the runtime stores the first error text, increments the writer error count, and stops accepting. Later records are dropped, and flush/shutdown observe the same failure.

## Flush, Shutdown, And Helper

`LogfmtRuntime::flush` waits until all records accepted before the control command is processed have been written and flushed. It does not close open spans and does not prevent future records.

`LogfmtRuntime::shutdown` sets `accepting` to false before sending the shutdown command. After a successful shutdown, later calls are no-ops. If shutdown is already in progress, later calls wait for the same acknowledgement.

`with_logfmt_writer` has the same error semantics as the JSON helper:

- If the user callback succeeds and shutdown fails, the shutdown error is raised.
- If the user callback fails and shutdown succeeds, the original error is raised.
- If both the user callback and shutdown fail with a `LogfmtRuntimeError`, `UserAndShutdownFailed` is raised.
- If the user callback is cancelled, the helper performs best-effort protected shutdown and re-raises cancellation.

Protected shutdown uses `@async.protect_from_cancel` and `shutdown_timeout_ms`, preventing outer cancellation from interrupting cleanup directly.

## Stats

`dropped_records` counts records that did not enter the writer path. Common causes are a full record queue, shutdown already started, or writer failure after which the runtime no longer accepts records.

`writer_errors` counts write or flush failures. The first failure stops the runtime from accepting new records.

`unclosed_spans` is the current number of unclosed spans. The shutdown worker snapshots it to the number of spans still open at shutdown time. Callers should stop using the runtime's dispatch after shutdown; later subscriber callbacks are dropped but can still mutate the open-span counter before they notice that the runtime is no longer accepting records.

## Options

`LogfmtOptions::new` creates a configuration with defaults and does not validate it. `LogfmtRuntime::start_in` requires every capacity and timeout to be positive and aborts otherwise.

Defaults match the JSON runtime: record queue 8192, control queue 8, ack queue 8, writer buffer 16 KiB, command timeout 2000 ms, helper shutdown timeout 2000 ms.

## Maintenance Notes

Field-name escaping must stay collision-free. When changing `append_field_name`, update tests for empty strings, underscores, slashes, spaces, and non-ASCII characters.

Fixed key names are log integration contracts. Changing `kind`, `trace_id`, the `field.` prefix, or similar keys will break downstream queries.

Do not make the subscriber wait for the writer. Blocking I/O belongs in the background worker.

Concurrent control must preserve command ids and the control gate. Otherwise concurrent flush and shutdown calls can consume the wrong acknowledgement.

When adding a new `Value` variant, update `append_value` and decide whether it should be emitted as a scalar or as a JSON string.
