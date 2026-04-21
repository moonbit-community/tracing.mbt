///|
/// Severity levels understood by the tracing core.
///
/// The ordering is from most verbose to least verbose. A `LevelFilter(Info)`
/// therefore enables `Info`, `Warn`, and `Error`, while filtering out
/// `Debug` and `Trace`.
pub(all) enum Level {
  Trace
  Debug
  Info
  Warn
  Error
} derive(Eq, Compare, Hash, Debug)

///|
/// Structured field values carried by spans and events.
///
/// `Object` preserves insertion order. This is
/// important for logging pipelines that rely on stable field ordering. Object
/// field names must be unique within each object value.
///
/// `Bytes` values are encoded by the formatter as base64 text.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Int64(Int64)
  UInt(UInt)
  UInt64(UInt64)
  Double(Double)
  String(String)
  Bytes(Bytes)
  Array(Array[Value])
  Object(Array[(String, Value)])
} derive(Eq, Hash)

///|
/// Conversion trait used by `field` and other convenience APIs.
pub(open) trait IntoValue {
  into_value(Self) -> Value
}

///|
/// A named structured field attached to a span or event.
pub struct Field {
  name : String
  value : Value
} derive(Eq, Hash, Debug)

///|
/// Create a structured field by converting `value` into a tracing `Value`.
pub fn[T : IntoValue] field(name : String, value : T) -> Field {
  let value = value.into_value()
  value.assert_unique_object_fields("$")
  { name, value }
}

///|
fn Value::assert_unique_object_fields(self : Value, path : String) -> Unit {
  match self {
    Array(values) =>
      for index = 0; index < values.length(); index = index + 1 {
        values[index].assert_unique_object_fields("\{path}[\{index}]")
      }
    Object(entries) => {
      let seen : Map[String, Bool] = {}
      for index = 0; index < entries.length(); index = index + 1 {
        let (name, value) = entries[index]
        let entry_path = "\{path}.\{name}"
        guard !seen.contains(name) else {
          abort(
            "tracing.Value::Object does not allow duplicate field names: \{entry_path}",
          )
        }
        seen[name] = true
        value.assert_unique_object_fields(entry_path)
      }
    }
    _ => ()
  }
}

///|
fn Field::assert_unique_object_fields(self : Field) -> Unit {
  self.value.assert_unique_object_fields("$")
}

///|
fn validate_fields(fields : ArrayView[Field]) -> Unit {
  for field in fields {
    field.assert_unique_object_fields()
  }
}

///|
fn Level::allows(self : Level, level : Level) -> Bool {
  level >= self
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
fn append_json_string(builder : StringBuilder, value : String) -> Unit {
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
fn append_json_double(builder : StringBuilder, value : Double) -> Unit {
  if value.is_nan() || value.is_inf() {
    builder.write_string("null")
  } else {
    builder.write_object(value)
  }
}

///|
fn Value::append_json(self : Value, builder : StringBuilder) -> Unit {
  match self {
    Null => builder.write_string("null")
    Bool(value) => builder.write_string(if value { "true" } else { "false" })
    Int(value) => builder.write_object(value)
    Int64(value) => builder.write_string(value.to_string())
    UInt(value) => builder.write_object(value)
    UInt64(value) => builder.write_string(value.to_string())
    Double(value) => append_json_double(builder, value)
    String(value) => append_json_string(builder, value)
    Bytes(value) => append_json_string(builder, @base64.encode(value[:]))
    Array(values) => {
      builder.write_char('[')
      for index = 0; index < values.length(); index = index + 1 {
        if index > 0 {
          builder.write_char(',')
        }
        values[index].append_json(builder)
      }
      builder.write_char(']')
    }
    Object(entries) => {
      builder.write_char('{')
      for index = 0; index < entries.length(); index = index + 1 {
        if index > 0 {
          builder.write_char(',')
        }
        let (name, value) = entries[index]
        append_json_string(builder, name)
        builder.write_char(':')
        value.append_json(builder)
      }
      builder.write_char('}')
    }
  }
}

///|
/// Encode a tracing value into JSON text without converting through the core
/// `Json` AST.
pub fn Value::to_json_string(self : Value) -> String {
  self.assert_unique_object_fields("$")
  let builder = StringBuilder::new()
  self.append_json(builder)
  builder.to_string()
}

///|
fn Value::to_debug_repr(self : Value) -> Repr {
  self.assert_unique_object_fields("$")
  match self {
    Null => Repr::literal("null")
    Bool(value) => Repr::bool(value)
    Int(value) => Repr::integer(value.to_string())
    Int64(value) => Repr::integer(value.to_string())
    UInt(value) => Repr::integer(value.to_string())
    UInt64(value) => Repr::integer(value.to_string())
    Double(value) => Repr::double(value)
    String(value) => Repr::string(value)
    Bytes(value) => Repr::string(@base64.encode(value[:]))
    Array(values) => Repr::array(values.map(value => value.to_debug_repr()))
    Object(entries) =>
      Repr::map(
        entries.map(entry => {
          let (name, value) = entry
          (Repr::string(name), value.to_debug_repr())
        }),
      )
  }
}

///|
pub impl Debug for Value with to_repr(self) {
  self.to_debug_repr()
}

///|
pub impl IntoValue for Value with into_value(self) {
  self
}

///|
pub impl IntoValue for Bool with into_value(self) {
  Bool(self)
}

///|
pub impl IntoValue for Int with into_value(self) {
  Int(self)
}

///|
pub impl IntoValue for Int64 with into_value(self) {
  Int64(self)
}

///|
pub impl IntoValue for UInt with into_value(self) {
  UInt(self)
}

///|
pub impl IntoValue for UInt64 with into_value(self) {
  UInt64(self)
}

///|
pub impl IntoValue for Double with into_value(self) {
  Double(self)
}

///|
pub impl IntoValue for String with into_value(self) {
  String(self)
}

///|
pub impl IntoValue for StringView with into_value(self) {
  String(self.to_string())
}

///|
pub impl IntoValue for Bytes with into_value(self) {
  Bytes(self)
}

///|
pub impl IntoValue for BytesView with into_value(self) {
  Bytes(self.to_bytes())
}

///|
pub impl IntoValue for Array[Value] with into_value(self) {
  Array(self)
}

///|
pub impl IntoValue for ArrayView[Value] with into_value(self) {
  Array(self.to_array())
}
