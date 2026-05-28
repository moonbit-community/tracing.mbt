# moonbit-community/tracing/otel Internal Design

This document explains the internals of the OpenTelemetry bridge package. The package maps spans, events, fields, status, and links from `moonbit-community/tracing` into the `moonbit-community/opentelemetry` trace interface.

## Package Role

`otel` is not a log formatting backend. It is for applications that already have an OpenTelemetry SDK, exporter, or collector pipeline installed and want this repository's explicit `TraceContext` model to join that pipeline.

The package exposes three groups of capabilities:

- `with_otel_tracer` and `with_global_otel_tracer`: scoped bridge runtime helpers. They run the user callback and then shut the runtime down.
- `OtelRuntime`: an explicit runtime for multiple root contexts, manual flush/shutdown, stats, and context conversion.
- Conversion helpers: conversions between tracing and OpenTelemetry span contexts, baggage, and contexts.

## File Responsibilities

`conversions.mbt` handles pure conversions between value domains: trace flags, trace state, span context, baggage, and creating a tracing root context from an OpenTelemetry context.

`runtime.mbt` implements the subscriber, span/event/status/link mapping, background span-end worker, control commands, runtime API, and scoped helpers.

`runtime_test.mbt` uses the OpenTelemetry SDK in-memory exporter to cover span lifecycle, status, events, exceptions, links, context round trips, baggage, drops, and unclosed span accounting.

## Bridge Model

OpenTelemetry span start, attribute update, event, status, and link operations are applied synchronously inside tracing subscriber callbacks. Only `span.end()` is moved to the background worker.

This design exists because the tracing hot path must know immediately that a span exists, so later event, record, and link callbacks can find it. OpenTelemetry span end may trigger exporter work, which is better handled through a bounded async queue.

Therefore `OtelRuntime::flush` means "wait until every already closed and successfully queued OpenTelemetry span has been ended." It does not close tracing spans that are still open.

## Core State

`OtelRuntime` owns:

- `dispatch`: used by root-package `TraceContext` values.
- `control_queue`, `ack_queue`, and `wake_queue`: background worker control and wakeup.
- `control_gate`: serializes flush and shutdown so concurrent control calls cannot consume each other's acknowledgements.
- `next_command_id`: assigns ids to control commands.
- `dropped_records` and `unclosed_spans`: runtime health counters.
- `accepting`: set to false when shutdown starts.
- `shutdown_state`: running, shutting down, succeeded, or failed.
- `command_timeout_ms` and `shutdown_timeout_ms`: explicit command wait timeout and helper shutdown timeout.
- `span_states`: a map from tracing `SpanContext` to OpenTelemetry span state.

`OtelSpanState` stores the OpenTelemetry `Span`, its corresponding `Context`, and the currently applied status. The status is stored in a `Ref` because the same span can be updated from start, record, event, and end callbacks.

`OtelSubscriber` stores the tracer, options, end queue, wake queue, accepting flag, drop counter, span state map, and unclosed span ref.

## Span Start Mapping

`on_span_start` follows these steps:

1. If the runtime is not accepting, increment dropped records and return.
2. Extract special fields: `otel.name`, `otel.kind`, `otel.status_code`, and `otel.status_description`.
3. Choose the OpenTelemetry span name. `otel.name` wins; otherwise use the tracing metadata name.
4. Convert ordinary tracing fields into OpenTelemetry attributes. Special fields are not emitted as ordinary attributes by default.
5. Append metadata attributes according to options: `target` is enabled by default, while `level` and `loc` are disabled by default.
6. If `otel.kind` is present and valid, set the span kind.
7. Compute the parent context. If the parent span was created by this runtime, use the saved OpenTelemetry context. Otherwise convert the tracing parent into an OpenTelemetry span context.
8. Build the OpenTelemetry span through the tracer.
9. Store the tracing span context in `span_states` and refresh the unclosed span count.
10. If the start fields included a status special, apply the initial status.

Span kind only takes effect at start time. `otel.kind` on later span records is parsed but does not change the kind, matching the OpenTelemetry span kind lifecycle.

## Span Record Mapping

`on_span_record` first checks whether the runtime is still accepting records. Records arriving after shutdown starts are counted as dropped and return before span lookup. While accepting, it looks up span state; if no state is found, the record is ignored. This can happen for spans that have already ended or spans outside this runtime.

Ordinary fields are converted to attributes and passed to `set_attributes`. Special fields are not emitted as attributes.

`otel.name` can update the OpenTelemetry span name.

`otel.status_code` and `otel.status_description` can update status. Status updates obey the priority rule described below.

## Event Mapping

OpenTelemetry trace events must belong to a span. For that reason, spanless tracing events are not exported to OpenTelemetry. While the runtime is accepting records, they are not counted as dropped records because this is an intentional model mismatch, not a queue or runtime failure.

An event inside a span calls `span.add_event(metadata.name, attributes)`. Event attributes include tracing fields, an optional `message` attribute, and target/level/location metadata according to options. `otel.*` fields on events are not special; they are emitted as ordinary attributes.

Error-level events have two optional side effects controlled by options:

- `error_events_to_status`: mark the current span as error. The description uses the event message when present, otherwise the event name.
- `error_events_to_exceptions`: call `record_error` to record an OpenTelemetry exception event. The message also prefers the tracing message over the event name.

## Span End Mapping

`on_span_end` looks up span state. When found, it first removes the span from `span_states` and refreshes the unclosed span count. Then it updates OpenTelemetry status based on tracing `SpanStatus`:

- `Ok`: set OpenTelemetry `Ok` only if no status has already been set.
- `Error`: set OpenTelemetry `Error`, using the tracing error as description.
- `Cancelled`: set OpenTelemetry `Error`, using the tracing error or the default description `"cancelled"`.

The span is then put into the end queue, where the background worker calls `span.end()`. If the runtime is not accepting or the queue is full, the drop counter is incremented.

## Status Priority

OpenTelemetry status updates use this priority order: `Unset < Error < Ok`.

`OtelSpanState::apply_status` calls `span.set_status` only when the new status has a higher priority than the current status, or when both statuses have the same code. This gives the following behavior:

- Explicit `Ok` can override an earlier `Error`.
- `Error` cannot override explicit `Ok`.
- Same-level status updates can replace the description.
- A normally closed span is set to `Ok` only if no status was set earlier.

This rule lets callers explicitly control final status with `otel.status_code` while preserving default behavior from error events and error closes.

## Link Mapping

`on_span_link` converts tracing follows-from relationships into OpenTelemetry links.

If the follows-from span is also managed by this runtime, the bridge uses its OpenTelemetry span context. Otherwise it converts the tracing span context directly. Invalid contexts are not linked.

Links do not affect parentage. A span created by `spawn_follower_span` is not a child span in OpenTelemetry, but it keeps the causal relationship through a link.

## Value To OpenTelemetry Attribute Mapping

`tracing_value_to_otel` maps tracing values to OpenTelemetry attribute values:

- `Null` becomes the string `"null"`.
- `Bool` becomes boolean.
- `Int`, `Int64`, and `UInt` become int64.
- `UInt64` becomes int64 when it fits in Int64; otherwise it becomes a decimal string.
- `Double` becomes double.
- `String` becomes string.
- `Bytes` becomes bytes.
- `Array` is converted element by element into an OpenTelemetry array.
- `Object` becomes a JSON string.

Special field parsing uses `tracing_value_to_text`, so callers can express `otel.kind` and `otel.status_code` with strings, numbers, or other tracing values. The bridge lower-cases the resulting text before matching.

## Special Fields

These tracing fields have special meaning on span start and, for some of them, on span record:

- `otel.name`: overrides or updates the OpenTelemetry span name.
- `otel.kind`: sets span kind only on start. Valid values are `internal`, `client`, `server`, `producer`, and `consumer`.
- `otel.status_code`: sets status code. Valid values are `unset`, `ok`, and `error`.
- `otel.status_description`: supplies the description when status code is error.

These fields are not emitted as ordinary span attributes by default, keeping control fields out of the attribute namespace.

## Background Worker

The worker only calls `end()` on OpenTelemetry spans that are already queued. It does not create spans, set attributes, or handle events.

`Flush(id)` drains the end queue and acknowledges the command.

`Shutdown(id)` drains the end queue, sets `unclosed_spans` to the current size of the `span_states` map, acknowledges the command, and exits.

The acknowledgement is currently only `Ok(id)` because the OpenTelemetry span end interface used here does not expose writer-style errors. Closed control or acknowledgement queues and timeouts still raise `OtelRuntimeError`.

## Runtime Control Semantics

`flush` sends `Flush(id)` while the runtime is running and waits for a bounded acknowledgement. If shutdown is already in progress, flush waits for the shutdown acknowledgement. After successful shutdown, flush is a no-op.

`shutdown` first sets `accepting` to false, then sends `Shutdown(id)`. Tracing callbacks after shutdown starts are counted as dropped records. After a successful shutdown, later shutdown calls are no-ops.

Concurrent flush and shutdown calls are serialized by `control_gate`; command ids prevent acknowledgement mismatches.

Timeouts do not automatically mark the runtime as failed. After shutdown times out, the state may remain `ShuttingDown(id)`, and a later call can continue waiting for the same acknowledgement.

## Scoped Helper

`with_otel_tracer` starts a runtime, creates a root `TraceContext` with a random trace id allocator, runs the user callback, and performs protected shutdown.

Its error semantics match the `jsonl` and `logfmt` backends:

- If the user callback succeeds and shutdown fails, the shutdown error is raised.
- If the user callback fails and shutdown succeeds, the user error is raised.
- If the user callback fails and shutdown also fails with an `OtelRuntimeError`, `UserAndShutdownFailed` is raised.
- If the user callback is cancelled, best-effort shutdown is attempted and cancellation is re-raised.

`with_global_otel_tracer` only obtains a tracer from the OpenTelemetry global provider and then delegates to `with_otel_tracer`. Instrumentation name, version, schema URL, and attributes are forwarded to `@global.tracer`.

## Context And Baggage Conversion

`span_context_to_otel` preserves trace id, span id, trace flags, trace state, and remote/local state. If an OpenTelemetry id type cannot represent the value, an invalid id is used.

`span_context_from_otel` accepts only valid OpenTelemetry span contexts. Invalid contexts return `None`.

`baggage_to_otel` inserts tracing baggage entries into OpenTelemetry baggage and preserves metadata.

`baggage_from_otel` converts OpenTelemetry baggage back into tracing baggage. Entries rejected by tracing baggage validation are skipped instead of failing the whole conversion.

`trace_context_from_otel` creates a tracing root context from an OpenTelemetry context. If the context has a valid span context, it becomes the tracing root's propagated parent. OpenTelemetry baggage is copied into the tracing context regardless of whether a parent exists.

`OtelRuntime::current_context` converts in the other direction. It reads the current span from a tracing context. If that span was created by this runtime, it returns the saved OpenTelemetry context; otherwise it converts the propagated span into an OpenTelemetry context. Tracing baggage is always attached at the end.

## Options

Default options mean:

- span end queue: 8192
- control queue: 8
- ack queue: 8
- command timeout: 2000 ms
- helper shutdown timeout: 2000 ms
- emit `target`
- do not emit `level`
- do not emit `loc`
- error events set error status
- error events record exceptions

`OtelOptions::new` does not validate. `OtelRuntime::start_in` validates that every capacity and timeout is positive.

## Stats

`dropped_records` includes tracing callbacks that arrive after shutdown starts and span ends that cannot be enqueued because the end queue is full. Spanless events that arrive while the runtime is accepting are not counted as dropped because they are intentionally ignored by the bridge model.

`unclosed_spans` is the current size of the `span_states` map. After shutdown, it is the number of tracing spans that had not received a span end by shutdown time.

## Maintenance Notes

Do not move span start to the background queue. Later event, record, and link callbacks depend on `span_states` being visible immediately.

When changing special fields, update the README table, `is_special_span_field`, `extract_span_specials`, and tests.

When changing status priority, check combinations of error events, record status, and span close status.

When adding a new tracing `Value` variant, update `tracing_value_to_text` and `tracing_value_to_otel`.

When changing context conversion, consider remote parents, local spans, spans managed by this runtime, spans outside this runtime, and baggage.
