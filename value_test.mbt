///|
test "Value Debug stays JSON-like" {
  debug_inspect(
    @tracing.Object([
      ("dup", @tracing.Int64(@string.parse_int64("9007199254740993"))),
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
      #|  "dup": 9007199254740993,
      #|  "text": "line\n\"quoted\"",
      #|  "bytes": "aGk=",
      #|  "items": [true, null, { "nested": 7 }],
      #|}
    ),
  )
}
