///|
/// A byte source with controllable transport fragmentation and a live-stream gate.
// Direct reads are needed to observe read-ahead; async@0.21.3 requires ReaderBuffer.
#warnings("-alert_internal")
struct FixtureReader {
  data : Bytes
  buffer : @io.ReaderBuffer
  chunk : Int32
  split : Int32
  mut offset : Int32
  mut available : Int32
  mut eof : Bool
}

///|
#warnings("-alert_internal")
fn FixtureReader::FixtureReader(
  data : Bytes,
  chunk~ : Int32 = 8192,
  split~ : Int32 = 0,
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
  let mut size = Int32::min(
    Int32::min(max_len, self.chunk),
    self.available - self.offset,
  )
  if self.offset < self.split {
    size = Int32::min(size, self.split - self.offset)
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
    let data = fixture_bytes(name)
    let expected = read_fixture_parts(FixtureReader(data), boundary)
    t.writeln(name)
    for (headers, body) in expected {
      t.writeln("  headers: \{Json(headers).stringify()}")
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
  let data = fixture_bytes("rfc5322-folding")
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
      "before_delimiter": Json(before_delimiter.map(Bytes::to_string)),
      "eof_before_next_headers": Json(eof_before_next_headers),
      "old_part_eof": Json(first.read_some() is None),
      "second_prefix": Json(Bytes::from_array(byte[:]).to_string()),
      "skipped_part_eof": Json(second.read_some() is None),
      "third_body": Json(third.read_all().text()),
      "finished": Json(reader.next_part() is None),
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
  let data = fixture_bytes("rfc2046-simple")
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
      "first_prefix": Json(prefix),
      "retained_first": Json(old_part.to_string()),
      "second": Json(rest.to_string()),
      "finished": Json(reader.next_part() is None),
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
      "preamble_bytes": Json(preamble.length()),
      "padding_bytes": Json(padding.length()),
      "body_bytes": Json(actual.length()),
      "skipped_bytes": Json(skipped_body.length() - 3),
      "skipped_prefix": Json(skipped_prefix.to_string()),
      "retained_eof": Json(skipped.read_some() is None),
      "last_headers": Json(headers),
      "last_body": Json(last.read_all().text()),
      "finished": Json(reader.next_part() is None),
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
    let data = fixture_bytes(name)
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
  let data = fixture_bytes("rfc2046-nested")
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
      "nested_headers": Json(headers),
      "nested_body": Json(nested_body),
      "following": Json(following.read_all().text()),
      "outer_finished": Json(outer.next_part() is None),
    },
    content={
      "nested_headers": { "Content-Type": "text/plain" },
      "nested_body": "nested",
      "following": "after",
      "outer_finished": true,
    },
  )
}

///|
// Raw bytes from fixtures/*.mime, including CRLF, NUL, and invalid UTF-8.
fn fixture_bytes(name : String) -> Bytes raise {
  match name {
    "actix-empty-multipart" => b"--a--\r\n"
    "actix-short-boundary" =>
      b"\n-\r\n--a\r\nContent-Type: text/plain\r\n\r\none\r\n--a\r\nContent-Type: text/plain\r\n\r\ntwo\r\n--a--\r\n"
    "bare-lf-framing" => b"--bad\nX-Id: value\n\nbody\n--bad--\n"
    "body-truncated" => b"--bad\r\n\r\nbody\r\n--bad-"
    "close-invalid-suffix" => b"--bad\r\n\r\nbody\r\n--bad--X"
    "delimiter-invalid-crlf" => b"--bad\r\n\r\nbody\r\n--bad\rX\r\n--bad--"
    "delimiter-invalid-padding" => b"--bad\r\n\r\nbody\r\n--bad \tX\r\n--bad--"
    "go-boundary-prefixes" =>
      b"--prefix\r\n\r\n--prefixX\r\n--prefix-\r\n--prefix_suffix\r\n--prefix\r\n\r\n--prefix-\r\npayload\r\n--prefix--"
    "header-bare-lf" =>
      b"--bad\r\nX-Id: value\nOther: value\r\n\r\nbody\r\n--bad--"
    "header-empty-name" => b"--bad\r\n: value\r\n\r\nbody\r\n--bad--"
    "header-invalid-utf8" => b"--bad\r\nX-Id: value\xff\r\n\r\nbody\r\n--bad--"
    "header-nul" => b"--bad\r\nX-Id: val\x00ue\r\n\r\nbody\r\n--bad--"
    "header-orphan-fold" => b"--bad\r\n\torphan\r\n\r\nbody\r\n--bad--"
    "header-space-in-name" => b"--bad\r\nBad Name: value\r\n\r\nbody\r\n--bad--"
    "header-truncated" => b"--bad\r\nX-Id: value\r"
    "header-without-colon" => b"--bad\r\nInvalid header\r\n\r\nbody\r\n--bad--"
    "missing-first" => b"just a preamble\r\n"
    "rfc2046-binary" =>
      b"--binary\r\nContent-Type: application/octet-stream\r\n\r\n\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\x7f\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff\r\n--binary--\r\n"
    "rfc2046-body-lines" =>
      b"--lines\r\n\r\nprefix--lines\r\n--line\r\n--LINES\rbare\nline\r\n\r\n--lines--"
    "rfc2046-compact-empty" =>
      b"--compact\r\nX-Id: first\r\n\r\n--compact\r\n\r\n--compact--"
    "rfc2046-empty" =>
      b"--empty\r\n\r\n\r\n--empty\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--empty--\r\n"
    "rfc2046-nested" =>
      b"--outer\r\nContent-Type: multipart/mixed; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nnested\r\n--inner--\r\n\r\n--outer\r\n\r\nafter\r\n--outer--"
    "rfc2046-padding" =>
      b"--pad \t\r\nX-Id: first\r\n\r\none\r\n--pad\t \r\nX-Id: second\r\n\r\ntwo\r\n--pad-- \t"
    "rfc2046-simple" =>
      b"Preamble ignored.\r\n\r\n--simple boundary\r\n\r\nimplicit\r\n--simple boundary\r\nContent-Type: text/plain; charset=us-ascii\r\n\r\nexplicit\r\n\r\n--simple boundary--\r\nEpilogue ignored.\r\n"
    "rfc5322-folding" =>
      b"--fold\r\ncOnTeNt-TyPe: text/plain;\r\n\tcharset=us-ascii\r\nX-Note:\tfirst\r\n second\t \r\nx-note:\tthird \t\r\n\tfourth  \r\nX-Tail: final\t \r\n\r\nfolded\r\n--fold--"
    "rfc7578-raw-encoding" =>
      b"--raw\r\nContent-Disposition: form-data; name=\"amount\"\r\nContent-Type: text/plain; charset=ISO-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\namount=3D=A3\r\n--raw--"
    _ => fail("unknown fixture: \{name}")
  }
}
