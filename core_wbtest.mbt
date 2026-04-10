///|
struct CaptureWb {
  starts : Ref[Array[SpanStart]]
  events : Ref[Array[EventRecord]]
}

///|
fn CaptureWb::new() -> CaptureWb {
  { starts: Ref::new([]), events: Ref::new([]) }
}

///|
impl Subscriber for CaptureWb with on_span_start(self, record) {
  self.starts.val.push(record)
}

///|
impl Subscriber for CaptureWb with on_event(self, record) {
  self.events.val.push(record)
}

///|
impl Subscriber for CaptureWb with on_span_end(_self, _record) {

}

///|
test "trace ids are materialized lazily from an explicit allocator" {
  let ids = TraceIdAllocator::new_seeded(0UL)
  let first = TraceContext::root(Dispatch::noop(), ids)
  let second = TraceContext::root(Dispatch::noop(), ids)
  assert_eq(
    "00000000000000000000000000000001",
    second.ensure_trace_id().to_hex(),
  )
  assert_eq(
    "00000000000000000000000000000002",
    first.ensure_trace_id().to_hex(),
  )
}

///|
test "filtered root event does not consume allocator state" {
  let capture = CaptureWb::new()
  let ids = TraceIdAllocator::new_seeded(0UL)
  let filtered = TraceContext::root(
    Dispatch::from_subscriber(capture).filtered(LevelFilter(Warn)),
    ids,
  )
  filtered.event(Info, "ignored")
  let enabled = TraceContext::root(Dispatch::from_subscriber(capture), ids)
  enabled.event(Info, "emitted")
  assert_eq(1, capture.events.val.length())
  assert_eq(
    "00000000000000000000000000000001",
    capture.events.val[0].trace_id.to_hex(),
  )
}

///|
test "filtered root span keeps both trace and span ids untouched" {
  let capture = CaptureWb::new()
  let ids = TraceIdAllocator::new_seeded(0UL)
  let filtered = TraceContext::root(
    Dispatch::from_subscriber(capture).filtered(LevelFilter(Warn)),
    ids,
  )
  let (filtered_handle, _) = filtered.span(Info, "ignored")
  assert_true(filtered_handle.span_ref() is None)
  let enabled = TraceContext::root(Dispatch::from_subscriber(capture), ids)
  let (handle, _) = enabled.span(Info, "emitted")
  ignore(handle.close())
  assert_eq(1, capture.starts.val.length())
  assert_eq(
    "00000000000000000000000000000001",
    capture.starts.val[0].span.trace_id.to_hex(),
  )
  assert_eq("0000000000000001", capture.starts.val[0].span.span_id.to_hex())
}

///|
test "default allocator emits non-zero random trace and span ids" {
  let capture = CaptureWb::new()
  let ctx = TraceContext::root(
    Dispatch::from_subscriber(capture),
    TraceIdAllocator::new(),
  )
  let (handle, _) = ctx.span(Info, "emitted")
  ignore(handle.close())
  assert_eq(1, capture.starts.val.length())
  assert_true(capture.starts.val[0].span.is_valid())
}
