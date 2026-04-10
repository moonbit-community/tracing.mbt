///|
/// Configuration for the JSON Lines formatter runtime.
pub struct JsonOptions {
  /// Capacity of the bounded record queue used by the hot path.
  record_queue_capacity : Int
  /// Capacity of the dedicated control queue used by `flush` and `shutdown`.
  control_queue_capacity : Int
  /// Capacity of the acknowledgement queue paired with the control queue.
  ack_queue_capacity : Int
  /// Buffer size used by the background `BufferedWriter`.
  writer_buffer_size : Int
  /// Timeout used by `JsonRuntime::flush` and `JsonRuntime::shutdown` while
  /// waiting for a writer acknowledgement.
  command_timeout_ms : Int
  /// Timeout used by `with_json_*` helpers when they attempt protected
  /// shutdown during scope exit.
  shutdown_timeout_ms : Int
}

///|
/// Snapshot of runtime health counters.
pub struct JsonStats {
  dropped_records : Int
  writer_errors : Int
  unclosed_spans : Int
} derive(Debug)

///|
/// Errors raised by `JsonRuntime::flush` and `JsonRuntime::shutdown`.
pub suberror JsonRuntimeError {
  WriterFailed(String)
  ChannelClosed(String)
  TimedOut(String)
} derive(Debug)

///|
/// Errors raised by `with_json_*` helpers when both user code and shutdown
/// fail.
pub suberror JsonHelperError {
  UserAndShutdownFailed(Error, JsonRuntimeError)
} derive(Debug)

///|
priv enum ControlCommand {
  Flush(Int64)
  Shutdown(Int64)
}

///|
priv enum RuntimeAck {
  Ok(Int64)
  Failed(Int64, String)
}

///|
priv enum ShutdownState {
  Running
  ShuttingDown(Int64)
  Succeeded
  FailedState(JsonRuntimeError)
}

///|
priv struct JsonSubscriber {
  record_queue : @aqueue.Queue[String]
  wake_queue : @aqueue.Queue[Unit]
  accepting : Ref[Bool]
  dropped_records : Ref[Int]
  open_spans : Ref[Set[@tracing.SpanRef]]
}

///|
fn append_json_string(builder : StringBuilder, value : String) -> Unit {
  builder.write_char('"')
  for ch in value {
    match ch {
      '"' => builder.write_string("\\\"")
      '\\' => builder.write_string("\\\\")
      '\n' => builder.write_string("\\n")
      '\r' => builder.write_string("\\r")
      '\t' => builder.write_string("\\t")
      '\u0008' => builder.write_string("\\b")
      '\u000c' => builder.write_string("\\f")
      ch if ch.to_int() < 0x20 => {
        let digits = "0123456789abcdef"
        builder.write_string("\\u")
        builder.write_char(
          digits[(ch.to_int() >> 12) & 0xF].to_int().unsafe_to_char(),
        )
        builder.write_char(
          digits[(ch.to_int() >> 8) & 0xF].to_int().unsafe_to_char(),
        )
        builder.write_char(
          digits[(ch.to_int() >> 4) & 0xF].to_int().unsafe_to_char(),
        )
        builder.write_char(digits[ch.to_int() & 0xF].to_int().unsafe_to_char())
      }
      ch => builder.write_char(ch)
    }
  }
  builder.write_char('"')
}

///|
fn append_level(builder : StringBuilder, level : @tracing.Level) -> Unit {
  append_json_string(
    builder,
    match level {
      @tracing.Trace => "trace"
      @tracing.Debug => "debug"
      @tracing.Info => "info"
      @tracing.Warn => "warn"
      @tracing.Error => "error"
    },
  )
}

///|
fn append_status(builder : StringBuilder, status : @tracing.SpanStatus) -> Unit {
  append_json_string(
    builder,
    match status {
      @tracing.Ok => "ok"
      @tracing.Error => "error"
      @tracing.Cancelled => "cancelled"
    },
  )
}

///|
fn append_fields(
  builder : StringBuilder,
  fields : ArrayView[@tracing.Field],
) -> Unit {
  builder.write_char('{')
  for index = 0; index < fields.length(); index = index + 1 {
    if index > 0 {
      builder.write_char(',')
    }
    let field = fields[index]
    append_json_string(builder, field.name)
    builder.write_char(':')
    builder.write_string(field.value.to_json_string())
  }
  builder.write_char('}')
}

///|
fn append_metadata_fields(
  builder : StringBuilder,
  metadata : @tracing.Metadata,
) -> Unit {
  builder.write_string(",\"level\":")
  append_level(builder, metadata.level)
  builder.write_string(",\"name\":")
  append_json_string(builder, metadata.name)
  builder.write_string(",\"target\":")
  append_json_string(builder, metadata.target)
  builder.write_string(",\"loc\":")
  append_json_string(builder, metadata.loc.to_string())
}

///|
fn encode_span_start(record : @tracing.SpanStart) -> String {
  let builder = StringBuilder::new()
  builder.write_string("{\"kind\":\"span_start\",\"trace_id\":")
  append_json_string(builder, record.span.trace_id.to_hex())
  builder.write_string(",\"span_id\":")
  append_json_string(builder, record.span.span_id.to_hex())
  if record.parent is Some(parent) {
    builder.write_string(",\"parent_span_id\":")
    append_json_string(builder, parent.span_id.to_hex())
  }
  append_metadata_fields(builder, record.metadata)
  builder.write_string(",\"fields\":")
  append_fields(builder, record.fields[:])
  builder.write_char('}')
  builder.to_string()
}

///|
fn encode_span_record(record : @tracing.SpanRecord) -> String {
  let builder = StringBuilder::new()
  builder.write_string("{\"kind\":\"span_record\",\"trace_id\":")
  append_json_string(builder, record.span.trace_id.to_hex())
  builder.write_string(",\"span_id\":")
  append_json_string(builder, record.span.span_id.to_hex())
  builder.write_string(",\"fields\":")
  append_fields(builder, record.fields[:])
  builder.write_char('}')
  builder.to_string()
}

///|
fn encode_event(record : @tracing.EventRecord) -> String {
  let builder = StringBuilder::new()
  builder.write_string("{\"kind\":\"event\",\"trace_id\":")
  append_json_string(builder, record.trace_id.to_hex())
  if record.span is Some(span) {
    builder.write_string(",\"span_id\":")
    append_json_string(builder, span.span_id.to_hex())
  }
  append_metadata_fields(builder, record.metadata)
  if record.message is Some(message) {
    builder.write_string(",\"message\":")
    append_json_string(builder, message)
  }
  builder.write_string(",\"fields\":")
  append_fields(builder, record.fields[:])
  builder.write_char('}')
  builder.to_string()
}

///|
fn encode_span_end(record : @tracing.SpanEnd) -> String {
  let builder = StringBuilder::new()
  builder.write_string("{\"kind\":\"span_end\",\"trace_id\":")
  append_json_string(builder, record.span.trace_id.to_hex())
  builder.write_string(",\"span_id\":")
  append_json_string(builder, record.span.span_id.to_hex())
  builder.write_string(",\"status\":")
  append_status(builder, record.status)
  if record.error is Some(text) {
    builder.write_string(",\"error\":")
    append_json_string(builder, text)
  }
  builder.write_char('}')
  builder.to_string()
}

///|
fn encode_span_link(record : @tracing.SpanLink) -> String {
  let builder = StringBuilder::new()
  builder.write_string("{\"kind\":\"span_link\",\"trace_id\":")
  append_json_string(builder, record.span.trace_id.to_hex())
  builder.write_string(",\"span_id\":")
  append_json_string(builder, record.span.span_id.to_hex())
  builder.write_string(",\"follows_from_trace_id\":")
  append_json_string(builder, record.follows_from.trace_id.to_hex())
  builder.write_string(",\"follows_from_span_id\":")
  append_json_string(builder, record.follows_from.span_id.to_hex())
  builder.write_char('}')
  builder.to_string()
}

///|
fn JsonSubscriber::notify(self : JsonSubscriber) -> Unit {
  ignore(self.wake_queue.try_put(())) catch {
    _ => ()
  }
}

///|
fn JsonSubscriber::enqueue(self : JsonSubscriber, line : String) -> Unit {
  if !self.accepting.val {
    self.dropped_records.val += 1
    return
  }
  let accepted = self.record_queue.try_put(line) catch { _ => false }
  if accepted {
    self.notify()
  } else {
    self.dropped_records.val += 1
  }
}

///|
impl @tracing.Subscriber for JsonSubscriber with on_span_start(self, record) {
  self.open_spans.val.add(record.span)
  self.enqueue(encode_span_start(record))
}

///|
impl @tracing.Subscriber for JsonSubscriber with on_span_record(self, record) {
  self.enqueue(encode_span_record(record))
}

///|
impl @tracing.Subscriber for JsonSubscriber with on_event(self, record) {
  self.enqueue(encode_event(record))
}

///|
impl @tracing.Subscriber for JsonSubscriber with on_span_end(self, record) {
  self.open_spans.val.remove(record.span)
  self.enqueue(encode_span_end(record))
}

///|
impl @tracing.Subscriber for JsonSubscriber with on_span_link(self, record) {
  self.enqueue(encode_span_link(record))
}

///|
fn remember_writer_error(
  accepting : Ref[Bool],
  writer_errors : Ref[Int],
  writer_error_text : Ref[String?],
  err : Error,
) -> Unit {
  writer_errors.val += 1
  accepting.val = false
  if writer_error_text.val is None {
    writer_error_text.val = Some(err.to_string())
  }
}

///|
async fn drain_records(
  record_queue : @aqueue.Queue[String],
  buffered : @io.BufferedWriter[&@io.Writer],
  accepting : Ref[Bool],
  writer_errors : Ref[Int],
  writer_error_text : Ref[String?],
) -> Unit {
  for ;; {
    let item = record_queue.try_get() catch { _ => None }
    match item {
      Some(line) =>
        if writer_error_text.val is None {
          try {
            buffered.write(line)
            buffered.write("\n")
          } catch {
            err =>
              remember_writer_error(
                accepting, writer_errors, writer_error_text, err,
              )
          }
        }
      None => break
    }
  }
}

///|
async fn flush_buffered(
  buffered : @io.BufferedWriter[&@io.Writer],
  accepting : Ref[Bool],
  writer_errors : Ref[Int],
  writer_error_text : Ref[String?],
) -> String? {
  if writer_error_text.val is Some(text) {
    return Some(text)
  }
  buffered.flush() catch {
    err => {
      remember_writer_error(accepting, writer_errors, writer_error_text, err)
      return Some(err.to_string())
    }
  }
  writer_error_text.val
}

///|
async fn ack_result(
  ack_queue : @aqueue.Queue[RuntimeAck],
  wake_queue : @aqueue.Queue[Unit],
  id : Int64,
  error_text : String?,
) -> Unit {
  let ack = match error_text {
    Some(text) => Failed(id, text)
    None => Ok(id)
  }
  ack_queue.put(ack) catch {
    _ => ()
  }
  ignore(wake_queue.try_put(())) catch {
    _ => ()
  }
}

///|
async fn writer_loop(
  writer : &@io.Writer,
  options : JsonOptions,
  record_queue : @aqueue.Queue[String],
  control_queue : @aqueue.Queue[ControlCommand],
  ack_queue : @aqueue.Queue[RuntimeAck],
  wake_queue : @aqueue.Queue[Unit],
  accepting : Ref[Bool],
  writer_errors : Ref[Int],
  writer_error_text : Ref[String?],
  open_spans : Ref[Set[@tracing.SpanRef]],
  unclosed_spans : Ref[Int],
) -> Unit {
  let buffered = @io.BufferedWriter::new(
    writer,
    size=options.writer_buffer_size,
  )
  for ;; {
    wake_queue.get() catch {
      _ => break
    }
    let mut should_stop = false
    for ;; {
      let control = control_queue.try_get() catch { _ => None }
      match control {
        Some(Flush(id)) => {
          drain_records(
            record_queue, buffered, accepting, writer_errors, writer_error_text,
          )
          let error_text = flush_buffered(
            buffered, accepting, writer_errors, writer_error_text,
          )
          ack_result(ack_queue, wake_queue, id, error_text)
        }
        Some(Shutdown(id)) => {
          drain_records(
            record_queue, buffered, accepting, writer_errors, writer_error_text,
          )
          let error_text = flush_buffered(
            buffered, accepting, writer_errors, writer_error_text,
          )
          unclosed_spans.val = open_spans.val.length()
          ack_result(ack_queue, wake_queue, id, error_text)
          should_stop = true
          break
        }
        None => ()
      }
      if should_stop {
        break
      }
      let item = record_queue.try_get() catch { _ => None }
      match item {
        Some(line) =>
          if writer_error_text.val is None {
            try {
              buffered.write(line)
              buffered.write("\n")
            } catch {
              err =>
                remember_writer_error(
                  accepting, writer_errors, writer_error_text, err,
                )
            }
          }
        None => break
      }
    }
    if should_stop {
      break
    }
  }
}

///|
fn shutdown_timeout_message(timeout_ms : Int) -> String {
  "shutdown timed out after \{timeout_ms.to_string()}ms"
}

///|
async fn protected_shutdown(runtime : JsonRuntime) -> Result[Unit, Error] {
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
fn runtime_error_of_error(err : Error) -> JsonRuntimeError? {
  match err {
    WriterFailed(text) => Some(WriterFailed(text))
    ChannelClosed(text) => Some(ChannelClosed(text))
    TimedOut(text) => Some(TimedOut(text))
    _ => None
  }
}

///|
/// Background JSON Lines runtime used by the formatter package.
pub struct JsonRuntime {
  priv dispatch : @tracing.Dispatch
  priv control_queue : @aqueue.Queue[ControlCommand]
  priv ack_queue : @aqueue.Queue[RuntimeAck]
  priv wake_queue : @aqueue.Queue[Unit]
  priv control_gate : @async.Semaphore
  priv next_command_id : Ref[Int64]
  priv dropped_records : Ref[Int]
  priv writer_errors : Ref[Int]
  priv unclosed_spans : Ref[Int]
  priv accepting : Ref[Bool]
  priv shutdown_state : Ref[ShutdownState]
  priv command_timeout_ms : Int
  priv shutdown_timeout_ms : Int
}

///|
pub impl Default for JsonOptions with default() {
  {
    record_queue_capacity: 8192,
    control_queue_capacity: 8,
    ack_queue_capacity: 8,
    writer_buffer_size: 16 * 1024,
    command_timeout_ms: 2000,
    shutdown_timeout_ms: 2000,
  }
}

///|
/// Create formatter options explicitly.
pub fn JsonOptions::new(
  record_queue_capacity? : Int = 8192,
  control_queue_capacity? : Int = 8,
  ack_queue_capacity? : Int = 8,
  writer_buffer_size? : Int = 16 * 1024,
  command_timeout_ms? : Int = 2000,
  shutdown_timeout_ms? : Int = 2000,
) -> JsonOptions {
  {
    record_queue_capacity,
    control_queue_capacity,
    ack_queue_capacity,
    writer_buffer_size,
    command_timeout_ms,
    shutdown_timeout_ms,
  }
}

///|
fn next_command_id(counter : Ref[Int64]) -> Int64 {
  counter.val += 1L
  counter.val
}

///|
async fn JsonRuntime::await_shutdown_ack(
  self : JsonRuntime,
  id : Int64,
) -> Unit {
  self.await_ack_bounded(id, "shutdown") catch {
    WriterFailed(text) => {
      let err = WriterFailed(text)
      self.shutdown_state.val = FailedState(err)
      raise err
    }
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
async fn[X] JsonRuntime::with_control_gate(
  self : JsonRuntime,
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
async fn JsonRuntime::await_ack(self : JsonRuntime, id : Int64) -> Unit {
  for ;; {
    let ack = self.ack_queue.get() catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => raise ChannelClosed("ack queue closed")
    }
    match ack {
      Ok(ack_id) if ack_id == id => return
      Failed(ack_id, text) if ack_id == id => raise WriterFailed(text)
      _ => ()
    }
  }
}

///|
async fn JsonRuntime::await_ack_bounded(
  self : JsonRuntime,
  id : Int64,
  command : String,
) -> Unit {
  let result : Unit? = @async.with_timeout_opt(self.command_timeout_ms, () => {
    self.await_ack(id)
  }) catch {
    WriterFailed(text) => raise WriterFailed(text)
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
/// Start a background JSON Lines runtime inside an existing task group.
pub fn[X] JsonRuntime::start_in(
  group : @async.TaskGroup[X],
  writer : &@io.Writer,
  options? : JsonOptions = JsonOptions::default(),
) -> JsonRuntime {
  guard options.record_queue_capacity > 0 else {
    abort("JsonOptions.record_queue_capacity must be positive")
  }
  guard options.control_queue_capacity > 0 else {
    abort("JsonOptions.control_queue_capacity must be positive")
  }
  guard options.ack_queue_capacity > 0 else {
    abort("JsonOptions.ack_queue_capacity must be positive")
  }
  guard options.writer_buffer_size > 0 else {
    abort("JsonOptions.writer_buffer_size must be positive")
  }
  guard options.command_timeout_ms > 0 else {
    abort("JsonOptions.command_timeout_ms must be positive")
  }
  guard options.shutdown_timeout_ms > 0 else {
    abort("JsonOptions.shutdown_timeout_ms must be positive")
  }
  let record_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.record_queue_capacity),
  )
  let control_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.control_queue_capacity),
  )
  let ack_queue = @aqueue.Queue::new(
    kind=@aqueue.Blocking(options.ack_queue_capacity),
  )
  let wake_queue = @aqueue.Queue::new(kind=@aqueue.DiscardLatest(1))
  let dropped_records = Ref::new(0)
  let writer_errors = Ref::new(0)
  let writer_error_text = Ref::new(None)
  let unclosed_spans = Ref::new(0)
  let accepting = Ref::new(true)
  let open_spans = Ref::new(@set.new())
  let subscriber = {
    record_queue,
    wake_queue,
    accepting,
    dropped_records,
    open_spans,
  }
  let dispatch = @tracing.Dispatch::from_subscriber(subscriber)
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    writer_loop(
      writer, options, record_queue, control_queue, ack_queue, wake_queue, accepting,
      writer_errors, writer_error_text, open_spans, unclosed_spans,
    )
  })
  {
    dispatch,
    control_queue,
    ack_queue,
    wake_queue,
    control_gate: @async.Semaphore::new(1),
    next_command_id: Ref::new(0L),
    dropped_records,
    writer_errors,
    unclosed_spans,
    accepting,
    shutdown_state: Ref::new(Running),
    command_timeout_ms: options.command_timeout_ms,
    shutdown_timeout_ms: options.shutdown_timeout_ms,
  }
}

///|
/// Return the dispatch that forwards tracing records into this runtime.
pub fn JsonRuntime::dispatch(self : JsonRuntime) -> @tracing.Dispatch {
  self.dispatch
}

///|
/// Snapshot formatter runtime counters.
pub fn JsonRuntime::stats(self : JsonRuntime) -> JsonStats {
  {
    dropped_records: self.dropped_records.val,
    writer_errors: self.writer_errors.val,
    unclosed_spans: self.unclosed_spans.val,
  }
}

///|
/// Ask the background writer to flush all records accepted so far.
pub async fn JsonRuntime::flush(self : JsonRuntime) -> Unit {
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
/// Ask the background writer to drain, terminate, and stop accepting new
/// records.
///
/// The method is idempotent.
pub async fn JsonRuntime::shutdown(self : JsonRuntime) -> Unit {
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
/// Run `f` with a fresh root trace context that writes JSON Lines to `writer`.
pub async fn[X] with_json_writer(
  writer : &@io.Writer,
  options? : JsonOptions = JsonOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer, options~)
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
