# moonbit-community/tracing/jsonl Internal Design

This document explains the internals of the JSON Lines backend. The package encodes structured tracing records from the root package as one JSON object per line and writes them to any `@io.Writer` through a background writer runtime.

## Package Role

`jsonl` is the built-in backend for machine-readable output. It does not create tracing semantics. It only implements `@tracing.Subscriber` and converts the root package's five record types into JSON Lines:

- `event`
- `span_start`
- `span_record`
- `span_end`
- `span_link`

Callers can use it in two ways:

- `with_json_writer`, `with_json_stdout`, and `with_json_stderr`: helpers that create a runtime and root context, then shut the runtime down when the scope exits.
- `JsonRuntime::start_in`: an explicit runtime placed in an existing task group. The caller creates `TraceContext` values and owns flush, shutdown, and stats reads.

## File Responsibilities

`runtime.mbt` contains the core implementation: options, stats, error types, subscriber, encoders, background writer loop, control commands, runtime API, and scoped helper.

`stdio.mbt` only provides native-target convenience entries for stdout and stderr. They delegate directly to `with_json_writer`.

`runtime_test.mbt` covers encoded shapes, error paths, cancellation paths, queue-full drops, concurrent flush/shutdown, timeouts, and unclosed span accounting.

## Core Concepts

JSON Lines means that each line is a complete JSON object. This package never emits a wrapper array and never splits one object across multiple lines. That format is convenient for line-oriented log collectors and for tests that parse output line by line.

The hot path is the synchronous path where tracing calls reach subscriber methods. The backend is designed so the hot path only performs deterministic encoding and non-blocking enqueue. It does not wait for the real writer.

The record queue is a bounded queue of already encoded JSON lines. When it is full, new records are dropped and `JsonStats.dropped_records` is incremented.

The control queue is the runtime control plane. It only carries `Flush(id)` and `Shutdown(id)`. The ack queue carries completion results for those commands. Separating the control path from the record path prevents high record volume from blocking flush and shutdown commands.

The wake queue is a discard-latest queue with capacity 1. It wakes the background writer. The subscriber attempts to notify it after each successful record enqueue, and control commands also notify it. Notifications may be coalesced; the writer loop drains currently visible work when woken.

## Runtime State

`JsonRuntime` owns:

- `dispatch`: the `@tracing.Dispatch` exposed to the root package. Its subscriber sends records into this runtime.
- `control_queue`, `ack_queue`, and `wake_queue`: the writer's control and wakeup mechanism.
- `control_gate`: a semaphore with capacity 1 that serializes concurrent flush and shutdown calls so they cannot consume each other's acknowledgements.
- `next_command_id`: an incrementing id source for control commands. Acks carry the same id and callers only accept matching acks.
- `dropped_records`, `writer_errors`, and `unclosed_spans`: backing refs for stats.
- `accepting`: whether new tracing records are accepted. It becomes false when shutdown begins or after a writer error.
- `shutdown_state`: `Running`, `ShuttingDown(id)`, `Succeeded`, or `FailedState(err)`.
- `command_timeout_ms` and `shutdown_timeout_ms`: explicit command wait timeout and helper scope-exit shutdown timeout.

`JsonSubscriber` owns the record queue, wake queue, accepting flag, drop counter, open span set, and unclosed span ref. It has no writer and does not flush directly.

## Encoding Model

The encoder writes JSON strings by hand instead of going through a JSON AST. The tracing backend needs low dependency overhead, low allocation overhead, and stable field ordering. Field order is visible in tests and helps log pipelines locate core keys.

Every record has `kind`. Span-related records always have `trace_id` and `span_id`. Events always have `trace_id` and only include `span_id` when emitted inside a current span.

`Metadata` is expanded into `level`, `name`, `target`, and `loc`. `level` and `status` are lower-case text. `loc` uses `SourceLoc::to_string()`.

`fields` is always a JSON object. It is written from `Array[Field]` in order. The root package guarantees that every nested `Value::Object` has unique keys, but the top-level fields array itself may contain duplicate field names. JSON handling of duplicate object keys depends on downstream parsers, so application code should avoid duplicate top-level fields.

Field values use the root package's `Value::to_json_string`. Therefore bytes are base64 strings, non-finite doubles are `null`, and arrays and objects remain JSON structures.

`span_start` includes `parent_span_id` when a parent exists. It does not include a parent trace id because the parent must be in the same trace; a remote root parent's trace id is already reflected in the current span's `trace_id`.

`span_link` includes the follows-from trace id and span id. Links may cross traces, so both `follows_from_trace_id` and `follows_from_span_id` are preserved.

## Subscriber Hot Path

Each subscriber callback first encodes the tracing record into a `String`, then calls `enqueue`.

`enqueue` follows these rules:

1. If `accepting` is false, increment `dropped_records` and return.
2. Try `record_queue.try_put(line)`.
3. On success, notify the wake queue.
4. On failure or queue closure, increment `dropped_records`.

`on_span_start` also adds the span to `open_spans` and refreshes `unclosed_spans`.

`on_span_end` removes the span from `open_spans`, refreshes `unclosed_spans`, and then enqueues the `span_end` line. Even if a later writer failure occurs, the open span count still reflects that tracing code closed the span.

`on_span_record`, `on_event`, and `on_span_link` only encode and enqueue. They do not modify the open span set.

## Background Writer Loop

`writer_loop` is spawned as a background task in the task group. It creates an `@io.BufferedWriter` and waits on the wake queue.

After wakeup, the loop handles control commands first:

- `Flush(id)`: drain the current record queue, flush the buffered writer, then write either `Ok(id)` or `Failed(id, text)` to the ack queue.
- `Shutdown(id)`: drain the current record queue, flush, record how many spans remain open at shutdown, ack, and exit the worker.

If there is no control command, the worker takes records from the record queue and writes them to the buffered writer until no record is immediately available. The next record enqueue or control command wakes it again.

Writer errors are recorded by `remember_writer_error`. The first error text is stored in `writer_error_text`, `writer_errors` is incremented, and `accepting` becomes false. Later drains still clear the queue but do not write. Flush and shutdown report the first writer error through their acknowledgements.

## Flush, Shutdown, And Concurrency Control

`JsonRuntime::flush` and `JsonRuntime::shutdown` both run under `with_control_gate`. This prevents concurrent flush and shutdown callers from consuming each other's acknowledgements.

When the runtime is `Running`, `flush` sends `Flush(id)`, wakes the worker, and waits for a bounded ack. If shutdown is already in progress, it waits for the shutdown ack. If shutdown already succeeded, flush succeeds immediately. If the runtime is in failed state, flush re-raises the stored error.

`shutdown` is idempotent. The first call sets `accepting` to false, sends `Shutdown(id)`, changes state to `ShuttingDown(id)`, and waits for the ack. On success the state becomes `Succeeded`. Later shutdown calls return immediately. If the control queue closes or a writer failure is acknowledged, the state becomes failed and later control calls return the same error.

Timeouts use `@async.with_timeout_opt`. A timeout does not necessarily mean the worker stopped. Tests cover retrying shutdown after a timeout; the second call can still wait for the same `ShuttingDown(id)`.

## Scoped Helper Error Semantics

`with_json_writer` starts the runtime inside `@async.with_task_group`, creates a root `TraceContext` with a random `TraceIdAllocator`, and runs the user callback.

If the callback returns normally, the helper performs protected shutdown. If shutdown succeeds, it returns the user value. If shutdown fails, it raises the shutdown error.

If the callback raises a normal error, the helper still attempts protected shutdown. If shutdown succeeds, it re-raises the user error. If shutdown also fails with a recognizable `JsonRuntimeError`, it raises `UserAndShutdownFailed(user_err, runtime_err)` so neither failure is lost.

If the callback is cancelled, the helper performs best-effort protected shutdown and re-raises the cancellation error. Cancellation is not wrapped in `UserAndShutdownFailed`.

Protected shutdown uses `@async.protect_from_cancel` and wraps the whole attempt in `shutdown_timeout_ms`, preventing outer cancellation from leaving the background task hanging indefinitely.

## Options And Validation

`JsonOptions::new` only constructs a value; it does not validate. `JsonRuntime::start_in` requires every capacity and timeout to be positive and aborts otherwise. This lets options be passed around as ordinary values while ensuring the runtime never starts with nonsensical configuration.

Default values are suitable for general use:

- record queue: 8192
- control queue: 8
- ack queue: 8
- writer buffer: 16 KiB
- command timeout: 2000 ms
- shutdown timeout: 2000 ms

## Stats Meaning

`dropped_records` counts records that did not enter the writer path because the runtime stopped accepting, the record queue was full, or a queue operation failed.

`writer_errors` counts write or flush failures from the underlying writer. The first error stops the runtime from accepting new records.

`unclosed_spans` is the current size of the open span set. During runtime, it can be used to observe span leaks. The shutdown worker snapshots it to the number of spans still open at shutdown time. Callers should stop using the runtime's dispatch after shutdown; later subscriber callbacks are dropped but can still mutate the open-span counter before they notice that the runtime is no longer accepting records.

## Maintenance Notes

Changing encoded field names or field order affects README examples, assertion-style tests, and downstream log parsers. Treat those names as integration contracts.

When changing the control plane, preserve the control gate and command id mechanism. Without them, concurrent flush and shutdown calls can consume the wrong acknowledgement.

When changing writer error behavior, preserve the contract that the first writer error stops accepting new records and is surfaced by later flush or shutdown.

When adding a new tracing record type, add an encoder, subscriber callback, README coverage, and tests.
