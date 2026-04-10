# moonbit-community/tracing/jsonl

JSON Lines output for `moonbit-community/tracing`.

This package turns tracing records into newline-delimited JSON and writes them
through an async background runtime. It is the ready-made backend in this
repository when you want machine-readable logs without building a custom
`Subscriber`.

The package provides:

- `with_json_writer` for the common case
- `with_json_stdout` and `with_json_stderr` on native targets
- `JsonRuntime` when the caller needs explicit `flush`, `shutdown`, or `stats`

The writer runtime uses bounded queues. When the hot-path queue is full, new
records are dropped and reflected in `JsonStats.dropped_records`.

Each output line is one JSON object with a `kind` field:

- `event`
- `span_start`
- `span_record`
- `span_end`
- `span_link`

`with_json_writer` is a convenience helper. It starts a runtime, runs `f` with
a fresh root `TraceContext`, and shuts that runtime down before leaving the
scope. On a clean callback return it surfaces shutdown failures directly. If
both the callback and shutdown fail, it raises `UserAndShutdownFailed(...)`. If
you need explicit flush ordering, use `JsonRuntime` directly.

Every MoonBit block below uses `mbt check`, so the examples participate in
`moon check` and `moon test`.

## Shared Helpers

The examples reuse one in-memory writer.

```mbt check
///|
struct JsonlReadmeWriter {
  output : Ref[StringBuilder]
}

///|
fn JsonlReadmeWriter::new() -> JsonlReadmeWriter {
  { output: Ref::new(StringBuilder::new()) }
}

///|
impl @io.Writer for JsonlReadmeWriter with write_once(self, buf, offset~, len~) {
  self.output.val.write_string(@utf8.decode(buf[offset:offset + len]))
  len
}

///|
fn JsonlReadmeWriter::contents(self : JsonlReadmeWriter) -> String {
  self.output.val.to_string()
}

///|
fn JsonlReadmeWriter::lines(self : JsonlReadmeWriter) -> Array[String] {
  let lines : Array[String] = []
  for line in self.contents().split("\n") {
    let line = line.to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}

///|
fn JsonlReadmeWriter::json_lines(
  self : JsonlReadmeWriter,
) -> Array[Json] raise @json.ParseError {
  let lines : Array[Json] = []
  for line in self.lines() {
    lines.push(@json.parse(line))
  }
  lines
}
```

## Quick Start

`with_json_writer` is the simplest entry point. It creates a fresh root
`TraceContext`, routes records into the JSON writer runtime, and then shuts that
runtime down before leaving the scope. On a clean callback return it surfaces
shutdown failures directly. If both the callback and shutdown fail, it raises
`UserAndShutdownFailed(...)`.

```mbt check
///|
async test "with_json_writer writes JSON lines" {
  let writer = JsonlReadmeWriter::new()

  with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "ready", message?=Some("booting"), fields=[
      @tracing.field("worker", 1),
    ])
    ctx.with_span(@tracing.Info, "request", request_ctx => {
      request_ctx.event(@tracing.Warn, "slow", fields=[
        @tracing.field("cached", false),
      ])
    })
  })

  let lines = writer.json_lines()
  assert_eq(4, lines.length())
  assert_true(
    lines[0]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "level": "info",
        "name": "ready",
        "target": String(_),
        "loc": String(_),
        "message": "booting",
        "fields": Object({ "worker": Number(1, ..), .. }),
        ..
      }
    ),
  )
  assert_true(
    lines[1]
    is Object(
      {
        "kind": "span_start",
        "trace_id": String(_),
        "span_id": String(_),
        "level": "info",
        "name": "request",
        "target": String(_),
        "loc": String(_),
        "fields": Object(_),
        ..
      }
    ),
  )
  assert_true(
    lines[2]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "span_id": String(_),
        "level": "warn",
        "name": "slow",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ "cached": False, .. }),
        ..
      }
    ),
  )
  assert_true(
    lines[3]
    is Object(
      {
        "kind": "span_end",
        "trace_id": String(_),
        "span_id": String(_),
        "status": "ok",
        ..
      }
    ),
  )
}
```

## Span Links And Late Fields

Span records that arrive after start are emitted as `span_record`. Follows-from
relationships are emitted as `span_link`.

```mbt check
///|
async test "manual span operations become dedicated JSON line kinds" {
  let writer = JsonlReadmeWriter::new()

  with_json_writer(writer, ctx => {
    let (cause_handle, cause_ctx) = ctx.span(@tracing.Info, "cache_lookup")
    let cause = cause_ctx.current_span().unwrap()
    ignore(cause_handle.close())

    let (handle, _child_ctx) = ctx.span(@tracing.Info, "db_query")
    ignore(handle.record([@tracing.field("rows", 3)]))
    ignore(handle.follows_from(cause))
    ignore(handle.close(status=@tracing.Error, error="timeout"))
  })

  let lines = writer.json_lines()
  assert_eq(6, lines.length())
  assert_true(
    lines[3]
    is Object(
      {
        "kind": "span_record",
        "trace_id": String(_),
        "span_id": String(_),
        "fields": Object({ "rows": Number(3, ..), .. }),
        ..
      }
    ),
  )
  assert_true(
    lines[4]
    is Object(
      {
        "kind": "span_link",
        "trace_id": String(_),
        "span_id": String(_),
        "follows_from_trace_id": String(_),
        "follows_from_span_id": String(_),
        ..
      }
    ),
  )
  assert_true(
    lines[5]
    is Object(
      {
        "kind": "span_end",
        "trace_id": String(_),
        "span_id": String(_),
        "status": "error",
        "error": "timeout",
        ..
      }
    ),
  )
}
```

## Manual Runtime Control

Use `JsonRuntime` directly when the caller needs explicit control over flushing
and shutdown, or wants to inspect counters such as dropped records and unclosed
spans.

```mbt check
///|
async test "JsonRuntime supports explicit flush shutdown and stats" {
  let writer = JsonlReadmeWriter::new()

  let stats = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer)
    let ctx = @tracing.TraceContext::root(
      runtime.dispatch(),
      @tracing.TraceIdAllocator::new_seeded(0UL),
    )
    ctx.event(@tracing.Info, "prefetch")
    runtime.flush()
    runtime.shutdown()
    runtime.stats()
  })

  assert_eq(stats.writer_errors, 0)
  assert_eq(stats.unclosed_spans, 0)
  assert_true(writer.lines().length() > 0)
}
```

On native targets, `with_json_stdout` and `with_json_stderr` are thin wrappers
around `with_json_writer` for `stdout` and `stderr`.

## API Summary

- Main entry points: `with_json_writer`, `with_json_stdout`, `with_json_stderr`
- Runtime control: `JsonRuntime`, `JsonOptions`, `JsonStats`,
  `JsonRuntimeError`
