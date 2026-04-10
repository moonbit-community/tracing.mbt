///|
let trace_state_limit = 32

///|
let baggage_entry_limit = 64

///|
let baggage_length_limit = 8192

///|
fn duplicate_pairs(
  entries : Array[(String, String)],
) -> Array[(String, String)] {
  let result : Array[(String, String)] = []
  for entry in entries {
    result.push(entry)
  }
  result
}

///|
fn duplicate_baggage_entries(
  entries : Array[BaggageEntry],
) -> Array[BaggageEntry] {
  let result : Array[BaggageEntry] = []
  for entry in entries {
    result.push(entry)
  }
  result
}

///|
fn is_trace_state_key_char(ch : Char) -> Bool {
  ch.is_ascii_lowercase() ||
  ch.is_ascii_digit() ||
  ch is ('_' | '-' | '*' | '/' | '@')
}

///|
fn valid_trace_state_key(key : StringView) -> Bool {
  if key.is_empty() || key.length() > 256 {
    return false
  }
  let mut at_count = 0
  for index, ch in key.iter2() {
    if !is_trace_state_key_char(ch) {
      return false
    }
    if index == 0 && !(ch.is_ascii_lowercase() || ch.is_ascii_digit()) {
      return false
    }
    if ch == '@' {
      at_count += 1
      if at_count > 1 || index + 1 >= key.length() {
        return false
      }
    }
  }
  true
}

///|
fn valid_trace_state_value(value : StringView) -> Bool {
  if value.length() > 256 {
    return false
  }
  for ch in value {
    if ch == ',' || ch == '=' {
      return false
    }
    if !(ch.is_ascii_graphic() || ch == ' ') {
      return false
    }
  }
  true
}

///|
fn valid_baggage_name(name : StringView) -> Bool {
  if name.is_empty() {
    return false
  }
  for ch in name {
    if !ch.is_ascii_graphic() {
      return false
    }
    if ch
      is ('('
      | ')'
      | ','
      | '/'
      | ':'
      | ';'
      | '<'
      | '='
      | '>'
      | '?'
      | '@'
      | '['
      | '\\'
      | ']'
      | '{'
      | '}'
      | '"') {
      return false
    }
  }
  true
}

///|
fn valid_baggage_metadata(metadata : StringView) -> Bool {
  for ch in metadata {
    if ch == ',' {
      return false
    }
    if !(ch.is_ascii_graphic() || ch == ' ') {
      return false
    }
  }
  true
}

///|
fn hex_digit(value : Int) -> Byte {
  "0123456789ABCDEF".code_unit_at(value).to_byte()
}

///|
fn decode_hex_digit(ch : Char) -> Int? {
  if ch.is_ascii_digit() {
    Some(ch.to_int() - '0'.to_int())
  } else if ch.is_ascii_lowercase() && ch <= 'f' {
    Some(ch.to_int() - 'a'.to_int() + 10)
  } else if ch.is_ascii_uppercase() && ch <= 'F' {
    Some(ch.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn percent_encode(input : String) -> String {
  let bytes = @utf8.encode(input)
  let out : Array[Byte] = []
  for b in bytes {
    let ch = b.to_char()
    if ch.is_ascii_digit() ||
      ch.is_ascii_lowercase() ||
      ch.is_ascii_uppercase() ||
      ch is ('-' | '.' | '_' | '~') {
      out.push(b)
    } else {
      let n = b.to_int()
      out.push(b'%')
      out.push(hex_digit((n >> 4) & 0x0F))
      out.push(hex_digit(n & 0x0F))
    }
  }
  @utf8.decode_lossy(Bytes::from_array(out)[:])
}

///|
fn percent_decode(input : StringView) -> String? {
  let chars = input.to_array()
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    if ch == '%' {
      guard index + 2 < chars.length() else { return None }
      guard decode_hex_digit(chars[index + 1]) is Some(high) else {
        return None
      }
      guard decode_hex_digit(chars[index + 2]) is Some(low) else { return None }
      bytes.push(((high << 4) | low).to_byte())
      index += 3
    } else {
      for byte in @utf8.encode(ch.to_string()) {
        bytes.push(byte)
      }
      index += 1
    }
  }
  Some(@utf8.decode_lossy(Bytes::from_array(bytes)[:]))
}

///|
/// Ordered W3C `tracestate` members carried alongside the current trace.
pub struct TraceState {
  priv entries : Array[(String, String)]
} derive(Eq, Compare, Hash, Debug)

///|
pub impl Default for TraceState with default() {
  { entries: [] }
}

///|
pub fn TraceState::empty() -> TraceState {
  TraceState::default()
}

///|
pub fn TraceState::is_empty(self : TraceState) -> Bool {
  self.entries.is_empty()
}

///|
pub fn TraceState::entries(self : TraceState) -> Array[(String, String)] {
  duplicate_pairs(self.entries)
}

///|
pub fn TraceState::get(self : TraceState, key : StringView) -> String? {
  for entry in self.entries {
    let (entry_key, entry_value) = entry
    if entry_key == key.to_string() {
      return Some(entry_value)
    }
  }
  None
}

///|
pub fn TraceState::header(self : TraceState) -> String {
  let builder = StringBuilder::new()
  for index = 0; index < self.entries.length(); index = index + 1 {
    if index > 0 {
      builder.write_char(',')
    }
    let (key, value) = self.entries[index]
    builder.write_string(key)
    builder.write_char('=')
    builder.write_string(value)
  }
  builder.to_string()
}

///|
pub fn TraceState::from_header(header : StringView) -> TraceState? {
  let header = header.trim()
  if header.is_empty() {
    return Some(TraceState::empty())
  }
  let entries : Array[(String, String)] = []
  let seen : Map[String, Bool] = {}
  for item in header.split(",") {
    let item = item.trim()
    guard !item.is_empty() else { return None }
    guard item.split_once("=") is Some((key, value)) else { return None }
    let key = key.trim()
    let value = value.trim()
    guard valid_trace_state_key(key) else { return None }
    guard valid_trace_state_value(value) else { return None }
    guard !seen.contains(key.to_string()) else { return None }
    entries.push((key.to_string(), value.to_string()))
    seen[key.to_string()] = true
  }
  guard entries.length() <= trace_state_limit else { return None }
  Some({ entries, })
}

///|
pub fn TraceState::insert(
  self : TraceState,
  key : String,
  value : String,
) -> TraceState? {
  guard valid_trace_state_key(key) else { return None }
  guard valid_trace_state_value(value) else { return None }
  let entries : Array[(String, String)] = [(key, value)]
  for entry in self.entries {
    if entry.0 != key {
      entries.push(entry)
    }
  }
  guard entries.length() <= trace_state_limit else { return None }
  Some({ entries, })
}

///|
pub fn TraceState::remove(self : TraceState, key : StringView) -> TraceState {
  let entries : Array[(String, String)] = []
  for entry in self.entries {
    if entry.0 != key.to_string() {
      entries.push(entry)
    }
  }
  { entries, }
}

///|
/// A single W3C baggage member.
pub struct BaggageEntry {
  name : String
  value : String
  metadata : String?
} derive(Eq, Compare, Hash, Debug)

///|
fn BaggageEntry::header(self : BaggageEntry) -> String {
  let builder = StringBuilder::new()
  builder.write_string(self.name)
  builder.write_char('=')
  builder.write_string(percent_encode(self.value))
  if self.metadata is Some(metadata) {
    if metadata != "" {
      builder.write_char(';')
      builder.write_string(metadata)
    }
  }
  builder.to_string()
}

///|
/// Ordered baggage members carried by a trace context.
pub struct Baggage {
  priv entries : Array[BaggageEntry]
} derive(Eq, Compare, Hash, Debug)

///|
pub impl Default for Baggage with default() {
  { entries: [] }
}

///|
pub fn Baggage::empty() -> Baggage {
  Baggage::default()
}

///|
pub fn Baggage::is_empty(self : Baggage) -> Bool {
  self.entries.is_empty()
}

///|
pub fn Baggage::entries(self : Baggage) -> Array[BaggageEntry] {
  duplicate_baggage_entries(self.entries)
}

///|
pub fn Baggage::get(self : Baggage, name : StringView) -> BaggageEntry? {
  for entry in self.entries {
    if entry.name == name.to_string() {
      return Some(entry)
    }
  }
  None
}

///|
pub fn Baggage::header(self : Baggage) -> String {
  let builder = StringBuilder::new()
  for index = 0; index < self.entries.length(); index = index + 1 {
    if index > 0 {
      builder.write_char(',')
    }
    builder.write_string(self.entries[index].header())
  }
  builder.to_string()
}

///|
fn baggage_with_entries(entries : Array[BaggageEntry]) -> Baggage? {
  guard entries.length() <= baggage_entry_limit else { return None }
  let baggage : Baggage = { entries, }
  guard baggage.header().length() <= baggage_length_limit else { return None }
  Some(baggage)
}

///|
pub fn Baggage::from_header(header : StringView) -> Baggage? {
  let header = header.trim()
  if header.is_empty() {
    return Some(Baggage::empty())
  }
  let entries : Array[BaggageEntry] = []
  let seen : Map[String, Bool] = {}
  for item in header.split(",") {
    let item = item.trim()
    guard !item.is_empty() else { return None }
    let (pair, metadata) = match item.find(";") {
      Some(index) =>
        (item[:index].trim(), Some(item[index + 1:].trim().to_string()))
      None => (item, None)
    }
    guard pair.split_once("=") is Some((name, encoded_value)) else {
      return None
    }
    let name = name.trim()
    let encoded_value = encoded_value.trim()
    guard valid_baggage_name(name) else { return None }
    guard !seen.contains(name.to_string()) else { return None }
    guard percent_decode(encoded_value) is Some(value) else { return None }
    guard metadata is None || valid_baggage_metadata(metadata.unwrap()) else {
      return None
    }
    entries.push({ name: name.to_string(), value, metadata })
    seen[name.to_string()] = true
  }
  baggage_with_entries(entries)
}

///|
pub fn Baggage::insert(
  self : Baggage,
  name : String,
  value : String,
  metadata? : String,
) -> Baggage? {
  guard valid_baggage_name(name) else { return None }
  guard metadata is None || valid_baggage_metadata(metadata.unwrap()) else {
    return None
  }
  let entries : Array[BaggageEntry] = [{ name, value, metadata }]
  for entry in self.entries {
    if entry.name != name {
      entries.push(entry)
    }
  }
  baggage_with_entries(entries)
}

///|
pub fn Baggage::remove(self : Baggage, name : StringView) -> Baggage {
  let entries : Array[BaggageEntry] = []
  for entry in self.entries {
    if entry.name != name.to_string() {
      entries.push(entry)
    }
  }
  { entries, }
}

///|
/// Immutable span identity used for parenting, linking, and propagation.
///
/// `SpanContext` is safe to copy and pass across tasks because it does not own
/// span lifecycle operations.
///
/// `trace_flags`, `trace_state`, and `is_remote` make the value sufficient for
/// W3C propagation and OpenTelemetry linking.
#alias(SpanRef)
pub struct SpanContext {
  trace_id : TraceId
  span_id : SpanId
  trace_flags : TraceFlags
  trace_state : TraceState
  is_remote : Bool
} derive(Eq, Compare, Hash, Debug)

///|
pub fn SpanContext::invalid() -> SpanContext {
  {
    trace_id: TraceId::invalid(),
    span_id: SpanId::invalid(),
    trace_flags: TraceFlags::not_sampled(),
    trace_state: TraceState::empty(),
    is_remote: false,
  }
}

///|
pub fn SpanContext::new(
  trace_id : TraceId,
  span_id : SpanId,
  trace_flags? : TraceFlags = TraceFlags::sampled(),
  trace_state? : TraceState = TraceState::empty(),
  is_remote? : Bool = false,
) -> SpanContext {
  { trace_id, span_id, trace_flags, trace_state, is_remote }
}

///|
pub fn SpanContext::is_valid(self : SpanContext) -> Bool {
  !self.trace_id.is_zero() && !self.span_id.is_zero()
}
