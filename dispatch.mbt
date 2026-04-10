///|
/// Metadata-only filter expression used by `Dispatch`.
pub(all) enum Filter {
  LevelFilter(Level)
  TargetFilter(Map[String, Level])
  AndFilter(Filter, Filter)
} derive(Debug)

///|
priv struct Lane {
  filter : Filter?
  subscriber : &Subscriber
}

///|
fn filter_allows(filter : Filter, metadata : Metadata) -> Bool {
  match filter {
    LevelFilter(max_level) => max_level.allows(metadata.level)
    TargetFilter(levels) =>
      match levels.get(metadata.target) {
        Some(max_level) => max_level.allows(metadata.level)
        None => false
      }
    AndFilter(lhs, rhs) =>
      filter_allows(lhs, metadata) && filter_allows(rhs, metadata)
  }
}

///|
fn lane_allows(lane : Lane, metadata : Metadata) -> Bool {
  match lane.filter {
    Some(filter) => filter_allows(filter, metadata)
    None => true
  }
}

///|
fn derive_target(loc : SourceLoc) -> String {
  let encoded = loc.to_string()
  match encoded.rev_find("@") {
    Some(index) if index + 1 < encoded.length() =>
      encoded[index + 1:].to_string()
    _ => "unknown"
  }
}

///|
fn normalize_target(target : String?, loc : SourceLoc) -> String {
  match target {
    Some(target) => target
    None => derive_target(loc)
  }
}

///|
/// `Dispatch` is the filtering and fanout authority for tracing records.
pub struct Dispatch {
  priv lanes : Array[Lane]
}

///|
/// Create a dispatch that never enables any event or span.
pub fn Dispatch::noop() -> Dispatch {
  { lanes: [] }
}

///|
/// Create a dispatch with a single unfiltered subscriber lane.
pub fn Dispatch::from_subscriber(subscriber : &Subscriber) -> Dispatch {
  { lanes: [{ filter: None, subscriber }] }
}

///|
/// Combine multiple dispatches into a single fanout dispatch.
pub fn Dispatch::fanout(dispatches : ArrayView[Dispatch]) -> Dispatch {
  let lanes : Array[Lane] = []
  for dispatch in dispatches {
    for lane in dispatch.lanes {
      lanes.push(lane)
    }
  }
  { lanes, }
}

///|
/// Return a dispatch that additionally applies `filter` to every existing lane.
pub fn Dispatch::filtered(self : Dispatch, filter : Filter) -> Dispatch {
  let lanes : Array[Lane] = []
  for lane in self.lanes {
    let filter = match lane.filter {
      Some(existing) => Some(AndFilter(existing, filter))
      None => Some(filter)
    }
    lanes.push({ filter, subscriber: lane.subscriber })
  }
  { lanes, }
}

///|
fn Dispatch::select_lanes(self : Dispatch, metadata : Metadata) -> Array[Lane] {
  let lanes : Array[Lane] = []
  for lane in self.lanes {
    if lane_allows(lane, metadata) {
      lanes.push(lane)
    }
  }
  lanes
}
