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
fn MemoryWriter::json_lines(
  self : MemoryWriter,
) -> Array[Json] raise @json.ParseError {
  let lines : Array[Json] = []
  for line in self.lines() {
    lines.push(@json.parse(line))
  }
  lines
}

///|
fn root_ctx(dispatch : @tracing.Dispatch) -> @tracing.TraceContext {
  @tracing.TraceContext::root(dispatch, @tracing.TraceIdAllocator::new())
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
async test "with_json_writer emits JSON lines" {
  let writer = MemoryWriter::new()
  with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "ready", message?=Some("booting"), fields=[
      @tracing.field("worker", 1),
    ])
    ctx.with_span(@tracing.Info, "parent", parent => {
      parent.event(@tracing.Warn, "warn", fields=[@tracing.field("ok", true)])
      parent.with_span(@tracing.Info, "child", child => {
        child.event(@tracing.Error, "boom", message?=Some("bad"))
      })
    })
  })
  let lines = writer.json_lines()
  assert_eq(7, lines.length())
  assert_true(
    lines[0]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "level": "info",
        "name": "ready",
        "target": String(_),
        "loc": String(_),
        "message": "booting",
        "fields": Object({ "worker": Number(1, ..), .. }),
        ..
      }
    ),
  )
  assert_true(
    lines[1]
    is Object(
      {
        "kind": "span_start",
        "trace_id": String(_),
        "span_id": String(_),
        "level": "info",
        "name": "parent",
        "target": String(_),
        "loc": String(_),
        "fields": Object(_),
        ..
      }
    ),
  )
  assert_true(
    lines[2]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "span_id": String(_),
        "level": "warn",
        "name": "warn",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ "ok": True, .. }),
        ..
      }
    ),
  )
  assert_true(
    lines[3]
    is Object(
      {
        "kind": "span_start",
        "trace_id": String(_),
        "span_id": String(_),
        "parent_span_id": String(_),
        "level": "info",
        "name": "child",
        "target": String(_),
        "loc": String(_),
        "fields": Object(_),
        ..
      }
    ),
  )
  assert_true(
    lines[4]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "span_id": String(_),
        "level": "error",
        "name": "boom",
        "target": String(_),
        "loc": String(_),
        "message": "bad",
        "fields": Object(_),
        ..
      }
    ),
  )
  assert_true(
    lines[5]
    is Object(
      {
        "kind": "span_end",
        "trace_id": String(_),
        "span_id": String(_),
        "status": "ok",
        ..
      }
    ),
  )
  assert_true(
    lines[6]
    is Object(
      {
        "kind": "span_end",
        "trace_id": String(_),
        "span_id": String(_),
        "status": "ok",
        ..
      }
    ),
  )
}

///|
async test "with_json_writer surfaces writer failures on the success path" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[Unit, _] = try? with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-shutdown-failure")
  })
  assert_true(result is Err(@jsonl.WriterFailed(_)))
}

///|
async test "with_json_writer encodes error span ends precisely" {
  let writer = MemoryWriter::new()
  let result : Result[Unit, _] = try? with_json_writer(writer, ctx => {
    ctx.with_span(@tracing.Info, "error-span", _ctx => raise UserFailed)
  })
  assert_true(result is Err(UserFailed))
  let lines = writer.json_lines()
  assert_eq(2, lines.length())
  let span_id = match lines[0] {
    Object(
      {
        "kind": "span_start",
        "span_id": String(span_id),
        "level": "info",
        "name": "error-span",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ .. }),
        ..
      }
    ) => span_id
    _ => abort("expected span_start for error-span")
  }
  match lines[1] {
    Object(
      {
        "kind": "span_end",
        "span_id": String(end_span_id),
        "status": "error",
        "error": String(error_text),
        ..
      }
    ) => {
      assert_eq(span_id, end_span_id)
      assert_true(error_text.contains("UserFailed"))
    }
    _ => abort("expected error span_end")
  }
}

///|
async test "with_json_writer encodes cancelled span ends precisely" {
  let writer = MemoryWriter::new()
  with_json_writer(writer, ctx => {
    ignore(
      @async.with_timeout_opt(10, () => {
        ctx.with_span(@tracing.Info, "cancelled-span", _ctx => @async.sleep(100))
      }),
    )
  })
  let lines = writer.json_lines()
  assert_eq(2, lines.length())
  let span_id = match lines[0] {
    Object(
      {
        "kind": "span_start",
        "span_id": String(span_id),
        "level": "info",
        "name": "cancelled-span",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ .. }),
        ..
      }
    ) => span_id
    _ => abort("expected span_start for cancelled-span")
  }
  match lines[1] {
    Object(
      {
        "kind": "span_end",
        "span_id": String(end_span_id),
        "status": "cancelled",
        ..
      }
    ) => assert_eq(span_id, end_span_id)
    _ => abort("expected cancelled span_end")
  }
}

///|
async test "with_json_writer maps non-finite doubles to null" {
  let nan = 0.0 / 0.0
  let pos_inf = 1.0 / 0.0
  let neg_inf = -1.0 / 0.0
  let writer = MemoryWriter::new()
  with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "non-finite", fields=[
      @tracing.field("nan", @tracing.Double(nan)),
      @tracing.field("pos_inf", @tracing.Double(pos_inf)),
      @tracing.field(
        "payload",
        @tracing.Object([
          ("neg_inf", @tracing.Double(neg_inf)),
          ("finite", @tracing.Double(1.5)),
        ]),
      ),
    ])
  })

  let lines = writer.json_lines()
  assert_eq(1, lines.length())
  assert_true(
    lines[0]
    is Object(
      {
        "kind": "event",
        "name": "non-finite",
        "fields": Object(
          {
            "nan": Null,
            "pos_inf": Null,
            "payload": Object(
              { "neg_inf": Null, "finite": Number(1.5, ..), .. }
            ),
            ..
          }
        ),
        ..
      }
    ),
  )
}

///|
async test "with_json_writer encodes follows-from links precisely" {
  let writer = MemoryWriter::new()
  with_json_writer(writer, ctx => {
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
  let lines = writer.json_lines()
  assert_eq(5, lines.length())
  let parent_span_id = match lines[0] {
    Object(
      {
        "kind": "span_start",
        "span_id": String(span_id),
        "level": "info",
        "name": "parent",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ .. }),
        ..
      }
    ) => span_id
    _ => abort("expected parent span_start")
  }
  let follower_span_id = match lines[1] {
    Object(
      {
        "kind": "span_start",
        "span_id": String(span_id),
        "level": "info",
        "name": "follower",
        "target": String(_),
        "loc": String(_),
        "fields": Object({ .. }),
        ..
      }
    ) => span_id
    _ => abort("expected follower span_start")
  }
  match lines[2] {
    Object(
      {
        "kind": "span_link",
        "span_id": String(link_span_id),
        "follows_from_span_id": String(parent_link_id),
        ..
      }
    ) => {
      assert_eq(follower_span_id, link_span_id)
      assert_eq(parent_span_id, parent_link_id)
    }
    _ => abort("expected span_link")
  }
  match lines[3] {
    Object(
      { "kind": "span_end", "span_id": String(end_span_id), "status": "ok", .. }
    ) => assert_eq(follower_span_id, end_span_id)
    _ => abort("expected follower span_end")
  }
  match lines[4] {
    Object(
      { "kind": "span_end", "span_id": String(end_span_id), "status": "ok", .. }
    ) => assert_eq(parent_span_id, end_span_id)
    _ => abort("expected parent span_end")
  }
}

///|
async test "with_json_writer flushes accepted records on exception path" {
  let writer = MemoryWriter::new()
  let result : Result[Unit, _] = try? with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-fail")
    raise UserFailed
  })
  assert_true(result is Err(UserFailed))
  let lines = writer.json_lines()
  assert_eq(1, lines.length())
  assert_true(
    lines[0]
    is Object(
      {
        "kind": "event",
        "trace_id": String(_),
        "level": "info",
        "name": "before-fail",
        "target": String(_),
        "loc": String(_),
        "fields": Object(_),
        ..
      }
    ),
  )
}

///|
async test "with_json_writer combines user and shutdown failures" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[Unit, _] = try? with_json_writer(writer, ctx => {
    ctx.event(@tracing.Info, "before-double-fail")
    raise UserFailed
  })

  match result {
    Err(@jsonl.UserAndShutdownFailed(user_err, @jsonl.WriterFailed(text))) => {
      assert_true(user_err is UserFailed)
      assert_true(text.contains("SinkFailed"))
    }
    _ => fail("expected combined helper error")
  }
}

///|
async test "with_json_writer handles enclosing cancellation without hanging" {
  let writer = MemoryWriter::new()
  let result : Unit? = @async.with_timeout_opt(10, () => {
    with_json_writer(writer, ctx => {
      ctx.event(@tracing.Info, "before-cancel")
      @async.sleep(100)
    })
  })
  assert_eq(None, result)
}

///|
async test "with_json_writer shutdown attempt stays within the configured timeout" {
  let writer = MemoryWriter::new(delay_ms=50)
  let result : Result[Unit?, _] = try? @async.with_timeout_opt(100, () => {
    with_json_writer(
      writer,
      options=JsonOptions::new(command_timeout_ms=5, shutdown_timeout_ms=5),
      ctx => {
        ctx.event(@tracing.Info, "slow")
        raise UserFailed
      },
    )
  })
  assert_true(result is Err(@jsonl.UserAndShutdownFailed(UserFailed, _)))
}

///|
async test "JsonRuntime counts dropped records when queue is full" {
  let writer = MemoryWriter::new(delay_ms=50)
  let runtime = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(
      group,
      writer,
      options=JsonOptions::new(
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
async test "JsonRuntime flush still works when the record queue is saturated" {
  let writer = MemoryWriter::new(delay_ms=10)
  let runtime = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(
      group,
      writer,
      options=JsonOptions::new(
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
  let lines = writer.json_lines()
  assert_true(lines.length() > 0)
  for line in lines {
    assert_true(
      line
      is Object(
        {
          "kind": "event",
          "trace_id": String(_),
          "level": "info",
          "name": "burst",
          "target": String(_),
          "loc": String(_),
          "fields": Object(_),
          ..
        }
      ),
    )
  }
}

///|
async test "JsonRuntime reports unclosed spans on shutdown" {
  let writer = MemoryWriter::new()
  let runtime = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer)
    let ctx = root_ctx(runtime.dispatch())
    ignore(ctx.span(@tracing.Info, "leaked"))
    runtime.shutdown()
    runtime
  })
  assert_eq(1, runtime.stats().unclosed_spans)
}

///|
async test "JsonRuntime reports writer failures through flush" {
  let writer = MemoryWriter::new(fail_after=0)
  let result : Result[JsonStats, _] = try? @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer)
    let ctx = root_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "first")
    ctx.event(@tracing.Info, "second")
    runtime.flush()
    runtime.shutdown()
    runtime.stats()
  })
  assert_true(result is Err(@jsonl.WriterFailed(_)))
}

///|
async test "JsonRuntime drops new records after a writer failure" {
  let writer = MemoryWriter::new(fail_after=0)
  let runtime = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer)
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
async test "JsonRuntime concurrent flush calls do not steal acknowledgements" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = JsonOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (first_result, second_result, stats) = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer, options~)
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
async test "JsonRuntime concurrent flush and shutdown do not steal acknowledgements" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = JsonOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (flush_result, shutdown_result, stats) = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer, options~)
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
async test "JsonRuntime concurrent shutdown is idempotent" {
  let writer = MemoryWriter::new(delay_ms=20)
  let options = JsonOptions::new(
    record_queue_capacity=8,
    control_queue_capacity=1,
    ack_queue_capacity=1,
    writer_buffer_size=32,
    command_timeout_ms=2000,
    shutdown_timeout_ms=2000,
  )
  let (first_result, second_result, stats) = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(group, writer, options~)
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
async test "JsonRuntime flush is bounded by command timeout" {
  let writer = MemoryWriter::new(delay_ms=100)
  let result : Result[Result[Unit, _]?, _] = try? @async.with_timeout_opt(500, () => {
    @async.with_task_group(group => {
      let runtime = JsonRuntime::start_in(
        group,
        writer,
        options=JsonOptions::new(command_timeout_ms=10, shutdown_timeout_ms=200),
      )
      let ctx = root_ctx(runtime.dispatch())
      ctx.event(@tracing.Info, "slow-flush")
      let flush_result : Result[Unit, _] = try? runtime.flush()
      @async.sleep(120)
      ignore(try? runtime.shutdown())
      flush_result
    })
  })
  assert_true(result is Ok(Some(Err(@jsonl.TimedOut(_)))))
}

///|
async test "JsonRuntime shutdown is bounded by command timeout" {
  let writer = MemoryWriter::new(delay_ms=100)
  let result : Result[Result[Unit, _]?, _] = try? @async.with_timeout_opt(500, () => {
    @async.with_task_group(group => {
      let runtime = JsonRuntime::start_in(
        group,
        writer,
        options=JsonOptions::new(command_timeout_ms=10, shutdown_timeout_ms=200),
      )
      let ctx = root_ctx(runtime.dispatch())
      ctx.event(@tracing.Info, "slow-shutdown")
      try? runtime.shutdown()
    })
  })
  assert_true(result is Ok(Some(Err(@jsonl.TimedOut(_)))))
}

///|
async test "JsonRuntime shutdown can be retried after timing out" {
  let writer = MemoryWriter::new(delay_ms=100)
  let (first_result, second_result) = @async.with_task_group(group => {
    let runtime = JsonRuntime::start_in(
      group,
      writer,
      options=JsonOptions::new(command_timeout_ms=10, shutdown_timeout_ms=200),
    )
    let ctx = root_ctx(runtime.dispatch())
    ctx.event(@tracing.Info, "slow-shutdown-retry")
    let first_result : Result[Unit, _] = try? runtime.shutdown()
    @async.sleep(120)
    let second_result : Result[Unit, _] = try? runtime.shutdown()
    (first_result, second_result)
  })
  assert_true(first_result is Err(@jsonl.TimedOut(_)))
  assert_true(second_result is Ok(_))
}
