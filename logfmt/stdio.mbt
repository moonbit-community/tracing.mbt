///|
/// Like `with_logfmt_writer`, but writes logfmt to stdout on native targets.
pub async fn[X] with_logfmt_stdout(
  options? : LogfmtOptions = LogfmtOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  with_logfmt_writer(@stdio.stdout, f, options~)
}

///|
/// Like `with_logfmt_writer`, but writes logfmt to stderr on native targets.
pub async fn[X] with_logfmt_stderr(
  options? : LogfmtOptions = LogfmtOptions::default(),
  f : async (@tracing.TraceContext) -> X,
) -> X {
  with_logfmt_writer(@stdio.stderr, f, options~)
}
