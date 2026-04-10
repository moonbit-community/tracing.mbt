///|
/// Distinguishes metadata for span-producing callsites from event-producing
/// callsites.
pub(all) enum RecordKind {
  Span
  Event
} derive(Eq, Compare, Hash, Debug)

///|
/// Static metadata attached to a tracing callsite.
///
/// `target` is either supplied explicitly by the caller or derived from
/// `SourceLoc` using the documented `...@package/path` suffix rule.
pub struct Metadata {
  kind : RecordKind
  level : Level
  name : String
  target : String
  loc : SourceLoc
} derive(Debug)

///|
/// Completion state emitted when a span ends.
pub(all) enum SpanStatus {
  Ok
  Error
  Cancelled
} derive(Eq, Compare, Hash, Debug)

///|
/// Record emitted when a span starts.
pub struct SpanStart {
  metadata : Metadata
  span : SpanContext
  parent : SpanContext?
  fields : Array[Field]
} derive(Debug)

///|
/// Record emitted when an existing span receives additional fields.
pub struct SpanRecord {
  span : SpanContext
  fields : Array[Field]
} derive(Debug)

///|
/// Record emitted for standalone events.
pub struct EventRecord {
  metadata : Metadata
  trace_id : TraceId
  span : SpanContext?
  message : String?
  fields : Array[Field]
} derive(Debug)

///|
/// Record emitted when a span ends.
pub struct SpanEnd {
  span : SpanContext
  status : SpanStatus
  error : String?
} derive(Debug)

///|
/// Record emitted for follows-from relationships.
pub struct SpanLink {
  span : SpanContext
  follows_from : SpanContext
} derive(Debug)

///|
/// Subscriber implementations receive the records produced by enabled tracing
/// callsites.
///
/// Filtering is decided by `Dispatch`, not by individual subscribers.
pub(open) trait Subscriber {
  on_span_start(Self, SpanStart) -> Unit
  on_span_record(Self, SpanRecord) -> Unit = _
  on_event(Self, EventRecord) -> Unit
  on_span_end(Self, SpanEnd) -> Unit
  on_span_link(Self, SpanLink) -> Unit = _
}

///|
impl Subscriber with on_span_record(_self, _record) {

}

///|
impl Subscriber with on_span_link(_self, _record) {

}
