///|
// A one-byte sink exercises @io.Writer's partial-write contract on every write.
priv struct ByteSink {
  bytes : @buffer.Buffer
}

///|
impl @io.Writer for ByteSink with fn write_once(self, bytes, offset~, len~) {
  if len == 0 {
    return 0
  }
  self.bytes.write_byte(bytes[offset])
  1
}

///|
// RFC 2046 section 5.1.1: delimiter CRLF belongs to the delimiter, so it must
// be written even when a part already ends with CRLF or has an empty body.
// https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1
async test "writer preserves empty parts, line endings, and binary bodies" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let writer = @multipart.Writer(sink, boundary="simple boundary")
  writer.write_part(headers={ "Content-Type": "text/plain" }, target => {
    target.write("first\r\n")
  })
  let empty = @io.MemoryReader(_ => ())
  defer empty.close()
  writer.write_reader(headers={}, empty)
  let binary = @io.MemoryReader(target => {
    target.write(b"ignored|\x00\xff\r\n--simple boundaryX\r\n")
  })
  defer binary.close()
  assert_eq(binary.read_until("|"), Some("ignored"))
  writer.write_reader(
    headers={ "Content-Type": "application/octet-stream" },
    binary,
  )
  writer.finish()
  writer.finish()
  inspect(
    sink.bytes.to_bytes(),
    content=(
      #|b"--simple boundary\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0afirst\x0d\x0a\x0d\x0a--simple boundary\x0d\x0a\x0d\x0a\x0d\x0a--simple boundary\x0d\x0aContent-Type: application/octet-stream\x0d\x0a\x0d\x0a\x00\xff\x0d\x0a--simple boundaryX\x0d\x0a\x0d\x0a--simple boundary--\x0d\x0a"
    ),
  )
}

///|
// Boundary vectors are adapted from Go's TestWriterSetBoundary, with the full
// RFC 2046 bchars alphabet and CR/LF/HTAB cases added from its ABNF.
// https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/writer_test.go
// https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1
test "writer validates RFC 2046 boundaries" {
  let results : Array[(String, String)] = []
  for
    boundary in [
      "abc",
      "",
      "ungültig",
      "!",
      "x".repeat(70),
      "x".repeat(71),
      "bad!ascii!",
      "my-separator",
      "with space",
      "badspace ",
      "(boundary)",
      "'()+_,-./:=? 0123456789AZaz",
      "line\rbreak",
      "line\nbreak",
      "tab\there",
    ] {
    let sink = ByteSink::{ bytes: @buffer.Buffer(), }
    let outcome = try @multipart.Writer(sink, boundary~) |> ignore catch {
      @multipart.MultipartError(message) => message
    } noraise {
      _ => "accepted"
    }
    results.push((boundary, outcome))
  }
  json_inspect(results, content=[
    ["abc", "accepted"],
    ["", "multipart boundary must contain 1 to 70 characters"],
    ["ungültig", "invalid character in multipart boundary"],
    ["!", "invalid character in multipart boundary"],
    [
      "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "accepted",
    ],
    [
      "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "multipart boundary must contain 1 to 70 characters",
    ],
    ["bad!ascii!", "invalid character in multipart boundary"],
    ["my-separator", "accepted"],
    ["with space", "accepted"],
    ["badspace ", "multipart boundary must not end in a space"],
    ["(boundary)", "accepted"],
    ["'()+_,-./:=? 0123456789AZaz", "accepted"],
    ["line\rbreak", "invalid character in multipart boundary"],
    ["line\nbreak", "invalid character in multipart boundary"],
    ["tab\there", "invalid character in multipart boundary"],
  ])
}

///|
// Header syntax follows RFC 5322 section 3.6.8 (field-name), rather than the
// narrower HTTP token alphabet. Bare CR/LF cannot introduce new MIME headers.
// https://www.rfc-editor.org/rfc/rfc5322#section-3.6.8
async test "writer validates headers before emitting a part" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let writer = @multipart.Writer(sink, boundary="headers")
  let errors : Array[String] = []
  for
    (name, value) in [
      ("", "empty"),
      ("bad name", "space"),
      ("bad:name", "colon"),
      ("é", "non-ASCII name"),
      ("X-Value", "one\r\nInjected: two"),
      ("X-Value", "nul\u0000"),
      ("X-Value", "del\u007f"),
    ] {
    let headers : @http.Headers = Map([
      (@http.CaseInsensitiveString(name), value),
    ])
    try writer.write_part(headers~, _ => ()) catch {
      @multipart.MultipartError(message) => errors.push(message)
      error => raise error
    } noraise {
      _ => fail("invalid header was accepted")
    }
  }
  assert_eq(sink.bytes.length(), 0)
  writer.write_part(headers={ "X(Extension)": "tab\tand UTF-8 中文" }, _ => ())
  writer.finish()
  json_inspect((errors, @utf8.decode(sink.bytes.to_bytes())), content=[
    [
      "multipart header name is empty", "invalid multipart header name", "invalid multipart header name",
      "invalid multipart header name", "invalid control character in multipart header",
      "invalid control character in multipart header", "invalid control character in multipart header",
    ],
    "--headers\r\nX(Extension): tab\tand UTF-8 中文\r\n\r\n\r\n--headers--\r\n",
  ])
}

///|
priv suberror WriteFailure {
  CallbackFailed
  TargetFailed
  SourceFailed
} derive(Debug)

///|
priv struct FailingSink {}

///|
impl @io.Writer for FailingSink with fn write_once(_self, _bytes, offset~, len~) {
  ignore(offset)
  ignore(len)
  raise TargetFailed
}

///|
async test "writer streams during callback and propagates failures" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let writer = @multipart.Writer(sink, boundary="stream")
  let observed = StringBuilder()
  try
    writer.write_part(headers={}, target => {
      target.write("first")
      observed.write_string(@utf8.decode(sink.bytes.to_bytes()))
      target.write("second")
      raise CallbackFailed
    })
  catch {
    CallbackFailed => ()
    error => raise error
  } noraise {
    _ => fail("callback failure was lost")
  }
  json_inspect((observed.to_string(), @utf8.decode(sink.bytes.to_bytes())), content=[
    "--stream\r\n\r\nfirst", "--stream\r\n\r\nfirstsecond",
  ])
  let failing = @multipart.Writer(FailingSink::{ }, boundary="stream")
  try failing.write_part(headers={}, _ => fail("unreachable callback")) catch {
    TargetFailed => ()
    error => raise error
  } noraise {
    _ => fail("target failure was lost")
  }
}

///|
async test "writer finishes an empty multipart and rejects further parts" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let writer = @multipart.Writer(sink, boundary="empty")
  writer.finish()
  writer.finish()
  try writer.write_part(headers={}, _ => ()) catch {
    @multipart.MultipartError(message) =>
      inspect(
        message,
        content=(
          #|multipart writer is finished
        ),
      )
    error => raise error
  } noraise {
    _ => fail("finished writer accepted another part")
  }
  inspect(
    sink.bytes.to_bytes(),
    content=(
      #|b"--empty--\x0d\x0a"
    ),
  )
}
