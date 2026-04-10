///|
let max_int64 : Int64 = 9223372036854775807L

///|
let max_int64_u64 : UInt64 = 9223372036854775807UL

///|
let zero8 : Bytes = Bytes::make(8, b'\x00')

///|
let zero16 : Bytes = Bytes::make(16, b'\x00')

///|
let splitmix64_gamma : UInt64 = 0x9E3779B97F4A7C15UL

///|
let splitmix64_mul1 : UInt64 = 0xBF58476D1CE4E5B9UL

///|
let splitmix64_mul2 : UInt64 = 0x94D049BB133111EBUL

///|
let allocator_entropy_nonce : Ref[UInt64] = Ref::new(0UL)

///|
fn bytes_to_hex(bytes : BytesView) -> String {
  let builder = StringBuilder::new(size_hint=bytes.length() * 2)
  for byte in bytes {
    builder.write_string(byte.to_hex())
  }
  builder.to_string().to_lower()
}

///|
fn parse_hex_bytes(hex : StringView, expected_length : Int) -> Bytes? {
  guard hex.length() == expected_length * 2 else { return None }
  let chars = hex.to_array()
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < chars.length() {
    guard decode_hex_digit(chars[index]) is Some(high) else { return None }
    guard decode_hex_digit(chars[index + 1]) is Some(low) else { return None }
    bytes.push(((high << 4) | low).to_byte())
    index += 2
  }
  Some(Bytes::from_array(bytes))
}

///|
/// Trace flags carried by W3C `traceparent`.
pub struct TraceFlags {
  priv raw : UInt
} derive(Eq, Compare, Hash, Debug)

///|
pub fn TraceFlags::new(raw : UInt) -> TraceFlags {
  { raw: raw & 0xFFU }
}

///|
pub fn TraceFlags::sampled() -> TraceFlags {
  TraceFlags::new(1U)
}

///|
pub fn TraceFlags::not_sampled() -> TraceFlags {
  TraceFlags::new(0U)
}

///|
pub fn TraceFlags::is_sampled(self : TraceFlags) -> Bool {
  (self.raw & 1U) == 1U
}

///|
pub fn TraceFlags::to_uint(self : TraceFlags) -> UInt {
  self.raw
}

///|
/// Identifier for a trace tree.
pub struct TraceId {
  priv raw : Bytes
} derive(Eq, Compare, Hash)

///|
/// Identifier for a single span within a trace.
pub struct SpanId {
  priv raw : Bytes
} derive(Eq, Compare, Hash)

///|
/// Explicit allocator for root trace identifiers.
///
/// Copying this allocator shares the same underlying sequence.
priv enum TraceIdAllocatorState {
  Counter(Ref[Int64])
  Random(@random.Rand)
}

///|
pub struct TraceIdAllocator {
  priv state : TraceIdAllocatorState
}

///|
fn TraceId::invalid() -> TraceId {
  { raw: zero16 }
}

///|
fn SpanId::invalid() -> SpanId {
  { raw: zero8 }
}

///|
fn TraceId::is_zero(self : TraceId) -> Bool {
  self.raw == zero16
}

///|
fn SpanId::is_zero(self : SpanId) -> Bool {
  self.raw == zero8
}

///|
fn splitmix64(value : UInt64) -> UInt64 {
  let value = value + splitmix64_gamma
  let value = (value ^ (value >> 30)) * splitmix64_mul1
  let value = (value ^ (value >> 27)) * splitmix64_mul2
  value ^ (value >> 31)
}

///|
fn allocator_seed_bytes(seed : UInt64) -> Bytes {
  splitmix64(seed).to_be_bytes() +
  splitmix64(seed + splitmix64_gamma).to_be_bytes() +
  splitmix64(seed + splitmix64_gamma * 2UL).to_be_bytes() +
  splitmix64(seed + splitmix64_gamma * 3UL).to_be_bytes()
}

///|
fn next_allocator_seed() -> Bytes {
  allocator_entropy_nonce.val += 1UL
  let seed = @env.now() ^
    (allocator_entropy_nonce.val * splitmix64_gamma) ^
    0xD1B54A32D192ED03UL
  allocator_seed_bytes(seed)
}

///|
pub fn TraceId::from_hex(hex : StringView) -> TraceId? {
  match parse_hex_bytes(hex, 16) {
    Some(raw) => Some({ raw, })
    None => None
  }
}

///|
pub fn TraceId::from_bytes(bytes : BytesView) -> TraceId? {
  guard bytes.length() == 16 else { return None }
  Some({ raw: bytes.to_bytes() })
}

///|
pub fn TraceId::to_bytes(self : TraceId) -> Bytes {
  self.raw
}

///|
pub fn TraceId::to_hex(self : TraceId) -> String {
  bytes_to_hex(self.raw[:])
}

///|
pub fn SpanId::from_hex(hex : StringView) -> SpanId? {
  match parse_hex_bytes(hex, 8) {
    Some(raw) => Some({ raw, })
    None => None
  }
}

///|
pub fn SpanId::from_bytes(bytes : BytesView) -> SpanId? {
  guard bytes.length() == 8 else { return None }
  Some({ raw: bytes.to_bytes() })
}

///|
pub fn SpanId::to_bytes(self : SpanId) -> Bytes {
  self.raw
}

///|
pub fn SpanId::to_hex(self : SpanId) -> String {
  bytes_to_hex(self.raw[:])
}

///|
fn TraceId::from_local_raw(raw : Int64) -> TraceId {
  { raw: zero8 + raw.reinterpret_as_uint64().to_be_bytes() }
}

///|
fn SpanId::from_local_raw(raw : Int64) -> SpanId {
  { raw: raw.reinterpret_as_uint64().to_be_bytes() }
}

///|
fn TraceId::from_random(rand : @random.Rand) -> TraceId {
  for ;; {
    let trace_id : TraceId = {
      raw: rand.uint64().to_be_bytes() + rand.uint64().to_be_bytes(),
    }
    if !trace_id.is_zero() {
      return trace_id
    }
  }
}

///|
fn SpanId::from_random(rand : @random.Rand) -> SpanId {
  for ;; {
    let span_id : SpanId = { raw: rand.uint64().to_be_bytes() }
    if !span_id.is_zero() {
      return span_id
    }
  }
}

///|
pub impl Debug for TraceId with to_repr(self) {
  Repr::literal(self.to_hex())
}

///|
pub impl Debug for SpanId with to_repr(self) {
  Repr::literal(self.to_hex())
}

///|
pub impl Show for TraceId with output(self, logger) {
  logger.write_string(self.to_hex())
}

///|
pub impl Show for SpanId with output(self, logger) {
  logger.write_string(self.to_hex())
}

///|
pub fn TraceIdAllocator::new() -> TraceIdAllocator {
  { state: Random(@random.Rand::chacha8(seed=next_allocator_seed())) }
}

///|
/// Construct a deterministic allocator for tests and documentation.
///
/// `seed` controls the first lazily allocated trace id. For example,
/// `new_seeded(0)` reproduces the historical sequence that starts from `...01`.
pub fn TraceIdAllocator::new_seeded(seed : UInt64) -> TraceIdAllocator {
  guard seed <= max_int64_u64 else {
    abort("TraceIdAllocator seed must fit in Int64")
  }
  { state: Counter(Ref::new(seed.reinterpret_as_int64())) }
}

///|
fn TraceIdAllocator::allocate(self : TraceIdAllocator) -> TraceId {
  match self.state {
    Counter(next_raw) => {
      guard next_raw.val < max_int64 else {
        abort("Trace ID allocator exhausted")
      }
      next_raw.val += 1L
      TraceId::from_local_raw(next_raw.val)
    }
    Random(rand) => TraceId::from_random(rand)
  }
}

///|
fn TraceIdAllocator::allocate_span_id(
  self : TraceIdAllocator,
  next : Ref[Int64],
) -> SpanId {
  match self.state {
    Counter(_) => {
      guard next.val < max_int64 else { abort("Span ID allocator exhausted") }
      next.val += 1L
      SpanId::from_local_raw(next.val)
    }
    Random(rand) => SpanId::from_random(rand)
  }
}
