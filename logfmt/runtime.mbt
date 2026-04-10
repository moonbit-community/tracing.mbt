///|
/// Configuration for the logfmt formatter runtime.
pub struct LogfmtOptions {
  /// Capacity of the bounded record queue used by the hot path.
  record_queue_capacity : Int
  /// Capacity of the dedicated control queue used by `flush` and `shutdown`.
  control_queue_capacity : Int
  /// Capacity of the acknowledgement queue paired with the control queue.
  ack_queue_capacity : Int
  /// Buffer size used by the background `BufferedWriter`.
  writer_buffer_size : Int
  /// Timeout used by `LogfmtRuntime::flush` and `LogfmtRuntime::shutdown` while
  /// waiting for a writer acknowledgement.
  command_timeout_ms : Int
  /// Timeout used by `with_logfmt_*` helpers when they attempt protected
  /// shutdown during scope exit.
  shutdown_timeout_ms : Int
}

///|
/// Snapshot of runtime health counters.
pub struct LogfmtStats {
  dropped_records : Int
  writer_errors : Int
  unclosed_spans : Int
} derive(Debug)

///|
/// Errors raised by `LogfmtRuntime::flush` and `LogfmtRuntime::shutdown`.
pub suberror LogfmtRuntimeError {
  WriterFailed(String)
  ChannelClosed(String)
  TimedOut(String)
} derive(Debug)

///|
/// Errors raised by `with_logfmt_*` helpers when both user code and shutdown
/// fail.
pub suberror LogfmtHelperError {
  UserAndShutdownFailed(Error, LogfmtRuntimeError)
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
  FailedState(LogfmtRuntimeError)
}

///|
priv struct LogfmtSubscriber {
  record_queue : @aqueue.Queue[String]
  wake_queue : @aqueue.Queue[Unit]
  accepting : Ref[Bool]
  dropped_records : Ref[Int]
  open_spans : Ref[Set[@tracing.SpanRef]]
}

///|
fn append_hex4(builder : StringBuilder, value : Int) -> Unit {
  let digits = "0123456789abcdef"
  builder.write_char(digits[(value >> 12) & 0xF].to_int().unsafe_to_char())
  builder.write_char(digits[(value >> 8) & 0xF].to_int().unsafe_to_char())
  builder.write_char(digits[(value >> 4) & 0xF].to_int().unsafe_to_char())
  builder.write_char(digits[value & 0xF].to_int().unsafe_to_char())
}

///|
fn append_hex(builder : StringBuilder, value : Int) -> Unit {
  let digits = "0123456789abcdef"
  let mut wrote = false
  for shift in [20, 16, 12, 8, 4, 0] {
    let digit = (value >> shift) & 0xF
    if wrote || digit != 0 || shift == 0 {
      builder.write_char(digits[digit].to_int().unsafe_to_char())
      wrote = true
    }
  }
}

///|
fn append_logfmt_string(builder : StringBuilder, value : String) -> Unit {
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
        builder.write_string("\\u")
        append_hex4(builder, ch.to_int())
      }
      ch => builder.write_char(ch)
    }
  }
  builder.write_char('"')
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
fn status_name(status : @tracing.SpanStatus) -> String {
  match status {
    @tracing.Ok => "ok"
    @tracing.Error => "error"
    @tracing.Cancelled => "cancelled"
  }
}

///|
fn append_pair_prefix(builder : StringBuilder, wrote_before : Bool) -> Unit {
  if wrote_before {
    builder.write_char(' ')
  }
}

///|
fn append_text_pair(
  builder : StringBuilder,
  key : String,
  value : String,
  wrote_before : Bool,
) -> Bool {
  append_pair_prefix(builder, wrote_before)
  builder.write_string(key)
  builder.write_char('=')
  append_logfmt_string(builder, value)
  true
}

///|
fn is_field_name_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  ch == '.' ||
  ch == '-'
}

///|
fn append_field_name(builder : StringBuilder, name : String) -> Unit {
  if name == "" {
    builder.write_string("_empty")
    return
  }
  for ch in name {
    if is_field_name_char(ch) {
      builder.write_char(ch)
    } else if ch == '_' {
      builder.write_string("__")
    } else {
      builder.write_string("_u")
      append_hex(builder, ch.to_int())
      builder.write_char('_')
    }
  }
}

///|
fn append_value(builder : StringBuilder, value : @tracing.Value) -> Unit {
  match value {
    @tracing.Null => builder.write_string("null")
    @tracing.Bool(value) =>
      builder.write_string(if value { "true" } else { "false" })
    @tracing.Int(value) => builder.write_object(value)
    @tracing.Int64(value) => builder.write_string(value.to_string())
    @tracing.UInt(value) => builder.write_object(value)
    @tracing.UInt64(value) => builder.write_string(value.to_string())
    @tracing.Double(value) => builder.write_object(value)
    @tracing.String(value) => append_logfmt_string(builder, value)
    @tracing.Bytes(value) =>
      append_logfmt_string(builder, @base64.encode(value[:]))
    @tracing.Array(values) =>
      append_logfmt_string(builder, @tracing.Array(values).to_json_string())
    @tracing.Object(entries) =>
      append_logfmt_string(builder, @tracing.Object(entries).to_json_string())
  }
}

///|
fn append_fields(
  builder : StringBuilder,
  fields : ArrayView[@tracing.Field],
  wrote_before : Bool,
) -> Bool {
  let mut wrote = wrote_before
  for field in fields {
    append_pair_prefix(builder, wrote)
    builder.write_string("field.")
    append_field_name(builder, field.name)
    builder.write_char('=')
    append_value(builder, field.value)
    wrote = true
  }
  wrote
}

///|
fn append_metadata_fields(
  builder : StringBuilder,
  metadata : @tracing.Metadata,
  wrote_before : Bool,
) -> Bool {
  let mut wrote = wrote_before
  wrote = append_text_pair(builder, "level", level_name(metadata.level), wrote)
  wrote = append_text_pair(builder, "name", metadata.name, wrote)
  wrote = append_text_pair(builder, "target", metadata.target, wrote)
  append_text_pair(builder, "loc", metadata.loc.to_string(), wrote)
}

///|
fn encode_span_start(record : @tracing.SpanStart) -> String {
  let builder = StringBuilder::new()
  let mut wrote = false
  wrote = append_text_pair(builder, "kind", "span_start", wrote)
  wrote = append_text_pair(
    builder,
    "trace_id",
    record.span.trace_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "span_id",
    record.span.span_id.to_hex(),
    wrote,
  )
  if record.parent is Some(parent) {
    wrote = append_text_pair(
      builder,
      "parent_span_id",
      parent.span_id.to_hex(),
      wrote,
    )
  }
  wrote = append_metadata_fields(builder, record.metadata, wrote)
  ignore(append_fields(builder, record.fields[:], wrote))
  builder.to_string()
}

///|
fn encode_span_record(record : @tracing.SpanRecord) -> String {
  let builder = StringBuilder::new()
  let mut wrote = false
  wrote = append_text_pair(builder, "kind", "span_record", wrote)
  wrote = append_text_pair(
    builder,
    "trace_id",
    record.span.trace_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "span_id",
    record.span.span_id.to_hex(),
    wrote,
  )
  ignore(append_fields(builder, record.fields[:], wrote))
  builder.to_string()
}

///|
fn encode_event(record : @tracing.EventRecord) -> String {
  let builder = StringBuilder::new()
  let mut wrote = false
  wrote = append_text_pair(builder, "kind", "event", wrote)
  wrote = append_text_pair(builder, "trace_id", record.trace_id.to_hex(), wrote)
  if record.span is Some(span) {
    wrote = append_text_pair(builder, "span_id", span.span_id.to_hex(), wrote)
  }
  wrote = append_metadata_fields(builder, record.metadata, wrote)
  if record.message is Some(message) {
    wrote = append_text_pair(builder, "message", message, wrote)
  }
  ignore(append_fields(builder, record.fields[:], wrote))
  builder.to_string()
}

///|
fn encode_span_end(record : @tracing.SpanEnd) -> String {
  let builder = StringBuilder::new()
  let mut wrote = false
  wrote = append_text_pair(builder, "kind", "span_end", wrote)
  wrote = append_text_pair(
    builder,
    "trace_id",
    record.span.trace_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "span_id",
    record.span.span_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(builder, "status", status_name(record.status), wrote)
  if record.error is Some(text) {
    wrote = append_text_pair(builder, "error", text, wrote)
  }
  ignore(wrote)
  builder.to_string()
}

///|
fn encode_span_link(record : @tracing.SpanLink) -> String {
  let builder = StringBuilder::new()
  let mut wrote = false
  wrote = append_text_pair(builder, "kind", "span_link", wrote)
  wrote = append_text_pair(
    builder,
    "trace_id",
    record.span.trace_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "span_id",
    record.span.span_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "follows_from_trace_id",
    record.follows_from.trace_id.to_hex(),
    wrote,
  )
  wrote = append_text_pair(
    builder,
    "follows_from_span_id",
    record.follows_from.span_id.to_hex(),
    wrote,
  )
  ignore(wrote)
  builder.to_string()
}

///|
fn LogfmtSubscriber::notify(self : LogfmtSubscriber) -> Unit {
  ignore(self.wake_queue.try_put(())) catch {
    _ => ()
  }
}

///|
fn LogfmtSubscriber::enqueue(self : LogfmtSubscriber, line : String) -> Unit {
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
impl @tracing.Subscriber for LogfmtSubscriber with on_span_start(self, record) {
  self.open_spans.val.add(record.span)
  self.enqueue(encode_span_start(record))
}

///|
impl @tracing.Subscriber for LogfmtSubscriber with on_span_record(self, record) {
  self.enqueue(encode_span_record(record))
}

///|
impl @tracing.Subscriber for LogfmtSubscriber with on_event(self, record) {
  self.enqueue(encode_event(record))
}

///|
impl @tracing.Subscriber for LogfmtSubscriber with on_span_end(self, record) {
  self.open_spans.val.remove(record.span)
  self.enqueue(encode_span_end(record))
}

///|
impl @tracing.Subscriber for LogfmtSubscriber with on_span_link(self, record) {
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
  options : LogfmtOptions,
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
async fn protected_shutdown(runtime : LogfmtRuntime) -> Result[Unit, Error] {
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
fn runtime_error_of_error(err : Error) -> LogfmtRuntimeError? {
  match err {
    WriterFailed(text) => Some(WriterFailed(text))
    ChannelClosed(text) => Some(ChannelClosed(text))
    TimedOut(text) => Some(TimedOut(text))
    _ => None
  }
}

///|
/// Background logfmt runtime used by the formatter package.
pub struct LogfmtRuntime {
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
pub impl Default for LogfmtOptions with default() {
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
pub fn LogfmtOptions::new(
  record_queue_capacity? : Int = 8192,
  control_queue_capacity? : Int = 8,
  ack_queue_capacity? : Int = 8,
  writer_buffer_size? : Int = 16 * 1024,
  command_timeout_ms? : Int = 2000,
  shutdown_timeout_ms? : Int = 2000,
) -> LogfmtOptions {
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
async fn LogfmtRuntime::await_shutdown_ack(
  self : LogfmtRuntime,
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
async fn[X] LogfmtRuntime::with_control_gate(
  self : LogfmtRuntime,
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
async fn LogfmtRuntime::await_ack(self : LogfmtRuntime, id : Int64) -> Unit {
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
async fn LogfmtRuntime::await_ack_bounded(
  self : LogfmtRuntime,
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
/// Start a background logfmt runtime inside an existing task group.
pub fn[X] LogfmtRuntime::start_in(
  group : @async.TaskGroup[X],
  writer : &@io.Writer,
  options? : LogfmtOptions = LogfmtOptions::default(),
) -> LogfmtRuntime {
  guard options.record_queue_capacity > 0 else {
    abort("LogfmtOptions.record_queue_capacity must be positive")
  }
  guard options.control_queue_capacity > 0 else {
    abort("LogfmtOptions.control_queue_capacity must be positive")
  }
  guard options.ack_queue_capacity > 0 else {
    abort("LogfmtOptions.ack_queue_capacity must be positive")
  }
  guard options.writer_buffer_size > 0 else {
    abort("LogfmtOptions.writer_buffer_size must be positive")
  }
  guard options.command_timeout_ms > 0 else {
    abort("LogfmtOptions.command_timeout_ms must be positive")
  }
  guard options.shutdown_timeout_ms > 0 else {
    abort("LogfmtOptions.shutdown_timeout_ms must be positive")
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
pub fn LogfmtRuntime::dispatch(self : LogfmtRuntime) -> @tracing.Dispatch {
  self.dispatch
}

///|
/// Snapshot formatter runtime counters.
pub fn LogfmtRuntime::stats(self : LogfmtRuntime) -> LogfmtStats {
  {
    dropped_records: self.dropped_records.val,
    writer_errors: self.writer_errors.val,
    unclosed_spans: self.unclosed_spans.val,
  }
}

///|
/// Ask the background writer to flush all records accepted so far.
pub async fn LogfmtRuntime::flush(self : LogfmtRuntime) -> Unit {
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
pub async fn LogfmtRuntime::shutdown(self : LogfmtRuntime) -> Unit {
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
/// Run `f` with a fresh root trace context that writes logfmt to `writer`.
pub async fn[X] with_logfmt_writer(
  writer : &@io.Writer,
  options? : LogfmtOptions = LogfmtOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer, options~)
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
