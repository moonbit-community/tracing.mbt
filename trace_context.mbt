///|
priv struct TraceShared {
  dispatch : Dispatch
  trace_ids : TraceIdAllocator
  root_parent : SpanContext?
  trace_flags : TraceFlags
  trace_state : TraceState
  trace_id : Ref[TraceId?]
  next_span_id : Ref[Int64]
}

///|
/// Handle that owns the lifecycle of a started span.
///
/// A disabled handle represents a span callsite that was filtered out. Disabled
/// handles never emit records and all lifecycle methods report `false`.
pub struct SpanHandle {
  priv span : SpanContext?
  priv lanes : Array[Lane]
  priv closed : Ref[Bool]
}

///|
/// Snapshot of tracing state that callers pass explicitly across async
/// boundaries.
pub struct TraceContext {
  priv shared : TraceShared
  priv current_span : SpanContext?
  priv baggage : Baggage
}

///|
fn new_trace_shared(
  dispatch : Dispatch,
  trace_ids : TraceIdAllocator,
  root_parent : SpanContext?,
) -> TraceShared {
  let trace_id = match root_parent {
    Some(parent) if parent.is_valid() => Some(parent.trace_id)
    _ => None
  }
  let trace_flags = match root_parent {
    Some(parent) if parent.is_valid() => parent.trace_flags
    _ => TraceFlags::sampled()
  }
  let trace_state = match root_parent {
    Some(parent) if parent.is_valid() => parent.trace_state
    _ => TraceState::empty()
  }
  {
    dispatch,
    trace_ids,
    root_parent,
    trace_flags,
    trace_state,
    trace_id: Ref::new(trace_id),
    next_span_id: Ref::new(0L),
  }
}

///|
fn TraceShared::allocate_span_id(self : TraceShared) -> SpanId {
  self.trace_ids.allocate_span_id(self.next_span_id)
}

///|
fn TraceContext::ensure_trace_id(self : TraceContext) -> TraceId {
  match self.shared.trace_id.val {
    Some(trace_id) => trace_id
    None => {
      let trace_id = self.shared.trace_ids.allocate()
      self.shared.trace_id.val = Some(trace_id)
      trace_id
    }
  }
}

///|
fn SpanHandle::disabled() -> SpanHandle {
  { span: None, lanes: [], closed: Ref::new(true) }
}

///|
fn SpanHandle::enabled(span : SpanContext, lanes : Array[Lane]) -> SpanHandle {
  { span: Some(span), lanes, closed: Ref::new(false) }
}

///|
/// Return the span identity owned by this handle.
///
/// Disabled handles return `None`.
pub fn SpanHandle::span_context(self : SpanHandle) -> SpanContext? {
  self.span
}

///|
pub fn SpanHandle::span_ref(self : SpanHandle) -> SpanContext? {
  self.span_context()
}

///|
/// Record additional fields on an active span.
///
/// The function returns `false` when the handle is disabled or the span was
/// already closed.
pub fn SpanHandle::record(self : SpanHandle, fields : ArrayView[Field]) -> Bool {
  guard self.span is Some(span) else { return false }
  guard !self.closed.val else { return false }
  validate_fields(fields)
  let record = { span, fields: fields.to_array() }
  for lane in self.lanes {
    lane.subscriber.on_span_record(record)
  }
  true
}

///|
/// Emit a follows-from link from this span to `cause`.
///
/// The function returns `false` when the handle is disabled or the span was
/// already closed.
pub fn SpanHandle::follows_from(self : SpanHandle, cause : SpanContext) -> Bool {
  guard self.span is Some(span) else { return false }
  guard !self.closed.val else { return false }
  let link = { span, follows_from: cause }
  for lane in self.lanes {
    lane.subscriber.on_span_link(link)
  }
  true
}

///|
/// Close a span handle exactly once.
///
/// `status` defaults to `Ok`. When `error` is provided it is carried in the
/// emitted `SpanEnd` record.
///
/// The function returns `true` only for the first successful close.
pub fn SpanHandle::close(
  self : SpanHandle,
  status? : SpanStatus = Ok,
  error? : String,
) -> Bool {
  guard self.span is Some(span) else { return false }
  guard !self.closed.val else { return false }
  self.closed.val = true
  let record = { span, status, error }
  for lane in self.lanes {
    lane.subscriber.on_span_end(record)
  }
  true
}

///|
fn TraceContext::start_span(
  self : TraceContext,
  level : Level,
  name : String,
  target : String?,
  fields : ArrayView[Field],
  follows_from : ArrayView[SpanContext],
  parent : SpanContext?,
  filtered_ctx : TraceContext,
  loc : SourceLoc,
) -> (SpanHandle, TraceContext) {
  validate_fields(fields)
  let metadata = {
    kind: Span,
    level,
    name,
    target: normalize_target(target, loc),
    loc,
  }
  let lanes = self.dispatch().select_lanes(metadata)
  if lanes.is_empty() {
    (SpanHandle::disabled(), filtered_ctx)
  } else {
    let trace_id = self.ensure_trace_id()
    let span = SpanContext::new(
      trace_id,
      self.shared.allocate_span_id(),
      trace_flags=self.shared.trace_flags,
      trace_state=self.shared.trace_state,
    )
    let start = { metadata, span, parent, fields: fields.to_array() }
    for lane in lanes {
      lane.subscriber.on_span_start(start)
    }
    let handle = SpanHandle::enabled(span, lanes)
    for link in follows_from {
      ignore(handle.follows_from(link))
    }
    (
      handle,
      { shared: self.shared, current_span: Some(span), baggage: self.baggage },
    )
  }
}

///|
async fn[X] run_started_span(
  handle : SpanHandle,
  child_ctx : TraceContext,
  filtered_ctx : TraceContext,
  f : async (TraceContext) -> X,
) -> X {
  guard handle.span_context() is Some(_) else { return f(filtered_ctx) }
  try f(child_ctx) catch {
    err if @async.is_cancellation_error(err) => {
      ignore(handle.close(status=Cancelled))
      raise err
    }
    err => {
      ignore(handle.close(status=Error, error=err.to_string()))
      raise err
    }
  } noraise {
    value => {
      ignore(handle.close())
      value
    }
  }
}

///|
/// Create a root tracing context backed by `dispatch`.
///
/// The trace identifier is allocated lazily when the context first emits an
/// enabled record.
pub fn TraceContext::root(
  dispatch : Dispatch,
  trace_ids : TraceIdAllocator,
) -> TraceContext {
  {
    shared: new_trace_shared(dispatch, trace_ids, None),
    current_span: None,
    baggage: Baggage::empty(),
  }
}

///|
/// Create a root tracing context that inherits a propagated remote parent.
pub fn TraceContext::root_with_parent(
  dispatch : Dispatch,
  trace_ids : TraceIdAllocator,
  parent : SpanContext,
  baggage? : Baggage = Baggage::empty(),
) -> TraceContext {
  let root_parent = if parent.is_valid() { Some(parent) } else { None }
  {
    shared: new_trace_shared(dispatch, trace_ids, root_parent),
    current_span: None,
    baggage,
  }
}

///|
/// Return the current span, if any.
pub fn TraceContext::current_span(self : TraceContext) -> SpanContext? {
  self.current_span
}

///|
/// Return the span that should be propagated to downstream work.
///
/// This is the current local span when one exists, otherwise the propagated
/// remote parent captured by `root_with_parent`.
pub fn TraceContext::propagated_span(self : TraceContext) -> SpanContext? {
  match self.current_span {
    Some(span) => Some(span)
    None => self.shared.root_parent
  }
}

///|
fn TraceContext::dispatch(self : TraceContext) -> Dispatch {
  self.shared.dispatch
}

///|
pub fn TraceContext::baggage(self : TraceContext) -> Baggage {
  self.baggage
}

///|
pub fn TraceContext::with_baggage(
  self : TraceContext,
  baggage : Baggage,
) -> TraceContext {
  { ..self, baggage, }
}

///|
/// Emit an event from the current trace context.
///
/// If no dispatch lane enables the callsite metadata, the event is ignored.
#callsite(autofill(loc))
pub fn TraceContext::event(
  self : TraceContext,
  level : Level,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  validate_fields(fields)
  let metadata = {
    kind: Event,
    level,
    name,
    target: normalize_target(target, loc),
    loc,
  }
  let lanes = self.dispatch().select_lanes(metadata)
  if lanes.is_empty() {
    return
  }
  let record = {
    metadata,
    trace_id: self.ensure_trace_id(),
    span: self.current_span,
    message,
    fields: fields.to_array(),
  }
  for lane in lanes {
    lane.subscriber.on_event(record)
  }
}

///|
/// Emit a `Trace` level event from the current trace context.
#callsite(autofill(loc))
pub fn TraceContext::trace(
  self : TraceContext,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  self.event(Trace, name, message?, target?, fields~, loc~)
}

///|
/// Emit a `Debug` level event from the current trace context.
#callsite(autofill(loc))
pub fn TraceContext::debug(
  self : TraceContext,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  self.event(Debug, name, message?, target?, fields~, loc~)
}

///|
/// Emit an `Info` level event from the current trace context.
#callsite(autofill(loc))
pub fn TraceContext::info(
  self : TraceContext,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  self.event(Info, name, message?, target?, fields~, loc~)
}

///|
/// Emit a `Warn` level event from the current trace context.
#callsite(autofill(loc))
pub fn TraceContext::warn(
  self : TraceContext,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  self.event(Warn, name, message?, target?, fields~, loc~)
}

///|
/// Emit an `Error` level event from the current trace context.
#callsite(autofill(loc))
pub fn TraceContext::error(
  self : TraceContext,
  name : String,
  message? : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
) -> Unit {
  self.event(Error, name, message?, target?, fields~, loc~)
}

///|
/// Start a child span below the current span, if the callsite is enabled.
///
/// If the span is filtered out, the returned child context is exactly `self`
/// and the handle is disabled.
#callsite(autofill(loc))
pub fn TraceContext::span(
  self : TraceContext,
  level : Level,
  name : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  follows_from? : ArrayView[SpanContext] = [],
  loc~ : SourceLoc,
) -> (SpanHandle, TraceContext) {
  let parent = match self.current_span {
    Some(span) => Some(span)
    None => self.shared.root_parent
  }
  self.start_span(level, name, target, fields, follows_from, parent, self, loc)
}

///|
/// Run `f` inside a child span when the callsite is enabled.
///
/// On normal return an enabled span ends with `SpanStatus::Ok`.
/// When `f` fails with a cancellation error, an enabled span ends with
/// `SpanStatus::Cancelled`.
/// Any other error ends an enabled span with `SpanStatus::Error`, records
/// `err.to_string()` as the end error text, and then re-raises the original
/// error.
///
/// If the callsite is filtered out, `f` runs with the original context and no
/// span records are emitted.
#callsite(autofill(loc))
pub async fn[X] TraceContext::with_span(
  self : TraceContext,
  level : Level,
  name : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  follows_from? : ArrayView[SpanContext] = [],
  loc~ : SourceLoc,
  f : async (TraceContext) -> X,
) -> X {
  let parent = match self.current_span {
    Some(span) => Some(span)
    None => self.shared.root_parent
  }
  let (handle, child_ctx) = self.start_span(
    level, name, target, fields, follows_from, parent, self, loc,
  )
  run_started_span(handle, child_ctx, self, f)
}

///|
/// Spawn a task that inherits the exact tracing context `ctx`.
pub fn[G, X] spawn_inherit(
  group : @async.TaskGroup[G],
  ctx : TraceContext,
  f : async (TraceContext) -> X,
  no_wait? : Bool = false,
  allow_failure? : Bool = false,
) -> @async.Task[X] {
  group.spawn(no_wait~, allow_failure~, () => f(ctx))
}

///|
/// Spawn a task inside a new child span in `ctx`'s trace.
///
/// The new span is a child of `ctx.current_span()` when one exists. Otherwise
/// it falls back to the propagated root parent, if any.
#callsite(autofill(loc))
pub fn[G, X] spawn_child_span(
  group : @async.TaskGroup[G],
  ctx : TraceContext,
  level : Level,
  name : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
  f : async (TraceContext) -> X,
  no_wait? : Bool = false,
  allow_failure? : Bool = false,
) -> @async.Task[X] {
  let (handle, child_ctx) = ctx.start_span(
    level,
    name,
    target,
    fields,
    [],
    match ctx.current_span() {
      Some(span) => Some(span)
      None => ctx.shared.root_parent
    },
    ctx,
    loc,
  )
  group.spawn(no_wait~, allow_failure~, () => {
    run_started_span(handle, child_ctx, ctx, f)
  })
}

///|
/// Spawn a task in a new span that stays in the same trace but is not a tree
/// child of the current span.
///
/// When `ctx.current_span()` exists, the new span emits a single follows-from
/// link to it. When there is no current span, the spawned task still stays in
/// the same trace and no link is emitted.
#callsite(autofill(loc))
pub fn[G, X] spawn_follower_span(
  group : @async.TaskGroup[G],
  ctx : TraceContext,
  level : Level,
  name : String,
  target? : String,
  fields? : ArrayView[Field] = [],
  loc~ : SourceLoc,
  f : async (TraceContext) -> X,
  no_wait? : Bool = false,
  allow_failure? : Bool = false,
) -> @async.Task[X] {
  let follows_from : Array[SpanContext] = []
  if ctx.current_span() is Some(current_span) {
    follows_from.push(current_span)
  }
  let (handle, child_ctx) = ctx.start_span(
    level,
    name,
    target,
    fields,
    follows_from[:],
    None,
    ctx,
    loc,
  )
  group.spawn(no_wait~, allow_failure~, () => {
    run_started_span(handle, child_ctx, ctx, f)
  })
}
