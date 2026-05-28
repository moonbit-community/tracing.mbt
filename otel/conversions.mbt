///|
fn common_trace_flags_to_tracing(
  flags : @common.TraceFlags,
) -> @tracing.TraceFlags {
  let raw = @string.parse_int(flags.to_hex(), base=16) catch { _ => 0 }
  @tracing.TraceFlags::new(raw.reinterpret_as_uint())
}

///|
fn common_trace_state_to_tracing(
  trace_state : @common.TraceState,
) -> @tracing.TraceState {
  match trace_state.to_header() {
    Some(header) =>
      match @tracing.TraceState::from_header(header) {
        Some(state) => state
        None => @tracing.TraceState::empty()
      }
    None => @tracing.TraceState::empty()
  }
}

///|
fn tracing_trace_state_to_common(
  trace_state : @tracing.TraceState,
) -> @common.TraceState {
  @common.TraceState::from_header(trace_state.header())
}

///|
/// Convert a tracing span context into an OpenTelemetry span context.
///
/// Trace id, span id, trace flags, trace state, and remote/local state are
/// preserved. If an id cannot be represented by the OpenTelemetry interface
/// type, the corresponding OpenTelemetry invalid id is used.
pub fn span_context_to_otel(
  span_context : @tracing.SpanContext,
) -> @common.SpanContext {
  let trace_id = match
    @common.TraceId::from_bytes(span_context.trace_id.to_bytes()) {
    Some(trace_id) => trace_id
    None => @common.TraceId::invalid()
  }
  let span_id = match
    @common.SpanId::from_bytes(span_context.span_id.to_bytes()) {
    Some(span_id) => span_id
    None => @common.SpanId::invalid()
  }
  @common.SpanContext::new(
    trace_id,
    span_id,
    trace_flags=@common.TraceFlags::new(span_context.trace_flags.to_uint()),
    is_remote=span_context.is_remote,
    trace_state=tracing_trace_state_to_common(span_context.trace_state),
  )
}

///|
/// Convert an OpenTelemetry span context into a tracing span context.
///
/// Invalid OpenTelemetry span contexts return `None`. Valid contexts preserve
/// trace id, span id, trace flags, trace state, and whether the context was
/// remote.
pub fn span_context_from_otel(
  span_context : @common.SpanContext,
) -> @tracing.SpanContext? {
  guard span_context.is_valid() else { return None }
  let trace_id = match
    @tracing.TraceId::from_bytes(span_context.trace_id().bytes()[:]) {
    Some(trace_id) => trace_id
    None => return None
  }
  let span_id = match
    @tracing.SpanId::from_bytes(span_context.span_id().bytes()[:]) {
    Some(span_id) => span_id
    None => return None
  }
  Some(
    @tracing.SpanContext::new(
      trace_id,
      span_id,
      trace_flags=common_trace_flags_to_tracing(span_context.trace_flags()),
      trace_state=common_trace_state_to_tracing(span_context.trace_state()),
      is_remote=span_context.is_remote(),
    ),
  )
}

///|
/// Convert tracing baggage into OpenTelemetry baggage.
///
/// Each tracing baggage entry is inserted into a new OpenTelemetry baggage
/// value. Entry metadata is preserved when present.
pub fn baggage_to_otel(baggage : @tracing.Baggage) -> @baggage.Baggage {
  let mut out = @baggage.Baggage::new()
  for entry in baggage.entries() {
    match entry.metadata {
      Some(metadata) =>
        out = out.insert_with_metadata(
          entry.name,
          entry.value,
          @baggage.BaggageMetadata::new(metadata),
        )
      None => out = out.insert(entry.name, entry.value)
    }
  }
  out
}

///|
/// Convert OpenTelemetry baggage into tracing baggage.
///
/// Entries with empty OpenTelemetry metadata are inserted without tracing
/// metadata. Entries rejected by `tracing.Baggage::insert` are skipped, matching
/// tracing baggage validation rules.
pub fn baggage_from_otel(baggage : @baggage.Baggage) -> @tracing.Baggage {
  let mut out = @tracing.Baggage::empty()
  for entry in baggage.entries() {
    let metadata = entry.metadata.as_string()
    let inserted = if metadata == "" {
      out.insert(entry.key.as_string(), entry.value)
    } else {
      out.insert(entry.key.as_string(), entry.value, metadata~)
    }
    match inserted {
      Some(next) => out = next
      None => ()
    }
  }
  out
}

///|
fn tracing_context_from_baggage(
  dispatch : @tracing.Dispatch,
  trace_ids : @tracing.TraceIdAllocator,
  baggage : @tracing.Baggage,
) -> @tracing.TraceContext {
  @tracing.TraceContext::root(dispatch, trace_ids).with_baggage(baggage)
}

///|
fn context_with_tracing_span(
  context : @context.Context,
  span_context : @tracing.SpanContext,
) -> @context.Context {
  let otel_span_context = span_context_to_otel(span_context)
  if !otel_span_context.is_valid() {
    context
  } else if span_context.is_remote {
    context.with_remote_span_context(otel_span_context)
  } else {
    context.with_span_context(otel_span_context)
  }
}

///|
fn tracing_context_baggage(
  context : @context.Context,
  tracing_context : @tracing.TraceContext,
) -> @context.Context {
  context.with_baggage(baggage_to_otel(tracing_context.baggage()))
}

///|
/// Build a tracing root context from an OpenTelemetry context.
///
/// The returned `TraceContext` uses `dispatch` for future tracing records and
/// `trace_ids` for newly allocated local spans. If the OpenTelemetry context
/// carries a valid span context, that span becomes the propagated parent of the
/// root trace. OpenTelemetry baggage is converted and attached to the tracing
/// context regardless of whether a parent span is present.
pub fn trace_context_from_otel(
  dispatch : @tracing.Dispatch,
  trace_ids : @tracing.TraceIdAllocator,
  context : @context.Context,
) -> @tracing.TraceContext {
  let baggage = baggage_from_otel(context.baggage())
  match context.span_context() {
    Some(span_context) =>
      match span_context_from_otel(span_context) {
        Some(parent) =>
          @tracing.TraceContext::root_with_parent(
            dispatch,
            trace_ids,
            parent,
            baggage~,
          )
        None => tracing_context_from_baggage(dispatch, trace_ids, baggage)
      }
    None => tracing_context_from_baggage(dispatch, trace_ids, baggage)
  }
}
