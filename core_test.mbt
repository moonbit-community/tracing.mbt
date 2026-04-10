///|
suberror TestErr derive(Debug)

///|
struct Capture {
  starts : Ref[Array[SpanStart]]
  records : Ref[Array[SpanRecord]]
  events : Ref[Array[EventRecord]]
  ends : Ref[Array[SpanEnd]]
  links : Ref[Array[SpanLink]]
}

///|
fn Capture::new() -> Capture {
  {
    starts: Ref::new([]),
    records: Ref::new([]),
    events: Ref::new([]),
    ends: Ref::new([]),
    links: Ref::new([]),
  }
}

///|
fn fake_source_loc(repr : String) -> SourceLoc = "%identity"

///|
fn root_ctx(dispatch : Dispatch) -> TraceContext {
  TraceContext::root(dispatch, TraceIdAllocator::new())
}

///|
impl Subscriber for Capture with on_span_start(self, record) {
  self.starts.val.push(record)
}

///|
impl Subscriber for Capture with on_span_record(self, record) {
  self.records.val.push(record)
}

///|
impl Subscriber for Capture with on_event(self, record) {
  self.events.val.push(record)
}

///|
impl Subscriber for Capture with on_span_end(self, record) {
  self.ends.val.push(record)
}

///|
impl Subscriber for Capture with on_span_link(self, record) {
  self.links.val.push(record)
}

///|
test "Value JSON encoding preserves order and scalar fidelity" {
  let encoded = @tracing.Object([
    ("dup", @tracing.Int64(@string.parse_int64("9007199254740993"))),
    ("dup", @tracing.UInt64(@string.parse_uint64("18446744073709551615"))),
    ("text", @tracing.String("line\n\"quoted\"")),
    ("bytes", @tracing.Bytes(b"hi")),
    ("items", @tracing.Array([@tracing.Bool(true), @tracing.Null])),
  ]).to_json_string()
  @debug.assert_eq(
    "{\"dup\":9007199254740993,\"dup\":18446744073709551615,\"text\":\"line\\n\\\"quoted\\\"\",\"bytes\":\"aGk=\",\"items\":[true,null]}",
    encoded,
  )
}

///|
test "root event carries trace id and derived target" {
  let capture = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(capture))
  ctx.event(Info, "ready", message?=Some("booting"))
  @debug.assert_eq(1, capture.events.val.length())
  let event = capture.events.val[0]
  @debug.assert_eq(None, event.span)
  @debug.assert_eq("ready", event.metadata.name)
  @debug.assert_eq("moonbit-community/tracing", event.metadata.target)
}

///|
test "level-specific event helpers preserve level and payload" {
  let capture = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(capture))
  ctx.trace("trace")
  ctx.debug("debug", target="debug-target")
  ctx.info("info", message?=Some("booting"))
  ctx.warn("warn", fields=[field("retry", true)])
  ctx.error("error", message?=Some("boom"), target="error-target", fields=[
    field("code", 500),
  ])
  @debug.assert_eq(5, capture.events.val.length())
  @debug.assert_eq(@tracing.Trace, capture.events.val[0].metadata.level)
  @debug.assert_eq("trace", capture.events.val[0].metadata.name)
  @debug.assert_eq(@tracing.Debug, capture.events.val[1].metadata.level)
  @debug.assert_eq("debug-target", capture.events.val[1].metadata.target)
  @debug.assert_eq(@tracing.Info, capture.events.val[2].metadata.level)
  @debug.assert_eq(Some("booting"), capture.events.val[2].message)
  @debug.assert_eq(@tracing.Warn, capture.events.val[3].metadata.level)
  @debug.assert_eq([field("retry", true)], capture.events.val[3].fields)
  @debug.assert_eq(@tracing.Level::Error, capture.events.val[4].metadata.level)
  @debug.assert_eq(Some("boom"), capture.events.val[4].message)
  @debug.assert_eq("error-target", capture.events.val[4].metadata.target)
  @debug.assert_eq([field("code", 500)], capture.events.val[4].fields)
}

///|
test "normalize_target falls back to unknown without package suffix" {
  let capture = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(capture))
  ctx.event(Info, "fallback", loc=fake_source_loc("missing-at"))
  ctx.event(
    Info,
    "explicit",
    target="explicit",
    loc=fake_source_loc("missing-at"),
  )
  @debug.assert_eq(2, capture.events.val.length())
  @debug.assert_eq("unknown", capture.events.val[0].metadata.target)
  @debug.assert_eq("explicit", capture.events.val[1].metadata.target)
}

///|
test "TargetFilter matches the derived module target" {
  let capture = Capture::new()
  let ctx = root_ctx(
    Dispatch::from_subscriber(capture).filtered(
      @tracing.TargetFilter({ "moonbit-community/tracing": Info }),
    ),
  )
  ctx.event(Info, "allowed")
  ctx.event(Debug, "blocked")
  @debug.assert_eq(1, capture.events.val.length())
  @debug.assert_eq("allowed", capture.events.val[0].metadata.name)
  @debug.assert_eq(
    "moonbit-community/tracing",
    capture.events.val[0].metadata.target,
  )
}

///|
test "disabled span returns original context and disabled handle" {
  let capture = Capture::new()
  let ctx = root_ctx(
    Dispatch::from_subscriber(capture).filtered(@tracing.LevelFilter(Warn)),
  )
  let (handle, child_ctx) = ctx.span(Info, "filtered")
  @debug.assert_eq(None, handle.span_ref())
  @debug.assert_eq(ctx.current_span(), child_ctx.current_span())
  @debug.assert_eq(0, capture.starts.val.length())
}

///|
test "SpanHandle records links and closes only once" {
  let capture = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(capture))
  let (handle, child_ctx) = ctx.span(Info, "manual")
  let cause = child_ctx.current_span().unwrap()
  assert_true(handle.record([field("answer", 42)]))
  assert_true(handle.follows_from(cause))
  assert_true(handle.close(status=Error, error="boom"))
  assert_true(!handle.record([field("late", true)]))
  assert_true(!handle.follows_from(cause))
  assert_true(!handle.close())
  @debug.assert_eq(1, capture.records.val.length())
  @debug.assert_eq(1, capture.links.val.length())
  @debug.assert_eq(1, capture.ends.val.length())
  @debug.assert_eq(Some("boom"), capture.ends.val[0].error)
}

///|
async test "with_span classifies cancellation and cleanup errors" {
  let cancelled = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(cancelled))
  ignore(
    @async.with_timeout_opt(10, () => {
      ctx.with_span(Info, "cancelled", _ctx => @async.sleep(100))
    }),
  )
  @debug.assert_eq(1, cancelled.ends.val.length())
  @debug.assert_eq(@tracing.SpanStatus::Cancelled, cancelled.ends.val[0].status)

  let failed = Capture::new()
  let failed_ctx = root_ctx(Dispatch::from_subscriber(failed))
  let result : Result[Unit?, _] = try? @async.with_timeout_opt(10, () => {
    failed_ctx.with_span(Info, "cleanup-error", _ctx => {
      @async.sleep(100) catch {
        _ => raise TestErr
      }
    })
  })
  assert_true(result is Err(TestErr))
  @debug.assert_eq(1, failed.ends.val.length())
  @debug.assert_eq(@tracing.SpanStatus::Error, failed.ends.val[0].status)
  assert_true(failed.ends.val[0].error.unwrap().contains("TestErr"))
}

///|
async test "spawn_inherit preserves the exact trace context" {
  let capture = Capture::new()
  root_ctx(Dispatch::from_subscriber(capture)).with_span(Info, "parent", parent_ctx => {
    let inherited = @async.with_task_group(group => {
      let task : @async.Task[SpanRef?] = spawn_inherit(group, parent_ctx, inherited => {
        inherited.event(Info, "inside-inherit")
        inherited.current_span()
      })
      task.wait()
    })
    @debug.assert_eq(parent_ctx.current_span(), inherited)
    @debug.assert_eq(1, capture.events.val.length())
    @debug.assert_eq(parent_ctx.current_span(), capture.events.val[0].span)
  })
}

///|
test "span lifecycle stays on the lanes captured at start" {
  let left = Capture::new()
  let right = Capture::new()
  let ctx = root_ctx(
    Dispatch::fanout([
      Dispatch::from_subscriber(left),
      Dispatch::from_subscriber(right).filtered(
        @tracing.TargetFilter({ "span-target": Info }),
      ),
    ]),
  )
  let (handle, child_ctx) = ctx.span(Info, "fixed", target="span-target")
  child_ctx.event(Info, "derived-event")
  assert_true(handle.record([field("answer", 42)]))
  assert_true(handle.close())
  @debug.assert_eq(1, left.starts.val.length())
  @debug.assert_eq(1, right.starts.val.length())
  @debug.assert_eq(1, left.records.val.length())
  @debug.assert_eq(1, right.records.val.length())
  @debug.assert_eq(1, left.ends.val.length())
  @debug.assert_eq(1, right.ends.val.length())
  @debug.assert_eq(1, left.events.val.length())
  @debug.assert_eq(0, right.events.val.length())
}

///|
async test "fanout and async propagation preserve child and follower semantics" {
  let left = Capture::new()
  let right = Capture::new()
  let dispatch = Dispatch::fanout([
    Dispatch::from_subscriber(left),
    Dispatch::from_subscriber(right).filtered(
      @tracing.TargetFilter({ "allowed": Info }),
    ),
  ])
  let ctx = root_ctx(dispatch)
  ctx.with_span(Info, "parent", parent_ctx => {
    @async.with_task_group(group => {
      let child_task : @async.Task[SpanRef] = spawn_child_span(
        group,
        parent_ctx,
        Info,
        "child",
        child_ctx => child_ctx.current_span().unwrap(),
        target="allowed",
      )
      let follower_task : @async.Task[SpanRef] = spawn_follower_span(
        group,
        parent_ctx,
        Info,
        "follower",
        follower_ctx => follower_ctx.current_span().unwrap(),
        target="allowed",
      )
      ignore(child_task.wait())
      ignore(follower_task.wait())
    })
  })
  @debug.assert_eq(3, left.starts.val.length())
  @debug.assert_eq(2, right.starts.val.length())
  let parent_span = left.starts.val[0].span
  let child_start = if left.starts.val[1].metadata.name == "child" {
    left.starts.val[1]
  } else {
    left.starts.val[2]
  }
  let follower_start = if left.starts.val[1].metadata.name == "follower" {
    left.starts.val[1]
  } else {
    left.starts.val[2]
  }
  @debug.assert_eq(Some(parent_span), child_start.parent)
  @debug.assert_eq(None, follower_start.parent)
  @debug.assert_eq(1, left.links.val.length())
  @debug.assert_eq(parent_span, left.links.val[0].follows_from)
}

///|
async test "spawn_follower_span without current span keeps the trace and skips links" {
  let capture = Capture::new()
  let ctx = root_ctx(Dispatch::from_subscriber(capture))
  let follower = @async.with_task_group(group => {
    let task : @async.Task[SpanRef] = spawn_follower_span(
      group,
      ctx,
      Info,
      "follower-root",
      follower_ctx => follower_ctx.current_span().unwrap(),
    )
    task.wait()
  })
  @debug.assert_eq(1, capture.starts.val.length())
  @debug.assert_eq(capture.starts.val[0].span.trace_id, follower.trace_id)
  @debug.assert_eq(None, capture.starts.val[0].parent)
  @debug.assert_eq(0, capture.links.val.length())
}

///|
test "filtered root span keeps span ids untouched" {
  let capture = Capture::new()
  let ids = TraceIdAllocator::new_seeded(0UL)
  let filtered = TraceContext::root(
    Dispatch::from_subscriber(capture).filtered(@tracing.LevelFilter(Warn)),
    ids,
  )
  let (filtered_handle, _) = filtered.span(Info, "ignored")
  @debug.assert_eq(None, filtered_handle.span_ref())
  let enabled = TraceContext::root(Dispatch::from_subscriber(capture), ids)
  let (handle, _) = enabled.span(Info, "emitted")
  ignore(handle.close())
  @debug.assert_eq(1, capture.starts.val.length())
  @debug.assert_eq(
    SpanId::from_hex("0000000000000001").unwrap(),
    capture.starts.val[0].span.span_id,
  )
}
