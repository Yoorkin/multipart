///|
async test "header values share MIME parameter syntax" (t : @test.Test) {
  // Content-Type syntax and quoted boundary examples:
  // https://www.rfc-editor.org/rfc/rfc2045.html#section-5.1
  // https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1
  // Content-Disposition tokens, quoted dates, and quoted-pair parameters:
  // https://www.rfc-editor.org/rfc/rfc2183.html#section-2
  for
    (title, value) in [
      ("charset token", "text/plain; charset=us-ascii"),
      (
        "comments around type and subtype", " (leading (nested)) Text (type) / (subtype) Plain ; CHARSET = \"UTF-8\" (end) ",
      ),
      ("quoted boundary", "multipart/mixed; boundary=\"gc0pJq0M:08jU534c0p\""),
      ("no parameters", "application/octet-stream"),
      ("single token", "INLINE"),
      (
        "attachment date", "attachment; filename=genome.jpeg; modification-date=\"Wed, 12 Feb 1997 16:29:51 -0500\"",
      ),
      (
        "quoted pairs and literal escapes", "attachment; filename=\"a\\\"b\\\\c%20.txt\"; filename*=UTF-8''caf%C3%A9.txt",
      ),
    ] {
    let (kind, parameters) = @multipart.parse_header_value(value)
    t.writeln(Repr((title, kind, parameters.to_json())))
  }
  // RFC 1867 §6: use the parsed Content-Type boundary to read a form body.
  // https://www.rfc-editor.org/rfc/rfc1867.html#section-6
  let (kind, parameters) = @multipart.parse_header_value(
    "multipart/form-data; BOUNDARY=\"AaB03x\"",
  )
  guard parameters.get("boundary") is Some(boundary) else {
    fail("missing boundary through case-insensitive lookup")
  }
  let source = @io.MemoryReader(writer => {
    writer.write(
      "--AaB03x\r\nContent-Disposition: form-data; name=\"field1\"\r\n\r\nJoe Blow\r\n--AaB03x--\r\n",
    )
  })
  defer source.close()
  let form = @multipart.Form(source, boundary~)
  guard form.next_part() is Some(part) else { fail("missing form part") }
  t.writeln(
    Repr((kind, part.name(), part.read_all().text(), form.next_part() is None)),
  )
  t.snapshot(filename="header_values.txt")
}

///|
test "header values reject malformed MIME syntax" (t : @test.Test) {
  // Mutations of RFC 2045 §5.1's type/subtype and token productions.
  // Control characters cannot enter parameters or comments through this API;
  // field unfolding belongs to Reader, before parsing a header value.
  // https://www.rfc-editor.org/rfc/rfc2045.html#section-5.1
  for
    (title, value) in [
      ("empty value", ""),
      ("missing type", "/plain"),
      ("missing subtype", "text/"),
      ("double slash", "text//plain"),
      ("extra subtype", "text/plain/extra"),
      ("missing slash", "text plain"),
      ("slash in unquoted parameter", "text/plain; name=a/b"),
      ("duplicate charset", "text/plain; charset=UTF-8; CHARSET=us-ascii"),
      ("quoted control", "text/plain; name=\"bad\u0000value\""),
      ("escaped control", "attachment; filename=\"bad\\\u007fvalue\""),
      ("comment control", "text/plain (bad\u0000comment)"),
      ("raw folding", "text/plain;\r\n charset=UTF-8"),
    ] {
    try @multipart.parse_header_value(value) catch {
      @multipart.MultipartError(message) => t.writeln("\{title}: \{message}")
    } noraise {
      _ => fail("accepted malformed header value: \{title}")
    }
  }
  t.snapshot(filename="header_invalid_values.txt")
}
