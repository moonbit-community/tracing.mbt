# moonbit-community/tracing/logfmt

logfmt output for `moonbit-community/tracing`.

This package turns tracing records into one logfmt line per tracing record and
writes them through an async background runtime. It is the ready-made backend in
this repository when you want readable logs without writing a custom
`Subscriber`.

The package provides:

- `with_logfmt_writer` for the common case
- `with_logfmt_stdout` and `with_logfmt_stderr` on native targets
- `LogfmtRuntime` when the caller needs explicit `flush`, `shutdown`, or
  `stats`

The writer runtime uses bounded queues. When the hot-path queue is full, new
records are dropped and reflected in `LogfmtStats.dropped_records`.

Each output line is one logfmt record with a `kind` field:

- `event`
- `span_start`
- `span_record`
- `span_end`
- `span_link`

Every MoonBit block below uses `mbt check`, so the examples participate in
`moon check` and `moon test`.

## Shared Helpers

The examples reuse one in-memory writer.

```mbt check
///|
struct LogfmtReadmeWriter {
  output : Ref[StringBuilder]
}

///|
fn LogfmtReadmeWriter::new() -> LogfmtReadmeWriter {
  { output: Ref::new(StringBuilder::new()) }
}

///|
impl @io.Writer for LogfmtReadmeWriter with write_once(self, buf, offset~, len~) {
  self.output.val.write_string(@utf8.decode(buf[offset:offset + len]))
  len
}

///|
fn LogfmtReadmeWriter::contents(self : LogfmtReadmeWriter) -> String {
  self.output.val.to_string()
}

///|
fn LogfmtReadmeWriter::lines(self : LogfmtReadmeWriter) -> Array[String] {
  let lines : Array[String] = []
  for line in self.contents().split("\n") {
    let line = line.to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}
```

## Quick Start

`with_logfmt_writer` is the simplest entry point. It creates a fresh root
`TraceContext`, routes records into the logfmt runtime, and then shuts that
runtime down before leaving the scope. On a clean callback return it surfaces
shutdown failures directly. If both the callback and shutdown fail, it raises
`UserAndShutdownFailed(...)`.

```mbt check
///|
async test "with_logfmt_writer writes logfmt lines" {
  let writer = LogfmtReadmeWriter::new()

  with_logfmt_writer(writer, ctx => {
    ctx.event(@tracing.Info, "ready", message?=Some("booting"), fields=[
      @tracing.field("worker", 1),
    ])
    ctx.with_span(@tracing.Info, "request", request_ctx => {
      request_ctx.event(@tracing.Warn, "slow", fields=[
        @tracing.field("cached", false),
      ])
    })
  })

  let lines = writer.lines()
  assert_eq(4, lines.length())
  assert_true(lines[0].contains("kind=\"event\""))
  assert_true(lines[0].contains("name=\"ready\""))
  assert_true(lines[0].contains("message=\"booting\""))
  assert_true(lines[0].contains("field.worker=1"))
  assert_true(lines[1].contains("kind=\"span_start\""))
  assert_true(lines[1].contains("name=\"request\""))
  assert_true(lines[2].contains("kind=\"event\""))
  assert_true(lines[2].contains("name=\"slow\""))
  assert_true(lines[2].contains("field.cached=false"))
  assert_true(lines[3].contains("kind=\"span_end\""))
  assert_true(lines[3].contains("status=\"ok\""))
}
```

## Complex Fields

Structured tracing values stay attached to the line. Scalars stay unquoted when
possible, while strings, bytes, arrays, and objects are quoted as logfmt text.

```mbt check
///|
async test "logfmt keeps complex fields on the line" {
  let writer = LogfmtReadmeWriter::new()

  with_logfmt_writer(writer, ctx => {
    ctx.event(@tracing.Info, "complex", message?=Some("line\n\"quoted\""), fields=[
      @tracing.field("user id/x", "req 1"),
      @tracing.field("bytes", b"hi"),
      @tracing.field(
        "items",
        @tracing.Array([@tracing.Int(1), @tracing.String("two"), @tracing.Null]),
      ),
      @tracing.field("payload", @tracing.Object([("ok", @tracing.Bool(true))])),
    ])
  })

  let line = writer.lines()[0]
  assert_true(line.contains("name=\"complex\""))
  assert_true(line.contains("message=\"line\\n\\\"quoted\\\"\""))
  assert_true(line.contains("field.user_u20_id_u2f_x=\"req 1\""))
  assert_true(line.contains("field.bytes=\"aGk=\""))
  assert_true(line.contains("field.items=\"[1,\\\"two\\\",null]\""))
  assert_true(line.contains("field.payload=\"{\\\"ok\\\":true}\""))
}
```

## Span Links And Manual Control

Use `LogfmtRuntime` directly when the caller needs to own the task group or
flush before shutdown.

```mbt check
///|
async test "LogfmtRuntime flushes span links and late fields" {
  let writer = LogfmtReadmeWriter::new()

  @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = @tracing.TraceContext::root(
      runtime.dispatch(),
      @tracing.TraceIdAllocator::new_seeded(0UL),
    )

    let (cause_handle, cause_ctx) = ctx.span(@tracing.Info, "cache_lookup")
    let cause = cause_ctx.current_span().unwrap()
    ignore(cause_handle.close())

    let (handle, _child_ctx) = ctx.span(@tracing.Info, "db_query")
    ignore(handle.record([@tracing.field("rows", 3)]))
    ignore(handle.follows_from(cause))
    ignore(handle.close(status=@tracing.Error, error="timeout"))

    runtime.flush()
    runtime.shutdown()
  })

  let lines = writer.lines()
  assert_eq(6, lines.length())
  assert_true(lines[3].contains("kind=\"span_record\""))
  assert_true(lines[3].contains("field.rows=3"))
  assert_true(lines[4].contains("kind=\"span_link\""))
  assert_true(lines[4].contains("follows_from_span_id="))
  assert_true(lines[5].contains("kind=\"span_end\""))
  assert_true(lines[5].contains("status=\"error\""))
  assert_true(lines[5].contains("error=\"timeout\""))
}
```
