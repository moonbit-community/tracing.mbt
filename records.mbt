///|
/// Distinguishes metadata for span-producing callsites from event-producing
/// callsites.
pub(all) enum RecordKind {
  Span
  Event
} derive(Eq, Compare, Hash, Debug)

///|
#deprecated
#doc(hidden)
pub extend RecordKind with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend RecordKind with Compare::{op_lt, op_le, op_ge, compare, op_gt}

///|
#deprecated
#doc(hidden)
pub extend RecordKind with Hash::{hash, hash_combine}

///|
#deprecated
#doc(hidden)
pub extend RecordKind with Debug::{to_repr}

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
#deprecated
#doc(hidden)
pub extend Metadata with Debug::{to_repr}

///|
/// Completion state emitted when a span ends.
pub(all) enum SpanStatus {
  Ok
  Error
  Cancelled
} derive(Eq, Compare, Hash, Debug)

///|
#deprecated
#doc(hidden)
pub extend SpanStatus with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend SpanStatus with Compare::{op_lt, op_le, op_ge, compare, op_gt}

///|
#deprecated
#doc(hidden)
pub extend SpanStatus with Hash::{hash, hash_combine}

///|
#deprecated
#doc(hidden)
pub extend SpanStatus with Debug::{to_repr}

///|
/// Record emitted when a span starts.
pub struct SpanStart {
  metadata : Metadata
  span : SpanContext
  parent : SpanContext?
  fields : Array[Field]
} derive(Debug)

///|
#deprecated
#doc(hidden)
pub extend SpanStart with Debug::{to_repr}

///|
/// Record emitted when an existing span receives additional fields.
pub struct SpanRecord {
  span : SpanContext
  fields : Array[Field]
} derive(Debug)

///|
#deprecated
#doc(hidden)
pub extend SpanRecord with Debug::{to_repr}

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
#deprecated
#doc(hidden)
pub extend EventRecord with Debug::{to_repr}

///|
/// Record emitted when a span ends.
pub struct SpanEnd {
  span : SpanContext
  status : SpanStatus
  error : String?
} derive(Debug)

///|
#deprecated
#doc(hidden)
pub extend SpanEnd with Debug::{to_repr}

///|
/// Record emitted for follows-from relationships.
pub struct SpanLink {
  span : SpanContext
  follows_from : SpanContext
} derive(Debug)

///|
#deprecated
#doc(hidden)
pub extend SpanLink with Debug::{to_repr}

///|
/// Subscriber implementations receive the records produced by enabled tracing
/// callsites.
///
/// Filtering is decided by `Dispatch`, not by individual subscribers.
pub(open) trait Subscriber {
  fn on_span_start(Self, SpanStart) -> Unit
  fn on_span_record(Self, SpanRecord) -> Unit = _
  fn on_event(Self, EventRecord) -> Unit
  fn on_span_end(Self, SpanEnd) -> Unit
  fn on_span_link(Self, SpanLink) -> Unit = _
}

///|
impl Subscriber with fn on_span_record(_self, _record) {

}

///|
impl Subscriber with fn on_span_link(_self, _record) {

}
