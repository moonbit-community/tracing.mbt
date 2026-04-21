# moonbit-community/tracing

Structured tracing for MoonBit with explicit context propagation.

This package keeps tracing state in normal values. You create a root
`TraceContext`, pass it where work happens, and keep async task relationships
and handoffs explicit.

The repository exposes four packages:

- `moonbit-community/tracing`: core tracing types, filtering, dispatch, spans,
  events, and async propagation helpers.
- `moonbit-community/tracing/jsonl`: a ready-made backend that writes records as
  JSON Lines.
- `moonbit-community/tracing/logfmt`: a ready-made backend that writes records
  as logfmt.

Every MoonBit block below uses `mbt check`, so the examples participate in
`moon check` and `moon test`.

## Shared Helpers

The examples reuse one small in-memory subscriber.

```mbt check
///|
struct ReadmeCapture {
  starts : Array[@tracing.SpanStart]
  records : Array[@tracing.SpanRecord]
  events : Array[@tracing.EventRecord]
  ends : Array[@tracing.SpanEnd]
  links : Array[@tracing.SpanLink]
}

///|
fn ReadmeCapture::new() -> ReadmeCapture {
  { starts: [], records: [], events: [], ends: [], links: [] }
}

///|
fn readme_root_ctx(dispatch : @tracing.Dispatch) -> @tracing.TraceContext {
  @tracing.TraceContext::root(
    dispatch,
    @tracing.TraceIdAllocator::new_seeded(0UL),
  )
}

///|
fn readme_source_loc(repr : String) -> SourceLoc = "%identity"

///|
fn ReadmeCapture::start_named(
  self : ReadmeCapture,
  name : String,
) -> @tracing.SpanStart {
  for start in self.starts {
    if start.metadata.name == name {
      return start
    }
  }
  abort("missing span start: \{name}")
}

///|
struct ReadmeSink {
  writes : Ref[Int]
}

///|
fn ReadmeSink::new() -> ReadmeSink {
  { writes: Ref::new(0) }
}

///|
impl @tracing.Subscriber for ReadmeCapture with on_span_start(self, record) {
  self.starts.push(record)
}

///|
impl @tracing.Subscriber for ReadmeCapture with on_span_record(self, record) {
  self.records.push(record)
}

///|
impl @tracing.Subscriber for ReadmeCapture with on_event(self, record) {
  self.events.push(record)
}

///|
impl @tracing.Subscriber for ReadmeCapture with on_span_end(self, record) {
  self.ends.push(record)
}

///|
impl @tracing.Subscriber for ReadmeCapture with on_span_link(self, record) {
  self.links.push(record)
}

///|
impl @io.Writer for ReadmeSink with write_once(self, _buf, offset~, len~) {
  ignore(offset)
  self.writes.val += 1
  len
}
```

## Quick Start

If you want useful output immediately, start with the `jsonl` package.
`with_json_writer` creates a root context, writes events and spans as JSON
Lines, and shuts the runtime down before the scope exits.

```mbt check
///|
async test "quick start with json writer" {
  let sink = ReadmeSink::new()
  @jsonl.with_json_writer(sink, ctx => {
    ctx.event(@tracing.Info, "app_started", message?=Some("booting"), fields=[
      @tracing.field("version", "0.1.0"),
      @tracing.field("port", 3000),
    ])
    ctx.with_span(
      @tracing.Info,
      "handle_request",
      request_ctx => {
        request_ctx.event(@tracing.Info, "validated", fields=[
          @tracing.field("method", "GET"),
          @tracing.field("path", "/health"),
        ])
      },
      target="http.server",
      fields=[@tracing.field("request_id", "req-1")],
    )
  })
  // This is a smoke test for the convenience helper: if the sink saw writes,
  // the helper created a root context, delivered records, and flushed on exit.
  assert_true(sink.writes.val > 0)
}
```

## Root Traces

Create a root context with `TraceContext::root(dispatch, trace_ids)`. Trace ids
are allocated lazily. Filtered-out callsites do not consume an id.

```mbt check
///|
test "root traces allocate ids lazily" {
  let capture = ReadmeCapture::new()
  let ids = @tracing.TraceIdAllocator::new_seeded(0UL)
  let first = @tracing.TraceContext::root(
    @tracing.Dispatch::from_subscriber(capture),
    ids,
  )
  let second = @tracing.TraceContext::root(
    @tracing.Dispatch::from_subscriber(capture),
    ids,
  )
  first.event(
    @tracing.Info,
    "first",
    target="readme.root",
    loc=readme_source_loc("root-first"),
  )
  second.event(
    @tracing.Info,
    "second",
    target="readme.root",
    loc=readme_source_loc("root-second"),
  )
  // The two roots share one allocator. Each root gets an id when it emits its
  // first enabled record.
  debug_inspect(
    capture.events,
    content=(
      #|[
      #|  {
      #|    metadata: {
      #|      kind: Event,
      #|      level: Info,
      #|      name: "first",
      #|      target: "readme.root",
      #|      loc: <SourceLoc: "root-first">,
      #|    },
      #|    trace_id: 00000000000000000000000000000001,
      #|    span: None,
      #|    message: None,
      #|    fields: [],
      #|  },
      #|  {
      #|    metadata: {
      #|      kind: Event,
      #|      level: Info,
      #|      name: "second",
      #|      target: "readme.root",
      #|      loc: <SourceLoc: "root-second">,
      #|    },
      #|    trace_id: 00000000000000000000000000000002,
      #|    span: None,
      #|    message: None,
      #|    fields: [],
      #|  },
      #|]
    ),
  )
}
```

## Events, Fields, and Values

Events are point-in-time records. Fields carry structured values with stable
names and machine-readable payloads.

`field(name, value)` accepts any type that implements `IntoValue`. Built-in
implementations cover common scalars, bytes, arrays of `Value`, and `Value`
itself.

`@tracing.Object` preserves insertion order, and each object field name must be
unique.

```mbt check
///|
struct ReadmeUser {
  id : Int
  name : String
}

///|
impl @tracing.IntoValue for ReadmeUser with into_value(self) {
  @tracing.Object([
    ("id", @tracing.Int(self.id)),
    ("name", @tracing.String(self.name)),
  ])
}

///|
test "fields accept custom values" {
  let user = ReadmeUser::{ id: 7, name: "alice" }
  // Check the exact JSON shape first, then verify that `field(...)` uses the
  // same `IntoValue` conversion automatically.
  let payload = @tracing.Object([
    ("ok", @tracing.Bool(true)),
    ("user", user.into_value()),
  ])
  assert_eq(
    "{\"ok\":true,\"user\":{\"id\":7,\"name\":\"alice\"}}",
    payload.to_json_string(),
  )
  let field = @tracing.field("user", user)
  assert_true(field.value is @tracing.Object(_))
}
```

## Scoped Spans

Use `TraceContext::with_span` for the common case. It starts a span, passes a
child context into the callback, and closes the span automatically.

```mbt check
///|
async test "with_span creates a child context and closes automatically" {
  let capture = ReadmeCapture::new()
  let ctx = readme_root_ctx(@tracing.Dispatch::from_subscriber(capture))
  ignore(
    ctx.with_span(
      @tracing.Info,
      "handle_request",
      request_ctx => {
        request_ctx.event(
          @tracing.Info,
          "validated",
          fields=[
            @tracing.field("method", "GET"),
            @tracing.field("path", "/health"),
          ],
          target="http.server",
          loc=readme_source_loc("validated"),
        )
      },
      target="http.server",
      fields=[@tracing.field("request_id", "req-1")],
      loc=readme_source_loc("handle-request"),
    ),
  )
  // The start record shows the new child span and the fields attached when it
  // was opened.
  debug_inspect(
    capture.starts[0],
    content=(
      #|{
      #|  metadata: {
      #|    kind: Span,
      #|    level: Info,
      #|    name: "handle_request",
      #|    target: "http.server",
      #|    loc: <SourceLoc: "handle-request">,
      #|  },
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000001,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  parent: None,
      #|  fields: [{ name: "request_id", value: "req-1" }],
      #|}
    ),
  )
  // The nested event keeps the same trace id and points at the span created by
  // `with_span`, so readers can tell the callback ran inside that scope.
  debug_inspect(
    capture.events[0],
    content=(
      #|{
      #|  metadata: {
      #|    kind: Event,
      #|    level: Info,
      #|    name: "validated",
      #|    target: "http.server",
      #|    loc: <SourceLoc: "validated">,
      #|  },
      #|  trace_id: 00000000000000000000000000000001,
      #|  span: Some(
      #|    {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000001,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|  ),
      #|  message: None,
      #|  fields: [{ name: "method", value: "GET" }, { name: "path", value: "/health" }],
      #|}
    ),
  )
  // A successful callback must produce exactly one matching `SpanEnd` with
  // status `Ok`; callers do not close the span manually.
  debug_inspect(
    capture.ends[0],
    content=(
      #|{
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000001,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  status: Ok,
      #|  error: None,
      #|}
    ),
  )
}
```

## Manual Span Lifecycle

If you need more control, call `TraceContext::span` directly. That returns a
`SpanHandle` plus the child context for work inside the span.

`SpanHandle` lets you:

- `record(fields)` to attach extra fields later
- `follows_from(cause)` to add a causal link
- `close(status, error)` to end the span exactly once

```mbt check
///|
test "manual span handles support record link and close" {
  let capture = ReadmeCapture::new()
  let ctx = readme_root_ctx(@tracing.Dispatch::from_subscriber(capture))

  let (cause_handle, cause_ctx) = ctx.span(
    @tracing.Info,
    "cache_lookup",
    target="db",
    loc=readme_source_loc("cache-lookup"),
  )
  // Start and close an earlier sibling span so the next span can reference it
  // through `follows_from` as a causal predecessor.
  let cause = cause_ctx.current_span().unwrap()
  ignore(cause_handle.close())

  let (handle, child_ctx) = ctx.span(
    @tracing.Info,
    "db_query",
    target="db",
    loc=readme_source_loc("db-query"),
  )
  child_ctx.event(
    @tracing.Info,
    "sql_built",
    target="db",
    loc=readme_source_loc("sql-built"),
  )
  // These calls are the reason to use the manual API: enrich the span after it
  // started, attach a causal link, and choose the final status explicitly.
  assert_true(handle.record([@tracing.field("rows", 3)]))
  assert_true(handle.follows_from(cause))
  assert_true(handle.close(status=@tracing.SpanStatus::Error, error="timeout"))

  // The starts prove both spans belong to the same trace. They are sibling
  // spans in that trace tree.
  debug_inspect(
    capture.starts,
    content=(
      #|[
      #|  {
      #|    metadata: {
      #|      kind: Span,
      #|      level: Info,
      #|      name: "cache_lookup",
      #|      target: "db",
      #|      loc: <SourceLoc: "cache-lookup">,
      #|    },
      #|    span: {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000001,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|    parent: None,
      #|    fields: [],
      #|  },
      #|  {
      #|    metadata: {
      #|      kind: Span,
      #|      level: Info,
      #|      name: "db_query",
      #|      target: "db",
      #|      loc: <SourceLoc: "db-query">,
      #|    },
      #|    span: {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000002,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|    parent: None,
      #|    fields: [],
      #|  },
      #|]
    ),
  )
  // Late fields are emitted as a separate `SpanRecord`, not folded back into
  // the original `SpanStart`.
  debug_inspect(
    capture.records[0],
    content=(
      #|{
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000002,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  fields: [{ name: "rows", value: 3 }],
      #|}
    ),
  )
  // `follows_from` records causality and leaves the parent field unchanged.
  debug_inspect(
    capture.links[0],
    content=(
      #|{
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000002,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  follows_from: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000001,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|}
    ),
  )
  // The final close controls both the terminal status and the optional error
  // text that subscribers observe.
  debug_inspect(
    capture.ends,
    content=(
      #|[
      #|  {
      #|    span: {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000001,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|    status: Ok,
      #|    error: None,
      #|  },
      #|  {
      #|    span: {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000002,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|    status: Error,
      #|    error: Some("timeout"),
      #|  },
      #|]
    ),
  )
}
```

## Filtering and Fanout

`Dispatch` decides which callsites are enabled and where records go.

- `Dispatch::from_subscriber(subscriber)` creates one lane
- `Dispatch::fanout([...])` combines multiple lanes
- `dispatch.filtered(filter)` applies metadata-only filtering

The available filters are:

- `LevelFilter(level)`
- `TargetFilter(Map[String, Level])`
- `AndFilter(lhs, rhs)`

```mbt check
///|
test "fanout can filter one lane without affecting another" {
  let left = ReadmeCapture::new()
  let right = ReadmeCapture::new()
  // The left lane is unfiltered. The right lane only keeps records whose
  // target matches `http.server`.
  let dispatch = @tracing.Dispatch::fanout([
    @tracing.Dispatch::from_subscriber(left),
    @tracing.Dispatch::from_subscriber(right).filtered(
      @tracing.TargetFilter({ "http.server": @tracing.Info }),
    ),
  ])
  let ctx = readme_root_ctx(dispatch)
  ctx.event(
    @tracing.Info,
    "allowed",
    target="http.server",
    loc=readme_source_loc("fanout-allowed"),
  )
  ctx.event(
    @tracing.Info,
    "blocked",
    target="db",
    loc=readme_source_loc("fanout-blocked"),
  )
  // The unfiltered lane still receives both events.
  debug_inspect(
    left.events,
    content=(
      #|[
      #|  {
      #|    metadata: {
      #|      kind: Event,
      #|      level: Info,
      #|      name: "allowed",
      #|      target: "http.server",
      #|      loc: <SourceLoc: "fanout-allowed">,
      #|    },
      #|    trace_id: 00000000000000000000000000000001,
      #|    span: None,
      #|    message: None,
      #|    fields: [],
      #|  },
      #|  {
      #|    metadata: {
      #|      kind: Event,
      #|      level: Info,
      #|      name: "blocked",
      #|      target: "db",
      #|      loc: <SourceLoc: "fanout-blocked">,
      #|    },
      #|    trace_id: 00000000000000000000000000000001,
      #|    span: None,
      #|    message: None,
      #|    fields: [],
      #|  },
      #|]
    ),
  )
  // The filtered lane only sees the event that matched its target filter.
  debug_inspect(
    right.events,
    content=(
      #|[
      #|  {
      #|    metadata: {
      #|      kind: Event,
      #|      level: Info,
      #|      name: "allowed",
      #|      target: "http.server",
      #|      loc: <SourceLoc: "fanout-allowed">,
      #|    },
      #|    trace_id: 00000000000000000000000000000001,
      #|    span: None,
      #|    message: None,
      #|    fields: [],
      #|  },
      #|]
    ),
  )
}
```

## Async Propagation

When one async flow branches into multiple tasks, the parent task has to choose
how the new task should relate to the current trace.

- `spawn_inherit`: keep exactly the same context and current span
- `spawn_child_span`: create a new child span under the current span
- `spawn_follower_span`: create a new span with a follows-from link that
  records a causal relationship

The choice is mostly about what relationship you want the trace to express.
In MoonBit, these helpers are for single-threaded async tasks; they describe
task relationships and handoff, not parallel execution on multiple threads.

- Use `spawn_inherit` when the new task is still the same logical operation and
  a separate span would just add noise. Typical cases are splitting one step
  into helper tasks, breaking a request flow into smaller async pieces, or
  moving small bookkeeping work onto another task while still wanting all
  events to appear under the current span. The inherited task has no separate
  duration, status, or fields; the trace still shows the parent span doing that
  work.
- Use `spawn_child_span` when the new task is a real sub-step that should be
  timed and described independently. This is the usual choice for branched
  async work such as querying a shard, calling another service, processing one
  item in a batch, or running a retryable async step. The child span keeps the
  structure clear: the parent started this work and conceptually owns it.
- Use `spawn_follower_span` when the current span caused the work and the new
  task should appear as a related handoff. Typical cases are enqueueing a job
  for later execution, triggering a webhook, handing work off to another
  pipeline, or starting deferred async work that may outlive the parent span.
  The follower stays in the same trace, so logs stay correlated, and the trace
  records the relationship as a causal link.

A practical rule of thumb:

- if the parent is still "doing the same thing", use `spawn_inherit`
- if the parent started a sub-step and you want nested timing, use
  `spawn_child_span`
- if the parent triggered or handed off work, use `spawn_follower_span`

```mbt check
///|
async test "spawn helpers preserve explicit relationships" {
  let capture = ReadmeCapture::new()
  let ctx = readme_root_ctx(@tracing.Dispatch::from_subscriber(capture))

  // All three helpers stay in the same trace. They express three
  // relationships to the current span: reuse it, create a child, or create a
  // follower linked by causality.
  ctx.with_span(
    @tracing.Info,
    "parent",
    parent_ctx => {
      let parent = parent_ctx.current_span().unwrap()
      @async.with_task_group(group => {
        let inherited_task : @async.Task[@tracing.SpanContext?] = @tracing.spawn_inherit(
          group,
          parent_ctx,
          inherited_ctx => {
            inherited_ctx.event(
              @tracing.Info,
              "inside_inherit",
              target="readme.async",
              loc=readme_source_loc("inside-inherit"),
            )
            inherited_ctx.current_span()
          },
        )
        let child_task : @async.Task[@tracing.SpanContext] = @tracing.spawn_child_span(
          group,
          parent_ctx,
          @tracing.Info,
          "child",
          target="readme.async",
          loc=readme_source_loc("child"),
          child_ctx => child_ctx.current_span().unwrap(),
        )
        let follower_task : @async.Task[@tracing.SpanContext] = @tracing.spawn_follower_span(
          group,
          parent_ctx,
          @tracing.Info,
          "follower",
          target="readme.async",
          loc=readme_source_loc("follower"),
          follower_ctx => follower_ctx.current_span().unwrap(),
        )

        // `spawn_inherit` reuses the exact current span. The other two helpers
        // create distinct spans, so they must not compare equal to `parent`.
        assert_true(inherited_task.wait() == Some(parent))
        assert_true(child_task.wait() != parent)
        assert_true(follower_task.wait() != parent)
      })
    },
    target="readme.async",
    loc=readme_source_loc("parent"),
  )

  // This is the original span created in the parent task.
  debug_inspect(
    capture.start_named("parent"),
    content=(
      #|{
      #|  metadata: {
      #|    kind: Span,
      #|    level: Info,
      #|    name: "parent",
      #|    target: "readme.async",
      #|    loc: <SourceLoc: "parent">,
      #|  },
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000001,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  parent: None,
      #|  fields: [],
      #|}
    ),
  )
  // A child span keeps the trace id but records the parent edge explicitly.
  debug_inspect(
    capture.start_named("child"),
    content=(
      #|{
      #|  metadata: {
      #|    kind: Span,
      #|    level: Info,
      #|    name: "child",
      #|    target: "readme.async",
      #|    loc: <SourceLoc: "child">,
      #|  },
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000002,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  parent: Some(
      #|    {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000001,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|  ),
      #|  fields: [],
      #|}
    ),
  )
  // A follower span stays in the same trace and leaves the parent field empty.
  // A later `SpanLink` records the causal relationship.
  debug_inspect(
    capture.start_named("follower"),
    content=(
      #|{
      #|  metadata: {
      #|    kind: Span,
      #|    level: Info,
      #|    name: "follower",
      #|    target: "readme.async",
      #|    loc: <SourceLoc: "follower">,
      #|  },
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000003,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  parent: None,
      #|  fields: [],
      #|}
    ),
  )
  // The inherited task emits inside the parent's span.
  debug_inspect(
    capture.events[0],
    content=(
      #|{
      #|  metadata: {
      #|    kind: Event,
      #|    level: Info,
      #|    name: "inside_inherit",
      #|    target: "readme.async",
      #|    loc: <SourceLoc: "inside-inherit">,
      #|  },
      #|  trace_id: 00000000000000000000000000000001,
      #|  span: Some(
      #|    {
      #|      trace_id: 00000000000000000000000000000001,
      #|      span_id: 0000000000000001,
      #|      trace_flags: { raw: 1 },
      #|      trace_state: { entries: [] },
      #|      is_remote: false,
      #|    },
      #|  ),
      #|  message: None,
      #|  fields: [],
      #|}
    ),
  )
  // The follower relationship is recorded as a link.
  debug_inspect(
    capture.links[0],
    content=(
      #|{
      #|  span: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000003,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|  follows_from: {
      #|    trace_id: 00000000000000000000000000000001,
      #|    span_id: 0000000000000001,
      #|    trace_flags: { raw: 1 },
      #|    trace_state: { entries: [] },
      #|    is_remote: false,
      #|  },
      #|}
    ),
  )
}
```

## Building a Custom Backend

A backend is just a `Subscriber` implementation plus a `Dispatch` built from
it. The `ReadmeCapture` helper earlier in this document is already a complete
in-memory backend for tests.

For production code, the minimal pattern is:

1. implement `Subscriber`
2. build a dispatch with `Dispatch::from_subscriber`
3. create a root context with `TraceContext::root`
4. pass that context explicitly through your program

The records delivered to a subscriber are:

- `SpanStart`
- `SpanRecord`
- `EventRecord`
- `SpanEnd`
- `SpanLink`

## JSON Lines Package

`moonbit-community/tracing/jsonl` is the ready-made backend in this repository.

Use it when you want:

- newline-delimited JSON output
- a dedicated async writer task with bounded queues
- `with_json_stdout` or `with_json_stderr` for quick setup on native targets
- direct runtime control through `JsonRuntime` when you need `flush`,
  `shutdown`, or `stats`

The main public entry points are:

- `with_json_writer(writer, options, f)`
- `with_json_stdout(options, f)`
- `with_json_stderr(options, f)`
- `JsonRuntime::start_in(group, writer, options)`
- `JsonRuntime::flush()`
- `JsonRuntime::shutdown()`
- `JsonRuntime::stats()`

## logfmt Package

`moonbit-community/tracing/logfmt` is the human-readable backend in this
repository.

Use it when you want:

- logfmt output with stable key ordering
- one line per tracing record
- a dedicated async writer task with bounded queues
- `with_logfmt_stdout` or `with_logfmt_stderr` for quick setup on native
  targets
- direct runtime control through `LogfmtRuntime` when you need `flush`,
  `shutdown`, or `stats`

The main public entry points are:

- `with_logfmt_writer(writer, options, f)`
- `with_logfmt_stdout(options, f)`
- `with_logfmt_stderr(options, f)`
- `LogfmtRuntime::start_in(group, writer, options)`
- `LogfmtRuntime::flush()`
- `LogfmtRuntime::shutdown()`
- `LogfmtRuntime::stats()`

## OpenTelemetry Package

`moonbit-community/tracing/opentelemetry` adds W3C propagation and a generic
batch export runtime.

Use it when you want:

- parse and inject `traceparent`, `tracestate`, and `baggage`
- root a local trace under a propagated remote parent
- export `ReadableSpan` batches into your own backend
- attach OpenTelemetry-specific span overrides such as name, kind, and status

The main public entry points are:

- `W3cPropagator`, `TraceContextPropagator`, `BaggagePropagator`
- `IncomingContext::root`
- `with_exporter(exporter, options, f)`
- `OpenTelemetryRuntime::start_in(group, exporter, options)`
- `OpenTelemetryRuntime::flush()`
- `OpenTelemetryRuntime::shutdown()`
- `OpenTelemetryRuntime::stats()`
- `Resource`, `InstrumentationScope`, `ReadableSpan`
- `otel_name`, `otel_kind`, `otel_status_code`, `otel_status_description`

## API Summary

Core package:

- `TraceContext`
- `SpanHandle`
- `Dispatch`
- `TraceIdAllocator`
- `TraceId`, `SpanId`, `SpanContext`
- `TraceFlags`, `TraceState`, `Baggage`
- `Metadata`, `SpanStart`, `SpanRecord`, `EventRecord`, `SpanEnd`, `SpanLink`
- `Level`, `SpanStatus`, `Filter`
- `Value`, `Field`, `IntoValue`
- `field`
- `spawn_inherit`, `spawn_child_span`, `spawn_follower_span`

JSON Lines package:

- `JsonOptions`
- `JsonRuntime`
- `JsonStats`
- `JsonRuntimeError`
- `with_json_writer`, `with_json_stdout`, `with_json_stderr`

logfmt package:

- `LogfmtOptions`
- `LogfmtRuntime`
- `LogfmtStats`
- `LogfmtRuntimeError`
- `with_logfmt_writer`, `with_logfmt_stdout`, `with_logfmt_stderr`

OpenTelemetry package:

- `IncomingContext`
- `TraceContextPropagator`, `BaggagePropagator`, `W3cPropagator`
- `OpenTelemetryOptions`
- `OpenTelemetryRuntime`
- `OpenTelemetryStats`
- `OpenTelemetryRuntimeError`
- `Resource`, `InstrumentationScope`, `ReadableSpan`, `ReadableEvent`,
  `ReadableLink`
- `SpanKind`, `StatusCode`, `Status`
- `with_exporter`

## Validation

The checked examples in this README are intended to stay in sync with the code.
After editing the repository, the expected validation flow is:

```bash
moon check
```

```bash
moon test --target native
```
