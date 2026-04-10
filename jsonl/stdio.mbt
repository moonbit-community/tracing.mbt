///|
/// Like `with_json_writer`, but writes JSON Lines to stdout on native targets.
pub async fn[X] with_json_stdout(
  options? : JsonOptions = JsonOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  with_json_writer(@stdio.stdout, f, options~)
}

///|
/// Like `with_json_writer`, but writes JSON Lines to stderr on native targets.
pub async fn[X] with_json_stderr(
  options? : JsonOptions = JsonOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  with_json_writer(@stdio.stderr, f, options~)
}
