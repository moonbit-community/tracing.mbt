# moonbit-community/tracing Internal Design

This document is for maintainers. It explains the core package's internal model and implementation constraints. Public usage is documented in `README.mbt.md`; this file focuses on why the code is shaped this way and which invariants must be preserved.

## Package Role

The root package is the tracing core for this repository. It does not write records to files, standard streams, or OpenTelemetry. Instead, it defines a backend-neutral record model:

- `TraceContext` is the tracing context that callers pass explicitly.
- `Dispatch` decides whether a callsite is enabled and fans records out to one or more `Subscriber` values.
- `Subscriber` is the backend interface. It receives structured span, event, and link records.
- `TraceId`, `SpanId`, `TraceFlags`, `TraceState`, and `Baggage` represent identity and propagation metadata.
- `Value` and `Field` form the structured field layer shared by all backends.

The package intentionally avoids implicit thread-local state. Callers pass `TraceContext` as an ordinary value into functions and async tasks. This keeps task inheritance, child task spans, and follows-from relationships visible in source code.

## Core Concepts

A `trace` represents one end-to-end operation, either as a tree or as a graph. The package identifies the whole trace with a `TraceId`. A `TraceId` is a 16-byte value, usually rendered as 32 hexadecimal characters.

A `span` represents a bounded unit of work inside a trace. A `SpanId` is an 8-byte value rendered as 16 hexadecimal characters. A span can have a parent span and can also point to causal predecessors through follows-from links.

An `event` is an instant record. It may be attached to the current span or be spanless. A spanless event still belongs to a trace because it carries a `TraceId`, but it does not carry a `SpanContext`.

`SpanContext` is a propagatable identity snapshot for a span. It contains `TraceId`, `SpanId`, `TraceFlags`, `TraceState`, and `is_remote`. It is not a lifecycle handle and cannot record or close a span. Lifecycle operations only live on `SpanHandle`.

`Baggage` is business metadata propagated with a trace. It is separate from span identity: baggage can exist even when there is no current span, and it can be replaced with `with_baggage`.

`Metadata` describes static callsite information: record kind, level, name, target, and source location. A callsite is the source location that calls APIs such as `event`, `span`, or `with_span`. `#callsite(autofill(loc))` lets MoonBit inject the caller's `SourceLoc`.

## File Responsibilities

`records.mbt` defines the records visible to backends and the `Subscriber` trait. These types are the package's core protocol. Backend packages depend on them instead of reading `TraceContext` internals.

`dispatch.mbt` defines filtering and fanout. A `Dispatch` contains lanes. Each lane binds one subscriber to an optional filter. A record is sent only to lanes whose filters allow it.

`trace_context.mbt` defines contexts, span lifecycle, and async propagation helpers. It is the package's state orchestration layer.

`ids.mbt` defines trace ids, span ids, trace flags, and the id allocator. It hides random allocation and deterministic test allocation behind the same `TraceIdAllocator`.

`propagation.mbt` defines W3C `tracestate`, `baggage`, and propagatable `SpanContext`. It handles header encoding, header parsing, validation, size limits, and remote parent contexts.

`value.mbt` defines field values, field construction, JSON text encoding, and debug rendering. JSON Lines, logfmt, and OpenTelemetry all reuse this value model.

## TraceContext Internal State

`TraceContext` is split into shared state and current state:

- `TraceShared` is shared by contexts in the same trace. It contains `Dispatch`, `TraceIdAllocator`, the remote root parent span, trace flags and state, the lazy trace id, and the next span id counter.
- `TraceContext.current_span` is the local span for the current execution scope. Entering a child span returns a new context whose `current_span` points at the new span.
- `TraceContext.baggage` is the baggage carried by this context. `with_baggage` copies the context and replaces the baggage.

This split lets multiple contexts share the same trace id sequence while keeping the current span as an ordinary immutable context value passed down the call chain.

The trace id is allocated lazily. `TraceContext::root` does not consume the allocator. Only an enabled event or span that will actually be sent to a subscriber calls `ensure_trace_id`. Filtered-out callsites do not consume trace ids or span ids. This is a core invariant covered by tests.

`root_with_parent` is used for inbound remote parents. A valid remote parent supplies the trace id, trace flags, and trace state. When the root context has no current span, `propagated_span` exposes that remote parent. Invalid parent contexts are ignored.

## Span Lifecycle

`TraceContext::span` and `TraceContext::with_span` both delegate to `start_span`.

`start_span` follows these steps:

1. Validate that nested object field values do not contain duplicate keys.
2. Build `Metadata`. If the caller did not provide a target, derive it from the `...@package/path` suffix in `SourceLoc`.
3. Use `Dispatch::select_lanes` to select lanes enabled for that metadata.
4. If no lane is enabled, return a disabled `SpanHandle` and the original context.
5. If at least one lane is enabled, allocate the trace id lazily, allocate a span id, and build a `SpanContext`.
6. Send `SpanStart` to the selected lanes.
7. Convert follows-from arguments into `SpanLink` records.
8. Return an enabled `SpanHandle` and a child context whose current span is the new span.

`SpanHandle` captures the lanes selected at span start. Later `record`, `follows_from`, and `close` calls are sent only to those lanes; they are not filtered again by metadata. This guarantees that one span's start, record, and end are observed by the same backend set. Independent events are still filtered by their own event metadata.

`SpanHandle::close` is single-use. The first successful close sends `SpanEnd` and sets `closed` to true. Later close, record, and follows-from calls return false. A disabled handle starts out closed.

`with_span` wraps an async callback and closes the span automatically:

- On normal return, it closes with `Ok`.
- On a MoonBit async cancellation error, it closes with `Cancelled` and re-raises the original error.
- On any other error, it closes with `Error`, stores `err.to_string()` in the end record's error field, and re-raises the original error.
- If the callsite is filtered out, the callback runs with the original context and no span records are emitted.

## Async Propagation Semantics

The root package provides three task helpers. Each one only combines an explicit `TraceContext` with a MoonBit `TaskGroup`:

- `spawn_inherit` inherits the exact input context and does not create a new span. Events in the child task are attached to the same current span.
- `spawn_child_span` creates a child span first when the callsite is enabled, then runs the task with the child context. The parent is the current span, or the remote root parent when there is no current span. If the callsite is filtered out, the task runs with the original context.
- `spawn_follower_span` creates a new span in the same trace when the callsite is enabled without making the current span its parent. If a current span exists, it emits one follows-from link. If no current span exists, it only preserves trace continuity. If the callsite is filtered out, the task runs with the original context.

These differences are behavioral contracts: inherit means the same context, child means tree parentage, and follower means causal graph linkage.

## Dispatch And Filtering

`Dispatch` is the filtering and broadcast unit on the tracing hot path. An internal `Lane` contains a subscriber and an optional filter.

There are three filter forms:

- `LevelFilter(level)` allows records whose level is greater than or equal to that level. The ordering is `Trace < Debug < Info < Warn < Error`, so `Info` allows `Info`, `Warn`, and `Error`.
- `TargetFilter(map)` looks up `metadata.target` and then applies the configured level. Missing targets are rejected.
- `AndFilter(lhs, rhs)` allows a record only when both filters allow it.

`Dispatch::filtered` layers a new filter onto every existing lane. If a lane already has a filter, the result is `AndFilter(existing, new_filter)`; otherwise the new filter is installed directly.

`Dispatch::fanout` concatenates lanes from multiple dispatches. It does not deduplicate and does not modify lane filters. A caller may intentionally include the same subscriber in multiple lanes and receive duplicate records.

## Record Protocol

Backends receive records only through `Subscriber`:

- `SpanStart`: a span was created. It contains metadata, span context, optional parent, and start fields.
- `SpanRecord`: an existing span received additional fields.
- `EventRecord`: an instant event. It contains metadata, trace id, optional span, optional message, and fields.
- `SpanEnd`: a span ended. It contains status and optional error text.
- `SpanLink`: a causal follows-from relationship.

`on_span_record` and `on_span_link` have default no-op implementations so simple backends can handle only start, event, and end. `on_span_start`, `on_event`, and `on_span_end` have no defaults because they form the minimal useful lifecycle.

## Value And Field

`Value` is the shared structured field model. It supports null, bool, signed and unsigned integers, double, string, bytes, array, and object.

`field(name, value)` converts ordinary MoonBit values into `Value` through `IntoValue`. Built-in implementations cover common scalars, bytes, string views, bytes views, `Array[Value]`, `ArrayView[Value]`, and `Value` itself. Business types can implement `IntoValue` to be used directly as field values.

`Object` preserves insertion order, but field names inside one object must be unique. The root package recursively checks this in `field`, `Value::to_json_string`, and debug rendering, and aborts on duplicates. The top-level `Array[Field]` on an event or span may contain duplicate names; each backend decides how those duplicates appear.

`Value::to_json_string` writes JSON text by hand instead of converting through an external JSON AST. Backends need a stable, lightweight encoding path. Bytes are base64 strings. Non-finite doubles, including NaN and infinity, encode as JSON `null`.

## ID Allocation

`TraceIdAllocator` has two internal states:

- `Random(@random.Rand)`: the default production path. It derives a chacha8 seed from `@env.now()`, a process-local nonce, and SplitMix64, then loops until it produces non-zero trace and span ids.
- `Counter(Ref[Int64])`: the deterministic path for tests and documentation. Copies of the allocator share one counter, so multiple root contexts consume the same sequence in actual materialization order.

Deterministic trace ids use eight zero high bytes and an incrementing low 8-byte counter. Span ids use an incrementing 8-byte counter. The seed must be lower than the maximum Int64 value because the first allocation increments before materializing an id.

`TraceFlags` keeps only the low 8 bits. `is_sampled` checks the lowest bit, matching the W3C `traceparent` flags model.

## W3C Propagation Data

`TraceState` is an ordered key/value list limited to 32 members. Header parsing trims whitespace and rejects empty items, duplicate keys, invalid keys or values, and member counts above the limit. `insert` moves the new key to the front and removes any previous entry with the same key.

`Baggage` is an ordered list of baggage entries. It is limited to 64 entries and a final header length of 8192 characters. Values use UTF-8 percent encoding. Invalid percent sequences or invalid UTF-8 return `None` during parsing. Metadata is optional and cannot contain commas or non-printable characters.

`entries()` methods return copied arrays so callers cannot mutate internal storage. These propagation structures should keep value semantics: callers get new values through `insert` and `remove` rather than modifying in place.

## Target Derivation

If the caller does not provide `target`, the root package derives it from the text after the last `@` in `SourceLoc::to_string()`. If no usable suffix exists, it falls back to `"unknown"`.

Backends and filters depend on metadata targets, so changes to `derive_target` must consider README examples, cross-package callsite tests, and `TargetFilter` behavior.

## Error And Failure Strategy

Most root-package hot paths do not return errors. Invalid configuration or violated invariants abort, such as duplicate object keys, an out-of-range allocator seed, or allocator exhaustion. Runtime I/O, queue, and export failures belong to backend packages.

User errors inside span callbacks are not swallowed. `with_span` only marks the span as error or cancelled and then re-raises the original error.

## Maintenance Notes

When changing filtering logic, verify that filtered root events and spans still do not consume trace ids or span ids.

When changing span lifecycle, verify that `SpanHandle` still captures lanes at start time and that close succeeds only once.

When changing propagation, verify header round trips, duplicate-member rejection, size limits, and UTF-8 percent decoding.

When adding a new `Value` variant, update root JSON/debug encoding and the mappings in the `jsonl`, `logfmt`, and `otel` backends.

When adding a new record type, update the `Subscriber` trait, all backend runtimes, README files, and the INTERNAL documents for each package.
