///|
test "Value Debug stays JSON-like" {
  debug_inspect(
    @tracing.Object([
      ("int64", @tracing.Int64(@string.parse_int64("9007199254740993"))),
      ("text", @tracing.String("line\n\"quoted\"")),
      ("bytes", @tracing.Bytes(b"hi")),
      (
        "items",
        @tracing.Array([
          @tracing.Bool(true),
          @tracing.Null,
          @tracing.Object([("nested", @tracing.UInt64(7UL))]),
        ]),
      ),
    ]),
    content=(
      #|{
      #|  "int64": 9007199254740993,
      #|  "text": "line\n\"quoted\"",
      #|  "bytes": "aGk=",
      #|  "items": [true, null, { "nested": 7 }],
      #|}
    ),
  )
}

///|
test "Value::to_json_string maps non-finite doubles to null" {
  let nan = 0.0 / 0.0
  let pos_inf = 1.0 / 0.0
  let neg_inf = -1.0 / 0.0

  assert_eq(@tracing.Double(nan).to_json_string(), "null")
  assert_eq(@tracing.Double(pos_inf).to_json_string(), "null")
  assert_eq(@tracing.Double(neg_inf).to_json_string(), "null")
  assert_eq(
    @tracing.Object([
      ("scalar", @tracing.Double(nan)),
      (
        "items",
        @tracing.Array([
          @tracing.Double(pos_inf),
          @tracing.Double(1.5),
          @tracing.Double(neg_inf),
        ]),
      ),
    ]).to_json_string(),
    "{\"scalar\":null,\"items\":[null,1.5,null]}",
  )
}

///|
test "panic Value::to_json_string rejects duplicate object field names" {
  ignore(
    @tracing.Object([("dup", @tracing.Int(1)), ("dup", @tracing.Int(2))]).to_json_string(),
  )
}
