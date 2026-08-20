# moonbit-community/tracing/otel

OpenTelemetry trace bridge for `moonbit-community/tracing`.

This package accepts an OpenTelemetry `interface/trace.Tracer` and turns
tracing spans, span fields, events, status, and follows-from links into
OpenTelemetry spans. Span ends are asynchronous in OpenTelemetry, so this
package uses a background runtime: tracing callbacks stay synchronous, while
closed spans are ended by the runtime and can be drained with `flush` or
`shutdown`.

The package provides:

- `with_otel_tracer` for the common scoped runtime case
- `with_global_otel_tracer` to look up a tracer from the OpenTelemetry global
  provider
- `OtelRuntime` when the caller needs explicit `dispatch`, `flush`,
  `shutdown`, `stats`, or `current_context`
- conversion helpers for span contexts and baggage

Use this package when an application already has an OpenTelemetry SDK,
exporter, or collector pipeline and wants traces produced through
`moonbit-community/tracing` to join that pipeline. If you want file or terminal
output without installing an OpenTelemetry provider, use the `jsonl` or
`logfmt` packages instead.

## Bridge Model

The bridge is implemented as a `tracing.Subscriber` plus a small background
runtime. Tracing callbacks remain synchronous from the caller's perspective:
span starts create OpenTelemetry spans immediately, span records update
attributes and status immediately, events are added to the active span
immediately, and follows-from records become OpenTelemetry links immediately.

Span ending is the only operation moved onto the background worker. This keeps
the tracing hot path predictable even when an OpenTelemetry exporter performs
work during span shutdown. `flush` and `shutdown` communicate with that worker
through a separate control queue and wait for an acknowledgement.

Spanless tracing events are not exported as trace events because OpenTelemetry
trace events belong to a span. If a record must be exported through this bridge,
emit it inside a tracing span.

## Span Mapping

Each tracing span becomes one OpenTelemetry span. By default the OpenTelemetry
span name is the tracing span name, and the span kind is OpenTelemetry
`Internal`. The bridge recognizes a few reserved tracing fields on span start,
and a subset of them on span record operations:

| Field | Effect |
| --- | --- |
| `otel.name` | Overrides or updates the OpenTelemetry span name. |
| `otel.kind` | Sets the span kind on span start. Accepted text values are `internal`, `client`, `server`, `producer`, and `consumer`. Span record operations cannot change span kind. |
| `otel.status_code` | Sets span status. Accepted text values are `unset`, `ok`, and `error`. |
| `otel.status_description` | Supplies the description when `otel.status_code` is `error`. |

Reserved span fields are not emitted as normal attributes. All other tracing
fields become OpenTelemetry attributes. Fields recorded after span start update
attributes on the OpenTelemetry span. `otel.name`, `otel.status_code`, and
`otel.status_description` are also honored on span record operations.

Status updates are applied by priority: `Unset` < `Error` < `Ok`. A tracing span
closed with `Ok` sets OpenTelemetry status to `Ok` only if no status was already
set. A tracing span closed with `Error` or `Cancelled` applies OpenTelemetry
status `Error` unless the span was already explicitly marked `Ok`.

Events emitted inside a span become OpenTelemetry span events. Event fields
become event attributes, and an event `message` becomes the `message`
attribute. Error-level events can also mark the current span as errored and
record an OpenTelemetry exception event; both behaviors are controlled by
`OtelOptions`.

Follows-from relationships become OpenTelemetry links. If the followed span is
managed by the same runtime, the bridge links to its OpenTelemetry span
context; otherwise it converts the tracing span context directly.

## Value Mapping

Most tracing values map directly to OpenTelemetry attribute values:

| Tracing value | OpenTelemetry value |
| --- | --- |
| `Null` | String `"null"` |
| `Bool` | Boolean |
| `Int`, `Int64`, `UInt` | 64-bit integer |
| `UInt64` | 64-bit integer when it fits, otherwise decimal string |
| `Double` | Double |
| `String` | String |
| `Bytes` | Bytes |
| `Array` | Array with element-wise conversion |
| `Object` | JSON string |

`target`, `level`, and `loc` can be copied from tracing metadata into span and
event attributes. `target` is enabled by default; `level` and `loc` are disabled
by default to keep exported spans compact.

## Runtime Lifecycle

For most application code, prefer `with_otel_tracer` or
`with_global_otel_tracer`. These helpers start an `OtelRuntime`, create a fresh
root `TraceContext`, run the callback, and perform protected shutdown before
returning.

Use `OtelRuntime::start_in` directly when you need to share one runtime across
multiple root contexts, flush at a specific point, inspect bridge health
counters, or convert the current tracing context back into an OpenTelemetry
context for downstream propagation.

`OtelRuntime::flush` waits for the worker to end all spans that were already
closed and successfully queued before the flush command is processed. It does
not close open tracing spans and does not stop future records.

`OtelRuntime::shutdown` stops accepting new records, drains queued span ends,
records the number of still-open spans, and terminates the worker. Records
emitted after shutdown starts are counted as dropped. Calling `shutdown` again
after a successful shutdown is a no-op.

`OtelRuntime::stats` exposes two bridge counters:

| Counter | Meaning |
| --- | --- |
| `dropped_records` | Records rejected because shutdown began or the span-end queue was full. |
| `unclosed_spans` | Spans started through this runtime that have not been closed yet. |

## Options

The `Default` implementation for `OtelOptions` is suitable for most applications. Use
`OtelOptions::new` when you need to tune queue sizes, timeouts, or metadata
attributes.

| Option | Default | Meaning |
| --- | --- | --- |
| `queue_capacity` | `8192` | Bounded queue for asynchronous span end work. |
| `control_queue_capacity` | `8` | Queue for `flush` and `shutdown` commands. |
| `ack_queue_capacity` | `8` | Queue for worker acknowledgements. |
| `command_timeout_ms` | `2000` | Timeout for `flush` and `shutdown` acknowledgement waits. |
| `shutdown_timeout_ms` | `2000` | Timeout for helper shutdown while leaving the callback scope. |
| `with_target` | `true` | Attach tracing `target` as an attribute. |
| `with_level` | `false` | Attach tracing level as an attribute. |
| `with_location` | `false` | Attach source location text as an attribute. |
| `error_events_to_status` | `true` | Convert error-level events inside spans to OpenTelemetry error status. |
| `error_events_to_exceptions` | `true` | Convert error-level events inside spans to OpenTelemetry exception events. |

All capacities and timeouts must be positive. Invalid values abort when
`OtelRuntime::start_in` starts the runtime.

## Errors

`flush` and `shutdown` raise `OtelRuntimeError` when the control path cannot
complete. `ChannelClosed` means a control or acknowledgement queue closed before
the command finished. `TimedOut` means the configured timeout elapsed before
the worker acknowledged the command.

The scoped helpers preserve user errors. If the callback fails and protected
shutdown succeeds, the original callback error is raised. If both callback and
shutdown fail, the helper raises `OtelHelperError::UserAndShutdownFailed` with
both failures.

Every MoonBit block below uses `mbt check`, so the examples participate in
`moon check` and `moon test`.

## In-Memory Exporter

`with_otel_tracer` starts a bridge runtime, passes a fresh root
`TraceContext` to the callback, and shuts down before returning. Applications
can pass any SDK-backed or custom OpenTelemetry tracer.

```mbt check
///|
async test "with_otel_tracer exports spans" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
    .into_tracer_provider()
  let tracer = provider.tracer("readme-otel")

  with_otel_tracer(tracer, ctx => {
    ctx.with_span(
      Info,
      "handle_request",
      request_ctx => {
        request_ctx.event(Info, "validated", fields=[
          @tracing.field("route", "/health"),
        ])
      },
      target="http.server",
      fields=[
        @tracing.field("otel.kind", "server"),
        @tracing.field("request_id", "req-1"),
      ],
    )
  })

  let spans = exporter.finished_spans()
  @debug.assert_eq(1, spans.length())
  @debug.assert_eq(spans[0].name, "handle_request")
  @debug.assert_eq(spans[0].kind, Server)
  @debug.assert_eq(spans[0].events.length(), 1)
}
```

## Global Tracer

`with_global_otel_tracer` is useful for applications that install a global
OpenTelemetry provider during startup.

```mbt check
///|
async test "with_global_otel_tracer uses the global provider" {
  @global.reset_for_test()
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
    .into_tracer_provider()
  @global.set_tracer_provider(provider)

  with_global_otel_tracer("readme-global", ctx => {
    ctx.with_span(Info, "job", _job_ctx => ())
  })

  @debug.assert_eq(1, exporter.finished_spans().length())
  @global.reset_for_test()
}
```

## Propagation

Use `trace_context_from_otel` when an inbound OpenTelemetry context should
become the root parent of tracing work. Use `OtelRuntime::current_context` when
downstream OpenTelemetry propagation needs the current OpenTelemetry span
created by the bridge.

```mbt check
///|
async test "current_context exposes the active OpenTelemetry span" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
    .into_tracer_provider()
  let tracer = provider.tracer("readme-context")

  @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(group, tracer)
    let ctx = @tracing.TraceContext::root(
      runtime.dispatch(),
      @tracing.TraceIdAllocator::new_seeded(0UL),
    )
    let (handle, child_ctx) = ctx.span(Info, "work")
    let otel_context = runtime.current_context(child_ctx)
    assert_true(otel_context.span_context().unwrap().is_valid())
    ignore(handle.close())
    runtime.shutdown()
  })

  @debug.assert_eq(1, exporter.finished_spans().length())
}
```
