///|
test "Value Debug stays JSON-like" {
  debug_inspect(
    @tracing.Object([
      ("int64", Int64(@string.parse_int64("9007199254740993"))),
      ("text", String("line\n\"quoted\"")),
      ("bytes", Bytes(b"hi")),
      ("items", Array([Bool(true), Null, Object([("nested", UInt64(7UL))])])),
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

  @debug.assert_eq(@tracing.Double(nan).to_json_string(), "null")
  @debug.assert_eq(@tracing.Double(pos_inf).to_json_string(), "null")
  @debug.assert_eq(@tracing.Double(neg_inf).to_json_string(), "null")
  @debug.assert_eq(
    @tracing.Object([
      ("scalar", Double(nan)),
      ("items", Array([Double(pos_inf), Double(1.5), Double(neg_inf)])),
    ]).to_json_string(),
    "{\"scalar\":null,\"items\":[null,1.5,null]}",
  )
}

///|
test "panic Value::to_json_string rejects duplicate object field names" {
  ignore(@tracing.Object([("dup", Int(1)), ("dup", Int(2))]).to_json_string())
}
