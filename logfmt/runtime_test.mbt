///|
suberror SinkFailed derive(Debug)

///|
suberror UserFailed derive(Debug)

///|
struct Capture {
  starts : Ref[Array[@tracing.SpanStart]]
}

///|
fn Capture::new() -> Capture {
  { starts: Ref::new([]) }
}

///|
fn fake_source_loc(repr : String) -> SourceLoc = "%identity"

///|
impl @tracing.Subscriber for Capture with on_span_start(self, record) {
  self.starts.val.push(record)
}

///|
impl @tracing.Subscriber for Capture with on_event(_self, _record) {

}

///|
impl @tracing.Subscriber for Capture with on_span_end(_self, _record) {

}

///|
struct MemoryWriter {
  output : Ref[StringBuilder]
  delay_ms : Int
  fail_after : Int?
  writes : Ref[Int]
}

///|
fn MemoryWriter::new(delay_ms? : Int = 0, fail_after? : Int) -> MemoryWriter {
  {
    output: Ref::new(StringBuilder::new()),
    delay_ms,
    fail_after,
    writes: Ref::new(0),
  }
}

///|
fn MemoryWriter::contents(self : MemoryWriter) -> String {
  self.output.val.to_string()
}

///|
fn MemoryWriter::lines(self : MemoryWriter) -> Array[String] {
  let lines : Array[String] = []
  for line in self.contents().split("\n") {
    let line = line.to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}

///|
fn MemoryWriter::entries(self : MemoryWriter) -> Array[Array[(String, String)]] {
  let entries : Array[Array[(String, String)]] = []
  for line in self.lines() {
    entries.push(parse_logfmt_line(line))
  }
  entries
}

///|
fn root_ctx(dispatch : @tracing.Dispatch) -> @tracing.TraceContext {
  @tracing.TraceContext::root(dispatch, @tracing.TraceIdAllocator::new())
}

///|
fn seeded_ctx(dispatch : @tracing.Dispatch) -> @tracing.TraceContext {
  @tracing.TraceContext::root(
    dispatch,
    @tracing.TraceIdAllocator::new_seeded(0UL),
  )
}

///|
fn decode_hex_digit(ch : Char) -> Int? {
  let code = ch.to_int()
  if code >= '0'.to_int() && code <= '9'.to_int() {
    Some(code - '0'.to_int())
  } else if code >= 'a'.to_int() && code <= 'f'.to_int() {
    Some(code - 'a'.to_int() + 10)
  } else if code >= 'A'.to_int() && code <= 'F'.to_int() {
    Some(code - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn parse_logfmt_line(line : String) -> Array[(String, String)] {
  let chars = line.to_array()
  let entries : Array[(String, String)] = []
  let mut index = 0
  while index < chars.length() {
    while index < chars.length() && chars[index] == ' ' {
      index += 1
    }
    if index >= chars.length() {
      break
    }

    let key_builder = StringBuilder::new()
    while index < chars.length() && chars[index] != '=' {
      key_builder.write_char(chars[index])
      index += 1
    }
    guard index < chars.length() else {
      abort("invalid logfmt line: missing '=' in \{line}")
    }
    let key = key_builder.to_string()
    index += 1

    let value_builder = StringBuilder::new()
    if index < chars.length() && chars[index] == '"' {
      index += 1
      let mut closed = false
      while index < chars.length() {
        match chars[index] {
          '"' => {
            index += 1
            closed = true
            break
          }
          '\\' => {
            index += 1
            guard index < chars.length() else {
              abort("invalid logfmt line: dangling escape in \{line}")
            }
            match chars[index] {
              '"' => value_builder.write_char('"')
              '\\' => value_builder.write_char('\\')
              'n' => value_builder.write_char('\n')
              'r' => value_builder.write_char('\r')
              't' => value_builder.write_char('\t')
              'b' => value_builder.write_char('\u0008')
              'f' => value_builder.write_char('\u000c')
              'u' => {
                guard index + 4 < chars.length() else {
                  abort("invalid logfmt line: short unicode escape in \{line}")
                }
                let mut value = 0
                for offset in 1..<=4 {
                  guard decode_hex_digit(chars[index + offset]) is Some(digit) else {
                    abort("invalid logfmt line: bad unicode escape in \{line}")
                  }
                  value = value * 16 + digit
                }
                value_builder.write_char(value.unsafe_to_char())
                index += 4
              }
              _ => abort("invalid logfmt line: unsupported escape in \{line}")
            }
            index += 1
          }
          ch => {
            value_builder.write_char(ch)
            index += 1
          }
        }
      }
      guard closed else {
        abort("invalid logfmt line: unterminated quoted value in \{line}")
      }
    } else {
      while index < chars.length() && chars[index] != ' ' {
        value_builder.write_char(chars[index])
        index += 1
      }
    }
    entries.push((key, value_builder.to_string()))
  }
  entries
}

///|
fn value_for(entries : Array[(String, String)], key : String) -> String? {
  for entry in entries {
    let (name, value) = entry
    if name == key {
      return Some(value)
    }
  }
  None
}

///|
fn values_for(entries : Array[(String, String)], key : String) -> Array[String] {
  let values : Array[String] = []
  for entry in entries {
    let (name, value) = entry
    if name == key {
      values.push(value)
    }
  }
  values
}

///|
fn keys(entries : Array[(String, String)]) -> Array[String] {
  let keys : Array[String] = []
  for entry in entries {
    let (key, _) = entry
    keys.push(key)
  }
  keys
}

///|
impl @io.Writer for MemoryWriter with write_once(self, buf, offset~, len~) {
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  self.writes.val += 1
  if self.fail_after is Some(limit) && self.writes.val > limit {
    raise SinkFailed
  }
  self.output.val.write_string(@utf8.decode(buf[offset:offset + len]))
  len
}

///|
async test "spawn_child_span preserves caller callsite across packages" {
  let capture = Capture::new()
  let ctx = root_ctx(@tracing.Dispatch::from_subscriber(capture))
  ctx.with_span(@tracing.Info, "parent", parent_ctx => {
    @async.with_task_group(group => {
      let child_task : @async.Task[@tracing.SpanRef] = @tracing.spawn_child_span(
        group,
        parent_ctx,
        @tracing.Info,
        "child",
        child_ctx => child_ctx.current_span().unwrap(),
      )
      let follower_task : @async.Task[@tracing.SpanRef] = @tracing.spawn_follower_span(
        group,
        parent_ctx,
        @tracing.Info,
        "follower",
        follower_ctx => follower_ctx.current_span().unwrap(),
      )
      ignore(child_task.wait())
      ignore(follower_task.wait())
    })
  })
  assert_eq(3, capture.starts.val.length())
  let child_start = if capture.starts.val[0].metadata.name == "child" {
    capture.starts.val[0]
  } else if capture.starts.val[1].metadata.name == "child" {
    capture.starts.val[1]
  } else {
    capture.starts.val[2]
  }
  let follower_start = if capture.starts.val[0].metadata.name == "follower" {
    capture.starts.val[0]
  } else if capture.starts.val[1].metadata.name == "follower" {
    capture.starts.val[1]
  } else {
    capture.starts.val[2]
  }
  assert_eq(follower_start.metadata.target, child_start.metadata.target)
  let child_loc = child_start.metadata.loc.to_string()
  let follower_loc = follower_start.metadata.loc.to_string()
  assert_true(child_loc.contains("runtime_test.mbt"))
  assert_true(follower_loc.contains("runtime_test.mbt"))
  assert_true(!child_loc.contains("trace_context.mbt"))
}

///|
async test "LogfmtRuntime encodes event and span lifecycle records" {
  let writer = MemoryWriter::new()
  let entries = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = seeded_ctx(runtime.dispatch())
    ctx.event(
      @tracing.Info,
      "ready",
      message?=Some("booting"),
      target="app",
      fields=[@tracing.field("worker", 1)],
      loc=fake_source_loc("event-ready"),
    )
    let (handle, child_ctx) = ctx.span(
      @tracing.Info,
      "request",
      target="http",
      fields=[@tracing.field("request_id", "req-1")],
      loc=fake_source_loc("span-request"),
    )
    child_ctx.event(
      @tracing.Warn,
      "slow",
      message?=Some("retrying"),
      target="http",
      fields=[@tracing.field("cached", false)],
      loc=fake_source_loc("event-slow"),
    )
    ignore(handle.record([@tracing.field("rows", 3)]))
    ignore(handle.close(status=@tracing.Error, error="timeout"))
    runtime.shutdown()
    writer.entries()
  })

  assert_eq(5, entries.length())

  let ready = entries[0]
  assert_eq(keys(ready), [
    "kind", "trace_id", "level", "name", "target", "loc", "message", "field.worker",
  ])
  assert_eq(value_for(ready, "kind"), Some("event"))
  assert_eq(
    value_for(ready, "trace_id"),
    Some("00000000000000000000000000000001"),
  )
  assert_eq(value_for(ready, "level"), Some("info"))
  assert_eq(value_for(ready, "name"), Some("ready"))
  assert_eq(value_for(ready, "target"), Some("app"))
  assert_true(value_for(ready, "loc").unwrap().contains("event-ready"))
  assert_eq(value_for(ready, "message"), Some("booting"))
  assert_eq(value_for(ready, "field.worker"), Some("1"))

  let started = entries[1]
  let span_id = value_for(started, "span_id").unwrap()
  assert_eq(value_for(started, "kind"), Some("span_start"))
  assert_eq(
    value_for(started, "trace_id"),
    Some("00000000000000000000000000000001"),
  )
  assert_eq(value_for(started, "level"), Some("info"))
  assert_eq(value_for(started, "name"), Some("request"))
  assert_eq(value_for(started, "target"), Some("http"))
  assert_true(value_for(started, "loc").unwrap().contains("span-request"))
  assert_eq(value_for(started, "field.request__id"), Some("req-1"))

  let slow = entries[2]
  assert_eq(value_for(slow, "kind"), Some("event"))
  assert_eq(
    value_for(slow, "trace_id"),
    Some("00000000000000000000000000000001"),
  )
  assert_eq(value_for(slow, "span_id"), Some(span_id))
  assert_eq(value_for(slow, "level"), Some("warn"))
  assert_eq(value_for(slow, "name"), Some("slow"))
  assert_eq(value_for(slow, "message"), Some("retrying"))
  assert_eq(value_for(slow, "field.cached"), Some("false"))

  let recorded = entries[3]
  assert_eq(value_for(recorded, "kind"), Some("span_record"))
  assert_eq(value_for(recorded, "span_id"), Some(span_id))
  assert_eq(value_for(recorded, "field.rows"), Some("3"))

  let ended = entries[4]
  assert_eq(value_for(ended, "kind"), Some("span_end"))
  assert_eq(value_for(ended, "span_id"), Some(span_id))
  assert_eq(value_for(ended, "status"), Some("error"))
  assert_eq(value_for(ended, "error"), Some("timeout"))
}

///|
async test "LogfmtRuntime quotes strings and preserves duplicate fields" {
  let writer = MemoryWriter::new()
  let entries = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = seeded_ctx(runtime.dispatch())
    ctx.event(
      @tracing.Info,
      "complex",
      message?=Some("line\n\"quoted\""),
      target="tests",
      fields=[
        @tracing.field("user id/x", "req 1"),
        @tracing.field("bytes", b"hi"),
        @tracing.field(
          "items",
          @tracing.Array([
            @tracing.Int(1),
            @tracing.String("two"),
            @tracing.Null,
          ]),
        ),
        @tracing.field(
          "payload",
          @tracing.Object([("ok", @tracing.Bool(true))]),
        ),
        @tracing.field("nothing", @tracing.Null),
        @tracing.field("dup", 1),
        @tracing.field("dup", 2),
      ],
      loc=fake_source_loc("event-complex"),
    )
    runtime.shutdown()
    writer.entries()
  })

  assert_eq(1, entries.length())
  let line = entries[0]
  assert_eq(keys(line), [
    "kind", "trace_id", "level", "name", "target", "loc", "message", "field.user_u20_id_u2f_x",
    "field.bytes", "field.items", "field.payload", "field.nothing", "field.dup",
    "field.dup",
  ])
  assert_eq(value_for(line, "message"), Some("line\n\"quoted\""))
  assert_eq(value_for(line, "field.user_u20_id_u2f_x"), Some("req 1"))
  assert_eq(value_for(line, "field.bytes"), Some("aGk="))
  assert_eq(value_for(line, "field.items"), Some("[1,\"two\",null]"))
  assert_eq(value_for(line, "field.payload"), Some("{\"ok\":true}"))
  assert_eq(value_for(line, "field.nothing"), Some("null"))
  assert_eq(values_for(line, "field.dup"), ["1", "2"])
}

///|
async test "LogfmtRuntime escapes field names without collisions" {
  let writer = MemoryWriter::new()
  let entries = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = seeded_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "escaped-fields", fields=[
      @tracing.field("user id", 1),
      @tracing.field("user/id", 2),
      @tracing.field("user_id", 3),
      @tracing.field("", 4),
      @tracing.field("中", 5),
    ])
    runtime.shutdown()
    writer.entries()
  })

  assert_eq(1, entries.length())
  let line = entries[0]
  assert_eq(value_for(line, "field.user_u20_id"), Some("1"))
  assert_eq(value_for(line, "field.user_u2f_id"), Some("2"))
  assert_eq(value_for(line, "field.user__id"), Some("3"))
  assert_eq(value_for(line, "field._empty"), Some("4"))
  assert_eq(value_for(line, "field._u4e2d_"), Some("5"))
}

///|
async test "with_logfmt_writer surfaces writer failures on the success path" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[Unit, _] = try? with_logfmt_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-shutdown-failure")
  })
  assert_true(result is Err(@logfmt.WriterFailed(_)))
}

///|
async test "with_logfmt_writer preserves error span ends precisely" {
  let writer = MemoryWriter::new()
  let result : Result[Unit, _] = try? with_logfmt_writer(writer, ctx => {
    ctx.with_span(@tracing.Info, "error-span", _ctx => raise UserFailed)
  })
  assert_true(result is Err(UserFailed))

  let entries = writer.entries()
  assert_eq(2, entries.length())
  let started = entries[0]
  let ended = entries[1]
  let span_id = value_for(started, "span_id").unwrap()
  assert_eq(value_for(started, "kind"), Some("span_start"))
  assert_eq(value_for(started, "name"), Some("error-span"))
  assert_eq(value_for(ended, "kind"), Some("span_end"))
  assert_eq(value_for(ended, "span_id"), Some(span_id))
  assert_eq(value_for(ended, "status"), Some("error"))
  assert_true(value_for(ended, "error").unwrap().contains("UserFailed"))
}

///|
async test "with_logfmt_writer preserves cancelled span ends precisely" {
  let writer = MemoryWriter::new()
  with_logfmt_writer(writer, ctx => {
    ignore(
      @async.with_timeout_opt(10, () => {
        ctx.with_span(@tracing.Info, "cancelled-span", _ctx => @async.sleep(100))
      }),
    )
  })

  let entries = writer.entries()
  assert_eq(2, entries.length())
  let started = entries[0]
  let ended = entries[1]
  assert_eq(value_for(started, "kind"), Some("span_start"))
  assert_eq(value_for(started, "name"), Some("cancelled-span"))
  assert_eq(value_for(ended, "kind"), Some("span_end"))
  assert_eq(value_for(ended, "span_id"), value_for(started, "span_id"))
  assert_eq(value_for(ended, "status"), Some("cancelled"))
}

///|
async test "with_logfmt_writer encodes follows-from links precisely" {
  let writer = MemoryWriter::new()
  with_logfmt_writer(writer, ctx => {
    ctx.with_span(@tracing.Info, "parent", parent_ctx => {
      @async.with_task_group(group => {
        let task : @async.Task[Unit] = @tracing.spawn_follower_span(
          group,
          parent_ctx,
          @tracing.Info,
          "follower",
          _follower_ctx => (),
        )
        task.wait()
      })
    })
  })

  let entries = writer.entries()
  assert_eq(5, entries.length())
  let parent_started = entries[0]
  let follower_started = entries[1]
  let linked = entries[2]
  let follower_ended = entries[3]
  let parent_ended = entries[4]
  let parent_span_id = value_for(parent_started, "span_id").unwrap()
  let follower_span_id = value_for(follower_started, "span_id").unwrap()
  assert_eq(value_for(parent_started, "name"), Some("parent"))
  assert_eq(value_for(follower_started, "name"), Some("follower"))
  assert_eq(value_for(linked, "kind"), Some("span_link"))
  assert_eq(value_for(linked, "span_id"), Some(follower_span_id))
  assert_eq(value_for(linked, "follows_from_span_id"), Some(parent_span_id))
  assert_eq(value_for(follower_ended, "span_id"), Some(follower_span_id))
  assert_eq(value_for(parent_ended, "span_id"), Some(parent_span_id))
}

///|
async test "with_logfmt_writer flushes accepted records on exception path" {
  let writer = MemoryWriter::new()
  let result : Result[Unit, _] = try? with_logfmt_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-fail")
    raise UserFailed
  })
  assert_true(result is Err(UserFailed))

  let entries = writer.entries()
  assert_eq(1, entries.length())
  assert_eq(value_for(entries[0], "kind"), Some("event"))
  assert_eq(value_for(entries[0], "name"), Some("before-fail"))
}

///|
async test "with_logfmt_writer combines user and shutdown failures" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[Unit, _] = try? with_logfmt_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-double-fail")
    raise UserFailed
  })

  match result {
    Err(@logfmt.UserAndShutdownFailed(user_err, @logfmt.WriterFailed(text))) => {
      assert_true(user_err is UserFailed)
      assert_true(text.contains("SinkFailed"))
    }
    _ => fail("expected combined helper error")
  }
}

///|
async test "with_logfmt_writer handles enclosing cancellation without hanging" {
  let writer = MemoryWriter::new()
  let result : Unit? = @async.with_timeout_opt(10, () => {
    with_logfmt_writer(writer, ctx => {
      ctx.event(@tracing.Info, "before-cancel")
      @async.sleep(100)
    })
  })
  assert_eq(None, result)
}

///|
async test "with_logfmt_writer shutdown attempt stays within the configured timeout" {
  let writer = MemoryWriter::new(delay_ms=50)
  let result : Result[Unit?, _] = try? @async.with_timeout_opt(100, () => {
    with_logfmt_writer(
      writer,
      options=LogfmtOptions::new(command_timeout_ms=5, shutdown_timeout_ms=5),
      ctx => {
        ctx.event(@tracing.Info, "slow")
        raise UserFailed
      },
    )
  })
  assert_true(result is Err(@logfmt.UserAndShutdownFailed(UserFailed, _)))
}

///|
async test "LogfmtRuntime counts dropped records when queue is full" {
  let writer = MemoryWriter::new(delay_ms=50)
  let runtime = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(
      group,
      writer,
      options=LogfmtOptions::new(
        record_queue_capacity=1,
        control_queue_capacity=2,
        ack_queue_capacity=2,
        writer_buffer_size=32,
        command_timeout_ms=1000,
        shutdown_timeout_ms=1000,
      ),
    )
    let ctx = root_ctx(runtime.dispatch())
    for _ in 0..<32 {
      ctx.event(@tracing.Info, "burst")
    }
    runtime.shutdown()
    runtime
  })
  assert_true(runtime.stats().dropped_records > 0)
}

///|
async test "LogfmtRuntime flush still works when the record queue is saturated" {
  let writer = MemoryWriter::new(delay_ms=10)
  let runtime = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(
      group,
      writer,
      options=LogfmtOptions::new(
        record_queue_capacity=1,
        control_queue_capacity=1,
        ack_queue_capacity=1,
        writer_buffer_size=32,
        command_timeout_ms=200,
        shutdown_timeout_ms=200,
      ),
    )
    let ctx = root_ctx(runtime.dispatch())
    for _ in 0..<16 {
      ctx.event(@tracing.Info, "burst")
    }
    runtime.flush()
    runtime.shutdown()
    runtime
  })
  assert_true(runtime.stats().dropped_records > 0)
  let entries = writer.entries()
  assert_true(entries.length() > 0)
  for line in entries {
    assert_eq(value_for(line, "kind"), Some("event"))
    assert_eq(value_for(line, "name"), Some("burst"))
  }
}

///|
async test "LogfmtRuntime reports unclosed spans on shutdown" {
  let writer = MemoryWriter::new()
  let runtime = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = root_ctx(runtime.dispatch())
    ignore(ctx.span(@tracing.Info, "leaked"))
    runtime.shutdown()
    runtime
  })
  assert_eq(1, runtime.stats().unclosed_spans)
}

///|
async test "LogfmtRuntime reports writer failures through flush" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[LogfmtStats, _] = try? @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = root_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "first")
    ctx.event(@tracing.Info, "second")
    runtime.flush()
    runtime.shutdown()
    runtime.stats()
  })
  assert_true(result is Err(@logfmt.WriterFailed(_)))
}

///|
async test "LogfmtRuntime drops new records after a writer failure" {
  let writer = MemoryWriter::new(fail_after=0)
  let runtime = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer)
    let ctx = root_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "first")
    ignore(try? runtime.flush())
    ctx.event(@tracing.Info, "after-writer-failure")
    ignore(try? runtime.shutdown())
    runtime
  })
  assert_eq(1, runtime.stats().writer_errors)
  assert_eq(1, runtime.stats().dropped_records)
}

///|
async test "LogfmtRuntime concurrent flush calls do not steal acknowledgements" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = LogfmtOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (first_result, second_result, stats) = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer, options~)
    let ctx = root_ctx(runtime.dispatch())
    for _ in 0..<4 {
      ctx.event(@tracing.Info, "flush-race")
    }
    let first_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.flush()
    })
    let second_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.flush()
    })
    let first_result = first_task.wait()
    let second_result = second_task.wait()
    ignore(try? runtime.shutdown())
    (first_result, second_result, runtime.stats())
  })
  assert_true(first_result is Ok(_))
  assert_true(second_result is Ok(_))
  assert_eq(0, stats.writer_errors)
  assert_true(writer.lines().length() > 0)
}

///|
async test "LogfmtRuntime concurrent flush and shutdown do not steal acknowledgements" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = LogfmtOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (flush_result, shutdown_result, stats) = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer, options~)
    let ctx = root_ctx(runtime.dispatch())
    for _ in 0..<4 {
      ctx.event(@tracing.Info, "flush-shutdown-race")
    }
    let flush_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.flush()
    })
    let shutdown_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.shutdown()
    })
    let flush_result = flush_task.wait()
    let shutdown_result = shutdown_task.wait()
    (flush_result, shutdown_result, runtime.stats())
  })
  match flush_result {
    Ok(_) => ()
    Err(err) => raise err
  }
  match shutdown_result {
    Ok(_) => ()
    Err(err) => raise err
  }
  assert_eq(0, stats.writer_errors)
  assert_true(writer.lines().length() > 0)
}

///|
async test "LogfmtRuntime concurrent shutdown is idempotent" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = LogfmtOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (first_result, second_result, stats) = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(group, writer, options~)
    let ctx = root_ctx(runtime.dispatch())
    for _ in 0..<4 {
      ctx.event(@tracing.Info, "shutdown-race")
    }
    let first_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.shutdown()
    })
    let second_task : @async.Task[Result[Unit, _]] = group.spawn(() => {
      try? runtime.shutdown()
    })
    let first_result = first_task.wait()
    let second_result = second_task.wait()
    (first_result, second_result, runtime.stats())
  })
  assert_true(first_result is Ok(_))
  assert_true(second_result is Ok(_))
  assert_eq(0, stats.writer_errors)
  assert_true(writer.lines().length() > 0)
}

///|
async test "LogfmtRuntime flush is bounded by command timeout" {
  let writer = MemoryWriter::new(delay_ms=100)
  let result : Result[Result[Unit, _]?, _] = try? @async.with_timeout_opt(500, () => {
    @async.with_task_group(group => {
      let runtime = LogfmtRuntime::start_in(
        group,
        writer,
        options=LogfmtOptions::new(
          command_timeout_ms=10,
          shutdown_timeout_ms=200,
        ),
      )
      let ctx = root_ctx(runtime.dispatch())
      ctx.event(@tracing.Info, "slow-flush")
      let flush_result : Result[Unit, _] = try? runtime.flush()
      @async.sleep(120)
      ignore(try? runtime.shutdown())
      flush_result
    })
  })
  assert_true(result is Ok(Some(Err(@logfmt.TimedOut(_)))))
}

///|
async test "LogfmtRuntime shutdown is bounded by command timeout" {
  let writer = MemoryWriter::new(delay_ms=100)
  let result : Result[Result[Unit, _]?, _] = try? @async.with_timeout_opt(500, () => {
    @async.with_task_group(group => {
      let runtime = LogfmtRuntime::start_in(
        group,
        writer,
        options=LogfmtOptions::new(
          command_timeout_ms=10,
          shutdown_timeout_ms=200,
        ),
      )
      let ctx = root_ctx(runtime.dispatch())
      ctx.event(@tracing.Info, "slow-shutdown")
      try? runtime.shutdown()
    })
  })
  assert_true(result is Ok(Some(Err(@logfmt.TimedOut(_)))))
}

///|
async test "LogfmtRuntime shutdown can be retried after timing out" {
  let writer = MemoryWriter::new(delay_ms=100)
  let (first_result, second_result) = @async.with_task_group(group => {
    let runtime = LogfmtRuntime::start_in(
      group,
      writer,
      options=LogfmtOptions::new(command_timeout_ms=10, shutdown_timeout_ms=200),
    )
    let ctx = root_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "slow-shutdown-retry")
    let first_result : Result[Unit, _] = try? runtime.shutdown()
    @async.sleep(120)
    let second_result : Result[Unit, _] = try? runtime.shutdown()
    (first_result, second_result)
  })
  assert_true(first_result is Err(@logfmt.TimedOut(_)))
  assert_true(second_result is Ok(_))
}
