///|
fn fake_source_loc(repr : String) -> SourceLoc = "%identity"

///|
fn test_tracer() -> (@sdktrace.InMemorySpanExporter, @trace.Tracer) {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
    .into_tracer_provider()
  (exporter, provider.tracer("tracing-otel-test"))
}

///|
fn root_ctx(dispatch : @tracing.Dispatch) -> @tracing.TraceContext {
  @tracing.TraceContext::root(
    dispatch,
    @tracing.TraceIdAllocator::new_seeded(0UL),
  )
}

///|
fn test_span_context(index : Int) -> @common.SpanContext {
  let trace_id = @common.TraceId::from_hex("4bf92f3577b34da6a3ce929d0e0e4736").unwrap()
  let span_id = @common.SpanId::from_hex(
    index.to_string(radix=16).pad_start(16, '0'),
  ).unwrap()
  @common.SpanContext::new(trace_id, span_id)
}

///|
fn slow_end_tracer(delay_ms : Int) -> @trace.Tracer {
  let next_span = Ref(1)
  @trace.Tracer::from_functions((_, parent_context) => {
    let span_context = test_span_context(next_span.val)
    next_span.val += 1
    let ended = Ref(false)
    let context = parent_context.with_span_context(span_context)
    @trace.Span::from_functions(
      () => span_context,
      () => context,
      () => true,
      () => ended.val,
      (_, _, _) => (),
      _ => (),
      _ => (),
      _ => (),
      (_, _) => (),
      _ => {
        if delay_ms > 0 {
          @async.sleep(delay_ms)
        }
        ended.val = true
      },
    )
  })
}

///|
fn exported_span(
  spans : Array[@sdktrace.SpanData],
  name : String,
) -> @sdktrace.SpanData {
  for span in spans {
    if span.name == name {
      return span
    }
  }
  abort("missing exported span: \{name}")
}

///|
fn event_named(
  events : Array[@sdktrace.SpanEvent],
  name : String,
) -> @sdktrace.SpanEvent {
  for event in events {
    if event.name == name {
      return event
    }
  }
  abort("missing exported event: \{name}")
}

///|
fn attr_value(
  attributes : ArrayView[@common.KeyValue],
  key : String,
) -> @common.Value? {
  for attribute in attributes {
    if attribute.key.as_string() == key {
      return Some(attribute.value)
    }
  }
  None
}

///|
fn attr_string(
  attributes : ArrayView[@common.KeyValue],
  key : String,
) -> String? {
  match attr_value(attributes, key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn attr_int64(attributes : ArrayView[@common.KeyValue], key : String) -> Int64? {
  match attr_value(attributes, key) {
    Some(Int64(value)) => Some(value)
    _ => None
  }
}

///|
async test "OtelRuntime exports span lifecycle records to OpenTelemetry" {
  let (exporter, tracer) = test_tracer()
  @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(
      group,
      tracer,
      options=OtelOptions::new(with_level=true, with_location=true),
    )
    let ctx = root_ctx(runtime.dispatch())
    let (parent_handle, parent_ctx) = ctx.span(
      Info,
      "parent",
      target="svc",
      fields=[
        @tracing.field("otel.name", "server.request"),
        @tracing.field("otel.kind", "server"),
        @tracing.field("request_id", "req-1"),
      ],
      loc=fake_source_loc("parent-loc"),
    )
    let (child_handle, child_ctx) = parent_ctx.span(
      Info,
      "child",
      target="worker",
      fields=[@tracing.field("child_attr", true)],
      loc=fake_source_loc("child-loc"),
    )
    child_ctx.event(
      Error,
      "failed",
      message="bad",
      fields=[@tracing.field("rows", 3)],
      loc=fake_source_loc("event-loc"),
    )
    ignore(child_handle.close())
    ignore(
      parent_handle.record([
        @tracing.field("otel.status_code", "error"),
        @tracing.field("otel.status_description", "db failed"),
      ]),
    )
    ignore(parent_handle.close())
    runtime.shutdown()
  })

  let spans = exporter.finished_spans()
  @debug.assert_eq(2, spans.length())
  let parent = exported_span(spans, "server.request")
  let child = exported_span(spans, "child")

  @debug.assert_eq(parent.kind, Server)
  @debug.assert_eq(attr_string(parent.attributes, "request_id"), Some("req-1"))
  @debug.assert_eq(attr_string(parent.attributes, "target"), Some("svc"))
  @debug.assert_eq(attr_string(parent.attributes, "level"), Some("info"))
  assert_true(
    attr_string(parent.attributes, "loc").unwrap().contains("parent-loc"),
  )
  @debug.assert_eq(parent.status.code, Error)
  @debug.assert_eq(parent.status.description, Some("db failed"))

  @debug.assert_eq(
    child.parent_span_context.unwrap().span_id().to_hex(),
    parent.span_context.span_id().to_hex(),
  )
  @debug.assert_eq(attr_value(child.attributes, "child_attr"), Some(Bool(true)))
  @debug.assert_eq(child.status.code, Error)
  @debug.assert_eq(child.status.description, Some("bad"))
  let event = event_named(child.events, "failed")
  @debug.assert_eq(attr_int64(event.attributes, "rows"), Some(3L))
  @debug.assert_eq(attr_string(event.attributes, "message"), Some("bad"))
  ignore(event_named(child.events, "exception"))
}

///|
async test "OtelRuntime links follows-from and exposes current OpenTelemetry context" {
  let (exporter, tracer) = test_tracer()
  let runtime = @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(group, tracer)
    let ctx = root_ctx(runtime.dispatch())
    let (parent_handle, parent_ctx) = ctx.span(Info, "parent")
    let current = runtime.current_context(parent_ctx)
    assert_true(current.span_context().unwrap().is_valid())
    let parent_span = parent_handle.span_context().unwrap()
    let (follower_handle, _) = ctx.span(Info, "follower", follows_from=[
      parent_span,
    ])
    ignore(follower_handle.close())
    ignore(parent_handle.close())
    runtime.flush()
    runtime.shutdown()
    ctx.event(Info, "after-shutdown")
    runtime.shutdown()
    runtime
  })

  @debug.assert_eq(1, runtime.stats().dropped_records)
  let spans = exporter.finished_spans()
  @debug.assert_eq(2, spans.length())
  let parent = exported_span(spans, "parent")
  let follower = exported_span(spans, "follower")
  @debug.assert_eq(follower.links.length(), 1)
  @debug.assert_eq(
    follower.links[0].span_context.span_id().to_hex(),
    parent.span_context.span_id().to_hex(),
  )
}

///|
async test "OtelRuntime reports unclosed spans on shutdown" {
  let (_, tracer) = test_tracer()
  let runtime = @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(group, tracer)
    let ctx = root_ctx(runtime.dispatch())
    ignore(ctx.span(Info, "leaked"))
    runtime.shutdown()
    runtime
  })
  @debug.assert_eq(1, runtime.stats().unclosed_spans)
}

///|
async test "OtelRuntime counts dropped span ends when the queue is full" {
  let runtime = @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(
      group,
      slow_end_tracer(25),
      options=OtelOptions::new(
        queue_capacity=1,
        control_queue_capacity=2,
        ack_queue_capacity=2,
        command_timeout_ms=2000,
        shutdown_timeout_ms=2000,
      ),
    )
    let ctx = root_ctx(runtime.dispatch())
    for index in 0..<32 {
      let (handle, _) = ctx.span(Info, "burst-\{index}")
      ignore(handle.close())
    }
    runtime.shutdown()
    runtime
  })
  assert_true(runtime.stats().dropped_records > 0)
}

///|
test "conversion helpers preserve propagated span context and baggage" {
  let trace_id = @common.TraceId::from_hex("4bf92f3577b34da6a3ce929d0e0e4736").unwrap()
  let span_id = @common.SpanId::from_hex("00f067aa0ba902b7").unwrap()
  let trace_flags : @common.TraceFlags = Default::default()
  let otel_parent = @common.SpanContext::new(
    trace_id,
    span_id,
    trace_flags=trace_flags.with_sampled(true),
    is_remote=true,
    trace_state=@common.TraceState::empty().set("vendor", "value"),
  )
  let otel_baggage = @baggage.Baggage::new().insert_with_metadata(
    "tenant",
    "acme",
    @baggage.BaggageMetadata::new("meta"),
  )
  let otel_context = @context.Context::empty()
    .with_remote_span_context(otel_parent)
    .with_baggage(otel_baggage)
  let ctx = trace_context_from_otel(
    @tracing.Dispatch::noop(),
    @tracing.TraceIdAllocator::new_seeded(0UL),
    otel_context,
  )
  let parent = ctx.propagated_span().unwrap()
  @debug.assert_eq(parent.trace_id.to_hex(), trace_id.to_hex())
  @debug.assert_eq(parent.span_id.to_hex(), span_id.to_hex())
  @debug.assert_eq(parent.is_remote, true)
  @debug.assert_eq(parent.trace_state.get("vendor"), Some("value"))
  let entry = ctx.baggage().get("tenant").unwrap()
  @debug.assert_eq(entry.value, "acme")
  @debug.assert_eq(entry.metadata, Some("meta"))

  let roundtrip = span_context_from_otel(span_context_to_otel(parent)).unwrap()
  @debug.assert_eq(roundtrip, parent)
  let otel_roundtrip = baggage_to_otel(ctx.baggage())
  @debug.assert_eq(otel_roundtrip.get("tenant"), Some("acme"))
  @debug.assert_eq(
    baggage_from_otel(otel_roundtrip).get("tenant").unwrap().metadata,
    Some("meta"),
  )
}
