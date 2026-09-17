///|
/// A byte source with controllable transport fragmentation and a live-stream gate.
// Direct reads are needed to observe read-ahead; async@0.21.3 requires ReaderBuffer.
#warnings("-alert_internal")
struct FixtureReader {
  data : Bytes
  buffer : @io.ReaderBuffer
  chunk : Int
  split : Int
  mut offset : Int
  mut available : Int
  mut eof : Bool
}

///|
#warnings("-alert_internal")
fn FixtureReader::FixtureReader(
  data : Bytes,
  chunk? : Int = 8192,
  split? : Int = 0,
) -> Self {
  {
    data,
    buffer: @io.ReaderBuffer::new(),
    chunk,
    split,
    offset: 0,
    available: data.length(),
    eof: false,
  }
}

///|
impl @io.Reader for FixtureReader with fn _get_internal_buffer(self) {
  self.buffer
}

///|
impl @io.Reader for FixtureReader with fn _direct_read(
  self,
  target,
  offset~,
  max_len~,
) {
  if self.offset == self.data.length() {
    // Go TestReadForm_NoReadAfterEOF: remember EOF instead of rereading source.
    // https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/formdata_test.go#L187-L220
    assert_true(!self.eof, msg="source was read again after EOF")
    self.eof = true
    return 0
  }
  if self.offset == self.available {
    fail("reader requested bytes that have not arrived")
  }
  let mut size = Int::min(
    Int::min(max_len, self.chunk),
    self.available - self.offset,
  )
  if self.offset < self.split {
    size = Int::min(size, self.split - self.offset)
  }
  target.blit_from_bytesview(offset, self.data[self.offset:self.offset + size])
  self.offset += size
  size
}

///|
async fn read_fixture_parts(
  source : &@io.Reader,
  boundary : String,
) -> Array[(@http.Headers, Bytes)] {
  let reader = @multipart.Reader(source, boundary~)
  let parts = []
  while reader.next_part() is Some((headers, body)) {
    parts.push((headers, body.read_all().binary()))
  }
  assert_true(reader.next_part() is None)
  parts
}

///|
async test "Reader specification fixtures and fragmented transport" (
  t : @test.Test,
) {
  for
    (name, boundary) in [
      ("rfc2046-simple", "simple boundary"),
      ("rfc2046-padding", "pad"),
      ("rfc2046-empty", "empty"),
      ("rfc2046-compact-empty", "compact"),
      ("rfc2046-nested", "outer"),
      ("rfc2046-binary", "binary"),
      ("rfc2046-body-lines", "lines"),
      ("rfc5322-folding", "fold"),
      ("rfc7578-raw-encoding", "raw"),
      ("go-boundary-prefixes", "prefix"),
      ("actix-short-boundary", "a"),
      ("actix-empty-multipart", "a"),
    ] {
    let data = @fs.read_file("fixtures/\{name}.mime").binary()
    let expected = read_fixture_parts(FixtureReader(data), boundary)
    t.writeln(name)
    for (headers, body) in expected {
      t.writeln("  headers: \{headers.to_json().stringify()}")
      t.writeln("  body: \{body}")
    }
    for chunk in [1, 2, 7, 31] {
      assert_eq(
        read_fixture_parts(FixtureReader(data, chunk~), boundary),
        expected,
      )
    }
  }
  t.snapshot(filename="reader-fixtures.txt")
}

///|
async test "Reader handles a transport split at every fixture byte" {
  let data = @fs.read_file("fixtures/rfc5322-folding.mime").binary()
  let expected = read_fixture_parts(FixtureReader(data), "fold")
  for split in 1..<data.length() {
    assert_eq(
      read_fixture_parts(FixtureReader(data, split~), "fold"),
      expected,
      msg="transport split at byte \{split}",
    )
  }
  json_inspect(
    { "split_positions": data.length() - 1, "parts": expected.length() },
    content={ "split_positions": 142, "parts": 1 },
  )
}

///|
// Go TestMultipartStreamReadahead (issue 15431), adapted to CRLF framing:
// https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/multipart_test.go#L349-L401
async test "Reader streams live parts without reading ahead into next headers" {
  let prefix = b"--live\r\n\r\nbody\r\n--li"
  let data = b"--live\r\n\r\nbody\r\n--live\r\n\r\nsecond\r\n--live\r\n\r\nthird\r\n--live--"
  let source = FixtureReader(data)
  source.available = prefix.length()
  let reader = @multipart.Reader(source, boundary="live")
  guard reader.next_part() is Some((_, first)) else {
    fail("missing first live part")
  }
  let before_delimiter = first.read_some()
  // Once the delimiter is complete, the first body must reach EOF even while
  // the next part's headers have not arrived.
  source.available = b"--live\r\n\r\nbody\r\n--live\r\n".length()
  let eof_before_next_headers = first.read_some() is None
  source.available = data.length()
  guard reader.next_part() is Some((_, second)) else {
    fail("missing second live part")
  }
  // A small direct read leaves ordinary body bytes available for next_part
  // to drain without allowing the retained reader into the following part.
  let byte = FixedArray::make(1, b'\x00')
  assert_eq(second.read(byte), 1)
  guard reader.next_part() is Some((_, third)) else {
    fail("missing third live part")
  }
  json_inspect(
    {
      "before_delimiter": before_delimiter.map(Bytes::to_string).to_json(),
      "eof_before_next_headers": eof_before_next_headers.to_json(),
      "old_part_eof": (first.read_some() is None).to_json(),
      "second_prefix": Bytes::from_array(byte[:]).to_string().to_json(),
      "skipped_part_eof": (second.read_some() is None).to_json(),
      "third_body": third.read_all().text().to_json(),
      "finished": (reader.next_part() is None).to_json(),
    },
    content={
      "before_delimiter": ["b\"body\""],
      "eof_before_next_headers": true,
      "old_part_eof": true,
      "second_prefix": "b\"s\"",
      "skipped_part_eof": true,
      "third_body": "third",
      "finished": true,
    },
  )
}

///|
async test "Reader drains unread parts and isolates retained readers" {
  let data = @fs.read_file("fixtures/rfc2046-simple.mime").binary()
  let reader = @multipart.Reader(
    FixtureReader(data),
    boundary="simple boundary",
  )
  guard reader.next_part() is Some((_, first)) else {
    fail("missing first part")
  }
  let prefix = first.read_until("p")
  guard reader.next_part() is Some((_, second)) else {
    fail("missing second part")
  }
  let old_part = first.read_all().binary()
  let rest = second.read_all().binary()
  json_inspect(
    {
      "first_prefix": prefix.to_json(),
      "retained_first": old_part.to_string().to_json(),
      "second": rest.to_string().to_json(),
      "finished": (reader.next_part() is None).to_json(),
    },
    content={
      "first_prefix": ["im"],
      "retained_first": "b\"\"",
      "second": "b\"explicit\\x0d\\x0a\"",
      "finished": true,
    },
  )
}

///|
// RFC 2046 §5.1.1: discard-text, OCTET bodies, and unbounded transport-padding.
// https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1
async test "Reader crosses buffer boundaries and drains large padded parts" {
  let preamble = b"p".repeat(3 * 8192 - 3)
  let padding = b" \t".repeat(8193)
  let prefix = preamble + b"\r\n--block" + padding + b"\r\nX-Id: first\r\n\r\n"
  // Both the initial and the first inner delimiter straddle an 8192-byte read.
  let body_len = 3 * 8192 - prefix.length() % 8192 - 3
  let body = b"\x00\xff0123456789ABCDEF\r\n".repeat(2000)[:body_len].to_owned()
  let skipped_body = body.repeat(2)
  let wire = prefix +
    body +
    b"\r\n--block" +
    padding +
    b"\r\nX-Id: skipped\r\n\r\n" +
    skipped_body +
    b"\r\n--block" +
    padding +
    b"\r\nX-Id: last\r\n\r\nfollowing" +
    b"\r\n--block--" +
    padding
  let source = FixtureReader(wire)
  let reader = @multipart.Reader(source, boundary="block")
  guard reader.next_part() is Some((_, first)) else {
    fail("missing first large part")
  }
  let target = FixedArray::make(19, b'~')
  let before_empty_read = source.offset
  assert_eq(first.read(target, offset=1, max_len=0), 0)
  assert_eq(source.offset, before_empty_read)
  assert_eq(Bytes::from_array(target[:]), b"~~~~~~~~~~~~~~~~~~~")
  let actual = @buffer.Buffer()
  for read_index = 0 {
    let max_len = if read_index % 2 == 0 { 1 } else { 17 }
    let count = first.read(target, offset=1, max_len~)
    assert_true(count <= max_len)
    assert_eq(target[0], b'~')
    assert_eq(target[18], b'~')
    if count == 0 {
      break
    }
    for byte in target[1:count + 1] {
      actual.write_byte(byte)
    }
    continue read_index + 1
  }
  assert_eq(actual.to_bytes(), body)
  guard reader.next_part() is Some((_, skipped)) else {
    fail("missing large part to skip")
  }
  let skipped_prefix = skipped.read_exactly(3)
  guard reader.next_part() is Some((headers, last)) else {
    fail("missing part after skipped body")
  }
  json_inspect(
    {
      "preamble_bytes": preamble.length().to_json(),
      "padding_bytes": padding.length().to_json(),
      "body_bytes": actual.length().to_json(),
      "skipped_bytes": (skipped_body.length() - 3).to_json(),
      "skipped_prefix": skipped_prefix.to_string().to_json(),
      "retained_eof": (skipped.read_some() is None).to_json(),
      "last_headers": headers.to_json(),
      "last_body": last.read_all().text().to_json(),
      "finished": (reader.next_part() is None).to_json(),
    },
    content={
      "preamble_bytes": 24573,
      "padding_bytes": 16386,
      "body_bytes": 24548,
      "skipped_bytes": 49093,
      "skipped_prefix": "b\"\\x00\\xff0\"",
      "retained_eof": true,
      "last_headers": { "X-Id": "last" },
      "last_body": "following",
      "finished": true,
    },
  )
}

///|
async test "Reader malformed fixtures" (t : @test.Test) {
  for
    name in [
      "missing-first", "bare-lf-framing", "header-without-colon", "header-empty-name",
      "header-space-in-name", "header-orphan-fold", "header-nul", "header-bare-lf",
      "header-truncated", "header-invalid-utf8", "body-truncated", "close-invalid-suffix",
      "delimiter-invalid-padding", "delimiter-invalid-crlf",
    ] {
    let data = @fs.read_file("fixtures/\{name}.mime").binary()
    for chunk in [1, 8192] {
      try read_fixture_parts(FixtureReader(data, chunk~), "bad") catch {
        @multipart.MultipartError(message) =>
          if chunk == 1 {
            t.writeln("\{name}: \{message}")
          }
        error => raise error
      } noraise {
        _ => fail("expected rejection of \{name}")
      }
    }
  }
  t.snapshot(filename="reader-errors.txt")
}

///|
async test "Reader detects every truncated prefix before the close delimiter" {
  let data = b"--cut\r\nX-Id: value\r\n\r\nbody\r\n--cut--"
  for cut in 0..<data.length() {
    try read_fixture_parts(FixtureReader(data[:cut].to_owned()), "cut") catch {
      @multipart.MultipartError(_) => ()
      error => raise error
    } noraise {
      _ => fail("truncated prefix at byte \{cut} was accepted")
    }
  }
  json_inspect({ "rejected_prefixes": data.length() }, content={
    "rejected_prefixes": 35,
  })
}

///|
async test "Reader composes over a nested multipart body" {
  let data = @fs.read_file("fixtures/rfc2046-nested.mime").binary()
  let outer = @multipart.Reader(FixtureReader(data, chunk=7), boundary="outer")
  guard outer.next_part() is Some((_, inner_source)) else {
    fail("missing multipart container")
  }
  let inner = @multipart.Reader(inner_source, boundary="inner")
  guard inner.next_part() is Some((headers, body)) else {
    fail("missing nested part")
  }
  let nested_body = body.read_all().text()
  assert_true(inner.next_part() is None)
  guard outer.next_part() is Some((_, following)) else {
    fail("missing part after multipart container")
  }
  json_inspect(
    {
      "nested_headers": headers.to_json(),
      "nested_body": nested_body.to_json(),
      "following": following.read_all().text().to_json(),
      "outer_finished": (outer.next_part() is None).to_json(),
    },
    content={
      "nested_headers": { "Content-Type": "text/plain" },
      "nested_body": "nested",
      "following": "after",
      "outer_finished": true,
    },
  )
}
