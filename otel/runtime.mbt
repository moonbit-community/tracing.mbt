///|
/// Configuration for the OpenTelemetry bridge runtime.
///
/// The bridge receives tracing callbacks synchronously, creates and updates
/// OpenTelemetry spans immediately, and sends span-end work to a background
/// worker. The queue and timeout values below therefore control the async
/// boundary rather than span construction itself. All capacity and timeout
/// values must be positive.
pub struct OtelOptions {
  /// Capacity of the bounded queue used for asynchronous span end commands.
  ///
  /// When this queue is full, newly closed spans cannot be handed to the
  /// worker. The record is dropped and `OtelStats.dropped_records` is
  /// incremented.
  queue_capacity : Int
  /// Capacity of the dedicated control queue used by `flush` and `shutdown`.
  ///
  /// Control messages are serialized by the runtime, so the default is small.
  /// Increase it only when embedding the runtime behind additional concurrent
  /// control paths.
  control_queue_capacity : Int
  /// Capacity of the acknowledgement queue paired with the control queue.
  ///
  /// The background worker writes one acknowledgement per accepted control
  /// command. The default capacity is intended to match the small control
  /// queue.
  ack_queue_capacity : Int
  /// Timeout used by `OtelRuntime::flush` and `OtelRuntime::shutdown`.
  ///
  /// The timeout covers waiting for the background worker to acknowledge the
  /// command. It includes time spent ending queued OpenTelemetry spans.
  command_timeout_ms : Int
  /// Timeout used by helper shutdown on scope exit.
  ///
  /// `with_otel_tracer` and `with_global_otel_tracer` protect shutdown from
  /// cancellation and bound the whole protected shutdown attempt with this
  /// timeout.
  shutdown_timeout_ms : Int
  /// Attach tracing target as a span/event attribute named `target`.
  with_target : Bool
  /// Attach tracing level as a span/event attribute named `level`.
  with_level : Bool
  /// Attach source location text as a span/event attribute named `loc`.
  with_location : Bool
  /// Convert Error-level events inside spans to span error status.
  ///
  /// The event message is used as the status description when present;
  /// otherwise the event name is used.
  error_events_to_status : Bool
  /// Convert Error-level events inside spans to OpenTelemetry exception events.
  ///
  /// This calls `record_error` on the OpenTelemetry span in addition to adding
  /// the original tracing event.
  error_events_to_exceptions : Bool
}

///|
/// Snapshot of OpenTelemetry bridge runtime counters.
///
/// The values are observational counters intended for health checks and tests.
/// They are read without stopping the runtime.
pub struct OtelStats {
  /// Records dropped because the runtime stopped accepting or the queue filled.
  ///
  /// Records can be dropped after shutdown starts, when the span-end queue is
  /// full, or when a tracing callback arrives after the runtime has stopped
  /// accepting work.
  dropped_records : Int
  /// Current count of started spans that have not been closed yet.
  ///
  /// On shutdown this becomes the number of spans that were started through the
  /// bridge but never closed by tracing code.
  unclosed_spans : Int
} derive(Debug)

///|
/// Errors raised by `OtelRuntime::flush` and `OtelRuntime::shutdown`.
pub suberror OtelRuntimeError {
  /// A control or acknowledgement queue closed before the command completed.
  ChannelClosed(String)
  /// A `flush`, `shutdown`, or helper shutdown wait exceeded its configured
  /// timeout.
  TimedOut(String)
} derive(Debug)

///|
/// Errors raised by helper functions when user code and shutdown both fail.
///
/// The helper preserves both failures: the first value is the original user
/// error, and the second value is the shutdown failure observed while leaving
/// the helper scope.
pub suberror OtelHelperError {
  /// User code raised an error and the protected runtime shutdown also failed.
  UserAndShutdownFailed(Error, OtelRuntimeError)
} derive(Debug)

///|
priv enum ControlCommand {
  Flush(Int64)
  Shutdown(Int64)
}

///|
priv enum RuntimeAck {
  Ok(Int64)
}

///|
priv enum ShutdownState {
  Running
  ShuttingDown(Int64)
  Succeeded
  FailedState(OtelRuntimeError)
}

///|
priv struct OtelSpanState {
  span : @trace.Span
  context : @context.Context
  status : Ref[@trace.Status?]
}

///|
priv struct OtelSubscriber {
  tracer : @trace.Tracer
  options : OtelOptions
  end_queue : @aqueue.Queue[@trace.Span]
  wake_queue : @aqueue.Queue[Unit]
  accepting : Ref[Bool]
  dropped_records : Ref[Int]
  span_states : Ref[Map[@tracing.SpanContext, OtelSpanState]]
  unclosed_spans : Ref[Int]
}

///|
let max_int64_as_uint64 : UInt64 = 9223372036854775807UL

///|
pub impl Default for OtelOptions with fn default() {
  {
    queue_capacity: 8192,
    control_queue_capacity: 8,
    ack_queue_capacity: 8,
    command_timeout_ms: 2000,
    shutdown_timeout_ms: 2000,
    with_target: true,
    with_level: false,
    with_location: false,
    error_events_to_status: true,
    error_events_to_exceptions: true,
  }
}

///|
/// Create OpenTelemetry bridge options explicitly.
///
/// All parameters are optional and default to `OtelOptions::default()`. The
/// constructor does not validate values; validation happens in
/// `OtelRuntime::start_in`, where non-positive capacities and timeouts abort.
pub fn OtelOptions::new(
  queue_capacity? : Int = 8192,
  control_queue_capacity? : Int = 8,
  ack_queue_capacity? : Int = 8,
  command_timeout_ms? : Int = 2000,
  shutdown_timeout_ms? : Int = 2000,
  with_target? : Bool = true,
  with_level? : Bool = false,
  with_location? : Bool = false,
  error_events_to_status? : Bool = true,
  error_events_to_exceptions? : Bool = true,
) -> OtelOptions {
  {
    queue_capacity,
    control_queue_capacity,
    ack_queue_capacity,
    command_timeout_ms,
    shutdown_timeout_ms,
    with_target,
    with_level,
    with_location,
    error_events_to_status,
    error_events_to_exceptions,
  }
}

///|
fn level_name(level : @tracing.Level) -> String {
  match level {
    @tracing.Trace => "trace"
    @tracing.Debug => "debug"
    @tracing.Info => "info"
    @tracing.Warn => "warn"
    @tracing.Error => "error"
  }
}

///|
fn tracing_value_to_text(value : @tracing.Value) -> String {
  match value {
    @tracing.Null => "null"
    @tracing.Bool(value) => value.to_string()
    @tracing.Int(value) => value.to_string()
    @tracing.Int64(value) => value.to_string()
    @tracing.UInt(value) => value.to_string()
    @tracing.UInt64(value) => value.to_string()
    @tracing.Double(value) => value.to_string()
    @tracing.String(value) => value
    @tracing.Bytes(value) => @base64.encode(value[:])
    @tracing.Array(values) => @tracing.Array(values).to_json_string()
    @tracing.Object(entries) => @tracing.Object(entries).to_json_string()
  }
}

///|
fn tracing_value_to_otel(value : @tracing.Value) -> @common.Value {
  match value {
    @tracing.Null => @common.String("null")
    @tracing.Bool(value) => @common.Bool(value)
    @tracing.Int(value) => @common.Int64(value.to_int64())
    @tracing.Int64(value) => @common.Int64(value)
    @tracing.UInt(value) => @common.Int64(value.to_int64())
    @tracing.UInt64(value) =>
      if value <= max_int64_as_uint64 {
        @common.Int64(value.reinterpret_as_int64())
      } else {
        @common.String(value.to_string())
      }
    @tracing.Double(value) => @common.Double(value)
    @tracing.String(value) => @common.String(value)
    @tracing.Bytes(value) => @common.Bytes(value)
    @tracing.Array(values) =>
      @common.Array(values.map(value => tracing_value_to_otel(value)))
    @tracing.Object(entries) =>
      @common.String(@tracing.Object(entries).to_json_string())
  }
}

///|
fn is_special_span_field(name : String) -> Bool {
  name == "otel.name" ||
  name == "otel.kind" ||
  name == "otel.status_code" ||
  name == "otel.status_description"
}

///|
fn append_metadata_attributes(
  attributes : Array[@common.KeyValue],
  metadata : @tracing.Metadata,
  options : OtelOptions,
) -> Unit {
  if options.with_target {
    attributes.push(
      @common.KeyValue::new("target", @common.String(metadata.target)),
    )
  }
  if options.with_level {
    attributes.push(
      @common.KeyValue::new("level", @common.String(level_name(metadata.level))),
    )
  }
  if options.with_location {
    attributes.push(
      @common.KeyValue::new("loc", @common.String(metadata.loc.to_string())),
    )
  }
}

///|
fn attributes_from_fields(
  fields : ArrayView[@tracing.Field],
  skip_special? : Bool = true,
) -> Array[@common.KeyValue] {
  let attributes : Array[@common.KeyValue] = []
  for field in fields {
    if skip_special && is_special_span_field(field.name) {
      continue
    }
    attributes.push(
      @common.KeyValue::new(field.name, tracing_value_to_otel(field.value)),
    )
  }
  attributes
}

///|
fn span_attributes(
  metadata : @tracing.Metadata,
  fields : ArrayView[@tracing.Field],
  options : OtelOptions,
) -> Array[@common.KeyValue] {
  let attributes = attributes_from_fields(fields)
  append_metadata_attributes(attributes, metadata, options)
  attributes
}

///|
fn event_attributes(
  record : @tracing.EventRecord,
  options : OtelOptions,
) -> Array[@common.KeyValue] {
  let attributes = attributes_from_fields(record.fields, skip_special=false)
  if record.message is Some(message) {
    attributes.push(@common.KeyValue::new("message", @common.String(message)))
  }
  append_metadata_attributes(attributes, record.metadata, options)
  attributes
}

///|
fn parse_span_kind(value : @tracing.Value) -> @trace.SpanKind? {
  match tracing_value_to_text(value).to_lower() {
    "internal" => Some(@trace.Internal)
    "client" => Some(@trace.Client)
    "server" => Some(@trace.Server)
    "producer" => Some(@trace.Producer)
    "consumer" => Some(@trace.Consumer)
    _ => None
  }
}

///|
fn parse_status_code(value : @tracing.Value) -> @trace.StatusCode? {
  match tracing_value_to_text(value).to_lower() {
    "unset" => Some(@trace.Unset)
    "ok" => Some(@trace.Ok)
    "error" => Some(@trace.Error)
    _ => None
  }
}

///|
priv struct SpanSpecials {
  name : String?
  kind : @trace.SpanKind?
  status_code : @trace.StatusCode?
  status_description : String?
}

///|
fn extract_span_specials(fields : ArrayView[@tracing.Field]) -> SpanSpecials {
  let mut name = None
  let mut kind = None
  let mut status_code = None
  let mut status_description = None
  for field in fields {
    match field.name {
      "otel.name" => name = Some(tracing_value_to_text(field.value))
      "otel.kind" => kind = parse_span_kind(field.value)
      "otel.status_code" => status_code = parse_status_code(field.value)
      "otel.status_description" =>
        status_description = Some(tracing_value_to_text(field.value))
      _ => ()
    }
  }
  { name, kind, status_code, status_description }
}

///|
fn status_priority(code : @trace.StatusCode) -> Int {
  match code {
    @trace.Unset => 0
    @trace.Error => 1
    @trace.Ok => 2
  }
}

///|
fn status_from_code(
  code : @trace.StatusCode,
  description : String?,
) -> @trace.Status {
  match code {
    @trace.Unset => @trace.Status::unset()
    @trace.Ok => @trace.Status::ok()
    @trace.Error => @trace.Status::error(description~)
  }
}

///|
fn OtelSpanState::apply_status(
  self : OtelSpanState,
  status : @trace.Status,
) -> Unit {
  let should_apply = match self.status.val {
    Some(current) =>
      status.code == current.code ||
      status_priority(status.code) > status_priority(current.code)
    None => true
  }
  if should_apply {
    self.span.set_status(status)
    self.status.val = Some(status)
  }
}

///|
fn OtelSubscriber::drop_record(self : OtelSubscriber) -> Unit {
  self.dropped_records.val += 1
}

///|
fn OtelSubscriber::notify(self : OtelSubscriber) -> Unit {
  ignore(self.wake_queue.try_put(())) catch {
    _ => ()
  }
}

///|
fn OtelSubscriber::enqueue_end(
  self : OtelSubscriber,
  span : @trace.Span,
) -> Unit {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  let accepted = self.end_queue.try_put(span) catch { _ => false }
  if accepted {
    self.notify()
  } else {
    self.drop_record()
  }
}

///|
fn OtelSubscriber::lookup_state(
  self : OtelSubscriber,
  span_context : @tracing.SpanContext,
) -> OtelSpanState? {
  self.span_states.val.get(span_context)
}

///|
fn OtelSubscriber::parent_context(
  self : OtelSubscriber,
  parent : @tracing.SpanContext?,
) -> @context.Context {
  match parent {
    Some(parent) =>
      match self.lookup_state(parent) {
        Some(state) => state.context
        None => context_with_tracing_span(@context.Context::empty(), parent)
      }
    None => @context.Context::empty()
  }
}

///|
fn OtelSubscriber::refresh_unclosed(self : OtelSubscriber) -> Unit {
  self.unclosed_spans.val = self.span_states.val.length()
}

///|
impl @tracing.Subscriber for OtelSubscriber with fn on_span_start(self, record) {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  let specials = extract_span_specials(record.fields)
  let span_name = match specials.name {
    Some(name) => name
    None => record.metadata.name
  }
  let mut builder = @trace.SpanBuilder::from_name(span_name).with_attributes(
    span_attributes(record.metadata, record.fields, self.options),
  )
  match specials.kind {
    Some(kind) => builder = builder.with_kind(kind)
    None => ()
  }
  let span = self.tracer.build_with_context(
    builder,
    self.parent_context(record.parent),
  )
  let state = { span, context: span.context(), status: Ref(None) }
  self.span_states.val[record.span] = state
  self.refresh_unclosed()
  match specials.status_code {
    Some(code) =>
      state.apply_status(status_from_code(code, specials.status_description))
    None => ()
  }
}

///|
impl @tracing.Subscriber for OtelSubscriber with fn on_span_record(self, record) {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  match self.lookup_state(record.span) {
    Some(state) => {
      let attributes = attributes_from_fields(record.fields)
      state.span.set_attributes(attributes)
      let specials = extract_span_specials(record.fields)
      match specials.name {
        Some(name) => state.span.update_name(name)
        None => ()
      }
      match specials.status_code {
        Some(code) =>
          state.apply_status(
            status_from_code(code, specials.status_description),
          )
        None => ()
      }
    }
    None => ()
  }
}

///|
impl @tracing.Subscriber for OtelSubscriber with fn on_event(self, record) {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  guard record.span is Some(span_context) else { return }
  guard self.lookup_state(span_context) is Some(state) else { return }
  let attributes = event_attributes(record, self.options)
  state.span.add_event(record.metadata.name, attributes~)
  if record.metadata.level == @tracing.Error {
    let description = match record.message {
      Some(message) => Some(message)
      None => Some(record.metadata.name)
    }
    if self.options.error_events_to_status {
      state.apply_status(@trace.Status::error(description~))
    }
    if self.options.error_events_to_exceptions {
      let message = match record.message {
        Some(message) => message
        None => record.metadata.name
      }
      state.span.record_error(message)
    }
  }
}

///|
impl @tracing.Subscriber for OtelSubscriber with fn on_span_end(self, record) {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  guard self.lookup_state(record.span) is Some(state) else { return }
  ignore(self.span_states.val.remove(record.span))
  self.refresh_unclosed()
  match record.status {
    @tracing.Ok =>
      if state.status.val is None {
        state.apply_status(@trace.Status::ok())
      }
    @tracing.Error =>
      state.apply_status(@trace.Status::error(description=record.error))
    @tracing.Cancelled => {
      let description = match record.error {
        Some(error) => Some(error)
        None => Some("cancelled")
      }
      state.apply_status(@trace.Status::error(description~))
    }
  }
  self.enqueue_end(state.span)
}

///|
impl @tracing.Subscriber for OtelSubscriber with fn on_span_link(self, record) {
  if !self.accepting.val {
    self.drop_record()
    return
  }
  guard self.lookup_state(record.span) is Some(state) else { return }
  let link_context = match self.lookup_state(record.follows_from) {
    Some(link_state) => link_state.span.span_context()
    None => span_context_to_otel(record.follows_from)
  }
  if link_context.is_valid() {
    state.span.add_link(link_context)
  }
}

///|
async fn drain_ended_spans(end_queue : @aqueue.Queue[@trace.Span]) -> Unit {
  for ;; {
    let item = end_queue.try_get() catch { _ => None }
    match item {
      Some(span) => span.end()
      None => break
    }
  }
}

///|
async fn ack_result(
  ack_queue : @aqueue.Queue[RuntimeAck],
  wake_queue : @aqueue.Queue[Unit],
  id : Int64,
) -> Unit {
  ack_queue.put(Ok(id)) catch {
    _ => ()
  }
  ignore(wake_queue.try_put(())) catch {
    _ => ()
  }
}

///|
async fn worker_loop(
  end_queue : @aqueue.Queue[@trace.Span],
  control_queue : @aqueue.Queue[ControlCommand],
  ack_queue : @aqueue.Queue[RuntimeAck],
  wake_queue : @aqueue.Queue[Unit],
  span_states : Ref[Map[@tracing.SpanContext, OtelSpanState]],
  unclosed_spans : Ref[Int],
) -> Unit {
  for ;; {
    wake_queue.get() catch {
      _ => break
    }
    let mut should_stop = false
    for ;; {
      let control = control_queue.try_get() catch { _ => None }
      match control {
        Some(Flush(id)) => {
          drain_ended_spans(end_queue)
          ack_result(ack_queue, wake_queue, id)
        }
        Some(Shutdown(id)) => {
          drain_ended_spans(end_queue)
          unclosed_spans.val = span_states.val.length()
          ack_result(ack_queue, wake_queue, id)
          should_stop = true
          break
        }
        None => ()
      }
      if should_stop {
        break
      }
      let item = end_queue.try_get() catch { _ => None }
      match item {
        Some(span) => span.end()
        None => break
      }
    }
    if should_stop {
      break
    }
  }
}

///|
fn next_command_id(counter : Ref[Int64]) -> Int64 {
  counter.val += 1L
  counter.val
}

///|
fn shutdown_timeout_message(timeout_ms : Int) -> String {
  "shutdown timed out after \{timeout_ms.to_string()}ms"
}

///|
fn runtime_error_of_error(err : Error) -> OtelRuntimeError? {
  match err {
    ChannelClosed(text) => Some(ChannelClosed(text))
    TimedOut(text) => Some(TimedOut(text))
    _ => None
  }
}

///|
/// Background OpenTelemetry bridge runtime.
///
/// `OtelRuntime` owns a tracing `Dispatch` backed by an OpenTelemetry
/// subscriber and a background worker that ends OpenTelemetry spans. Span
/// starts, span records, span events, status changes, and links are applied
/// synchronously from tracing callbacks; span end calls are moved to the
/// worker because OpenTelemetry span shutdown may perform asynchronous work.
///
/// Create a runtime inside an existing task group with `OtelRuntime::start_in`
/// when you need explicit control over root contexts, flushing, shutdown, or
/// health counters. For scoped application code, `with_otel_tracer` is usually
/// simpler.
pub struct OtelRuntime {
  priv dispatch : @tracing.Dispatch
  priv control_queue : @aqueue.Queue[ControlCommand]
  priv ack_queue : @aqueue.Queue[RuntimeAck]
  priv wake_queue : @aqueue.Queue[Unit]
  priv control_gate : @async.Semaphore
  priv next_command_id : Ref[Int64]
  priv dropped_records : Ref[Int]
  priv unclosed_spans : Ref[Int]
  priv accepting : Ref[Bool]
  priv shutdown_state : Ref[ShutdownState]
  priv command_timeout_ms : Int
  priv shutdown_timeout_ms : Int
  priv span_states : Ref[Map[@tracing.SpanContext, OtelSpanState]]
}

///|
async fn[X] OtelRuntime::with_control_gate(
  self : OtelRuntime,
  f : async () -> X,
) -> X {
  self.control_gate.acquire()
  try f() catch {
    err => {
      self.control_gate.release()
      raise err
    }
  } noraise {
    value => {
      self.control_gate.release()
      value
    }
  }
}

///|
async fn OtelRuntime::await_ack(self : OtelRuntime, id : Int64) -> Unit {
  for ;; {
    let ack = self.ack_queue.get() catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => raise ChannelClosed("ack queue closed")
    }
    match ack {
      Ok(ack_id) if ack_id == id => return
      _ => ()
    }
  }
}

///|
async fn OtelRuntime::await_ack_bounded(
  self : OtelRuntime,
  id : Int64,
  command : String,
) -> Unit {
  let result : Unit? = @async.with_timeout_opt(self.command_timeout_ms, () => {
    self.await_ack(id)
  }) catch {
    ChannelClosed(text) => raise ChannelClosed(text)
    TimedOut(text) => raise TimedOut(text)
    err => raise err
  }
  if result is None {
    raise TimedOut(
      "\{command} timed out after \{self.command_timeout_ms.to_string()}ms",
    )
  }
}

///|
async fn OtelRuntime::await_shutdown_ack(
  self : OtelRuntime,
  id : Int64,
) -> Unit {
  self.await_ack_bounded(id, "shutdown") catch {
    ChannelClosed(text) => {
      let err = ChannelClosed(text)
      self.shutdown_state.val = FailedState(err)
      raise err
    }
    TimedOut(text) => raise TimedOut(text)
    err => raise err
  }
  self.shutdown_state.val = Succeeded
}

///|
/// Start a background OpenTelemetry bridge runtime inside a task group.
///
/// The returned runtime is ready to receive tracing records through
/// `runtime.dispatch()`. The caller is responsible for creating one or more
/// `TraceContext` values with that dispatch and for calling `shutdown` before
/// the task group exits.
///
/// This function aborts if any capacity or timeout option is non-positive.
pub fn[X] OtelRuntime::start_in(
  group : @async.TaskGroup[X],
  tracer : @trace.Tracer,
  options? : OtelOptions = OtelOptions::default(),
) -> OtelRuntime {
  guard options.queue_capacity > 0 else {
    abort("OtelOptions.queue_capacity must be positive")
  }
  guard options.control_queue_capacity > 0 else {
    abort("OtelOptions.control_queue_capacity must be positive")
  }
  guard options.ack_queue_capacity > 0 else {
    abort("OtelOptions.ack_queue_capacity must be positive")
  }
  guard options.command_timeout_ms > 0 else {
    abort("OtelOptions.command_timeout_ms must be positive")
  }
  guard options.shutdown_timeout_ms > 0 else {
    abort("OtelOptions.shutdown_timeout_ms must be positive")
  }
  let end_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.queue_capacity),
  )
  let control_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.control_queue_capacity),
  )
  let ack_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.ack_queue_capacity),
  )
  let wake_queue = @aqueue.Queue::new(kind=@aqueue.DiscardLatest(1))
  let accepting = Ref(true)
  let dropped_records = Ref(0)
  let unclosed_spans = Ref(0)
  let span_states : Ref[Map[@tracing.SpanContext, OtelSpanState]] = Ref({})
  let subscriber = {
    tracer,
    options,
    end_queue,
    wake_queue,
    accepting,
    dropped_records,
    span_states,
    unclosed_spans,
  }
  let dispatch = @tracing.Dispatch::from_subscriber(subscriber)
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    worker_loop(
      end_queue, control_queue, ack_queue, wake_queue, span_states, unclosed_spans,
    )
  })
  {
    dispatch,
    control_queue,
    ack_queue,
    wake_queue,
    control_gate: @async.Semaphore::new(1),
    next_command_id: Ref(0L),
    dropped_records,
    unclosed_spans,
    accepting,
    shutdown_state: Ref(Running),
    command_timeout_ms: options.command_timeout_ms,
    shutdown_timeout_ms: options.shutdown_timeout_ms,
    span_states,
  }
}

///|
/// Return the dispatch that forwards tracing records into this runtime.
///
/// Pass this dispatch to `TraceContext::root` or other tracing constructors.
/// Records emitted through contexts backed by this dispatch are converted to
/// OpenTelemetry span operations.
pub fn OtelRuntime::dispatch(self : OtelRuntime) -> @tracing.Dispatch {
  self.dispatch
}

///|
/// Snapshot bridge runtime counters.
///
/// This method does not flush or synchronize with the background worker. Use it
/// for telemetry about the bridge itself, for tests, or after `shutdown` to
/// inspect final drop and unclosed-span counts.
pub fn OtelRuntime::stats(self : OtelRuntime) -> OtelStats {
  {
    dropped_records: self.dropped_records.val,
    unclosed_spans: self.unclosed_spans.val,
  }
}

///|
/// Return the OpenTelemetry context corresponding to a tracing context.
///
/// The returned context contains the OpenTelemetry span context for the current
/// tracing span when that span was created by this runtime. If the tracing
/// context only has a propagated parent, the propagated parent is installed
/// instead. Tracing baggage is converted and attached in both cases.
///
/// Use this when calling downstream OpenTelemetry-aware APIs from code that
/// otherwise carries `TraceContext`.
pub fn OtelRuntime::current_context(
  self : OtelRuntime,
  tracing_context : @tracing.TraceContext,
) -> @context.Context {
  let base = match tracing_context.current_span() {
    Some(span_context) =>
      match self.span_states.val.get(span_context) {
        Some(state) => state.context
        None =>
          match tracing_context.propagated_span() {
            Some(propagated) =>
              context_with_tracing_span(@context.Context::empty(), propagated)
            None => @context.Context::empty()
          }
      }
    None =>
      match tracing_context.propagated_span() {
        Some(propagated) =>
          context_with_tracing_span(@context.Context::empty(), propagated)
        None => @context.Context::empty()
      }
  }
  tracing_context_baggage(base, tracing_context)
}

///|
/// Ask the background worker to end all queued spans accepted so far.
///
/// `flush` waits until the worker has ended every span that had already been
/// closed and successfully queued before the control command is processed. It
/// does not close currently open tracing spans, does not stop future records,
/// and is safe to call more than once. If shutdown is already in progress,
/// `flush` waits for that shutdown acknowledgement instead.
pub async fn OtelRuntime::flush(self : OtelRuntime) -> Unit {
  self.with_control_gate(() => {
    match self.shutdown_state.val {
      Succeeded => ()
      FailedState(err) => raise err
      ShuttingDown(id) => self.await_shutdown_ack(id)
      Running => {
        let id = next_command_id(self.next_command_id)
        self.control_queue.put(Flush(id)) catch {
          _ => raise ChannelClosed("control queue closed")
        }
        ignore(self.wake_queue.try_put(())) catch {
          _ => ()
        }
        self.await_ack_bounded(id, "flush")
      }
    }
  })
}

///|
/// Ask the background worker to drain, terminate, and stop accepting records.
///
/// Shutdown first marks the runtime as no longer accepting tracing records,
/// then asks the worker to end all queued spans and exit. Records emitted after
/// shutdown begins are counted as dropped. The method is idempotent after a
/// successful shutdown; repeated calls return without sending another command.
pub async fn OtelRuntime::shutdown(self : OtelRuntime) -> Unit {
  self.with_control_gate(() => {
    match self.shutdown_state.val {
      Succeeded => return
      FailedState(err) => raise err
      ShuttingDown(id) => return self.await_shutdown_ack(id)
      Running => ()
    }
    self.accepting.val = false
    let id = next_command_id(self.next_command_id)
    self.control_queue.put(Shutdown(id)) catch {
      _ => {
        let err = ChannelClosed("control queue closed")
        self.shutdown_state.val = FailedState(err)
        raise err
      }
    }
    ignore(self.wake_queue.try_put(())) catch {
      _ => ()
    }
    self.shutdown_state.val = ShuttingDown(id)
    self.await_shutdown_ack(id)
  })
}

///|
async fn protected_shutdown(runtime : OtelRuntime) -> Result[Unit, Error] {
  let result : Result[Unit, Error]? = @async.protect_from_cancel(() => {
    @async.with_timeout_opt(runtime.shutdown_timeout_ms, () => {
      try? runtime.shutdown()
    })
  })
  match result {
    Some(shutdown_result) => shutdown_result
    None => Err(TimedOut(shutdown_timeout_message(runtime.shutdown_timeout_ms)))
  }
}

///|
/// Run `f` with a fresh tracing root context exported through `tracer`.
///
/// This helper creates an `OtelRuntime`, builds a root `TraceContext` with a
/// fresh trace-id allocator, passes that context to `f`, and attempts protected
/// runtime shutdown before returning. On a clean callback return, shutdown
/// errors are raised directly. If `f` raises and shutdown also fails with an
/// `OtelRuntimeError`, the helper raises
/// `OtelHelperError::UserAndShutdownFailed`.
///
/// Cancellation errors from `f` are re-raised after a best-effort protected
/// shutdown attempt.
pub async fn[X] with_otel_tracer(
  tracer : @trace.Tracer,
  options? : OtelOptions = OtelOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  @async.with_task_group(group => {
    let runtime = OtelRuntime::start_in(group, tracer, options~)
    let ctx = @tracing.TraceContext::root(
      runtime.dispatch(),
      @tracing.TraceIdAllocator::new(),
    )
    try f(ctx) catch {
      err if @async.is_cancellation_error(err) => {
        ignore(protected_shutdown(runtime))
        raise err
      }
      err =>
        match protected_shutdown(runtime) {
          Ok(_) => raise err
          Err(shutdown_err) =>
            match runtime_error_of_error(shutdown_err) {
              Some(runtime_err) => raise UserAndShutdownFailed(err, runtime_err)
              None => raise shutdown_err
            }
        }
    } noraise {
      value =>
        match protected_shutdown(runtime) {
          Ok(_) => value
          Err(err) => raise err
        }
    }
  })
}

///|
/// Run `f` with a tracer looked up from the OpenTelemetry global provider.
///
/// `name`, `version`, `schema_url`, and `attributes` are forwarded to
/// `@global.tracer`. The resulting tracer is then passed to `with_otel_tracer`,
/// so this helper has the same scoped-runtime and shutdown behavior.
pub async fn[X] with_global_otel_tracer(
  name : String,
  version? : String? = None,
  schema_url? : String? = None,
  attributes? : ArrayView[@common.KeyValue] = [],
  options? : OtelOptions = OtelOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  with_otel_tracer(
    @global.tracer(name, version~, schema_url~, attributes~),
    options~,
    f,
  )
}
