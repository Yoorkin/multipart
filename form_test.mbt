///|
async test "form fixtures from RFC 1867 and RFC 7578" (t : @test.Test) {
  // RFC 1867 §6's single-file example, with CRLF restored from its printed form.
  // https://www.rfc-editor.org/rfc/rfc1867.html#section-6
  // RFC 7578 §4.5's transfer-encoded example, completed with a closing boundary.
  // https://www.rfc-editor.org/rfc/rfc7578.html#section-4.5
  for
    (title, wire) in [
      (
        "RFC 1867 single file", "--AaB03x\r\ncontent-disposition: form-data; name=\"field1\"\r\n\r\nJoe Blow\r\n--AaB03x\r\ncontent-disposition: form-data; name=\"pics\"; filename=\"file1.txt\"\r\nContent-Type: text/plain\r\n\r\n... contents of file1.txt ...\r\n--AaB03x--\r\n",
      ),
      (
        "RFC 7578 transfer encoding stays raw", "--AaB03x\r\ncontent-disposition: form-data; name=\"field1\"\r\ncontent-type: text/plain;charset=UTF-8\r\ncontent-transfer-encoding: quoted-printable\r\n\r\nJoe owes =E2=82=AC100.\r\n--AaB03x--\r\n",
      ),
      // RFC 7578 §§4.3, 5.2 require repeated file names to remain ordered parts.
      (
        "RFC 7578 repeated field names", "--AaB03x\r\nContent-Disposition: form-data; name=files; filename=one.txt\r\n\r\none\r\n--AaB03x\r\nContent-Disposition: form-data; name=files; filename=two.txt\r\nContent-Type: application/octet-stream\r\n\r\ntwo\r\n--AaB03x--\r\n",
      ),
      // RFC 7578 §4.6: expose the charset field and bytes without applying an
      // implicit text decoder. The API returns io.Reader, not decoded values.
      (
        "RFC 7578 charset field remains a part", "--AaB03x\r\nContent-Disposition: form-data; name=_charset_\r\n\r\nUTF-8\r\n--AaB03x\r\nContent-Disposition: form-data; name=message\r\n\r\n月亮🌙\r\n--AaB03x--\r\n",
      ),
    ] {
    t.writeln(title)
    let source = @io.MemoryReader(writer => writer.write(wire))
    defer source.close()
    let form = @multipart.Form(source, boundary="AaB03x")
    while form.next_part() is Some(part) {
      t.writeln(
        Repr(
          (
            part.name(),
            part.filename(),
            part.content_type(),
            part.headers().get("Content-Transfer-Encoding"),
            part.read_all().text(),
          ),
        ),
      )
    }
  }
  t.snapshot(filename="form_rfc_examples.txt")
}

///|
async test "form disposition grammar and metadata" (t : @test.Test) {
  // Derived from RFC 2183 §2 and RFC 2045 §5.1's normative parameter grammar:
  // https://www.rfc-editor.org/rfc/rfc2183.html#section-2
  // https://www.rfc-editor.org/rfc/rfc2045.html#section-5.1
  // Unicode and literal percent escapes: RFC 7578 §§2, 4.2, 5.1.2.
  for
    disposition in [
      "FoRm-DaTa; NaMe=MixedCase; FiLeNaMe=Report.TXT", "form-data; name=\"semi;colon\"; filename=\"a\\\"b\\\\c.txt\"",
      "(outer (nested)) form-data (kind); name (field) = (before) \"value\" (after)",
      "form-data (escaped \\) parenthesis); name=field", "form-data; name=\"\"; filename=\"\"",
      "form-data; name=\"字段🌙\"; filename=\"报告🌙.txt\"", "form-data; name=upload; filename=\"100%20done.txt\"",
      "form-data; name=upload; filename=\"../../a.txt\"", "form-data; name=upload; filename=\"C:\\\\tmp\\\\a.txt\"",
      "form-data; name=upload; ignored=\"x;y\"; filename*=UTF-8''ignored.txt", "form-data;\r\n\tname=folded;\r\n filename=folded.txt",
      // RFC 5322 §2.2.3 unfolds by removing CRLF, preserving surrounding WSP.
      // https://www.rfc-editor.org/rfc/rfc5322.html#section-2.2.3
       "form-data; name=\"a \r\n b\"", "form-data; name=\"a \r\n b \r\n c\"; filename=\"x\t\r\n y\"",
      // multer v3.1.0 test_content_distribution_misordered_fields:
      // both parameter orders yield name "file" and filename "file-name.txt".
      // https://github.com/rwf2/multer/blob/09cc7300c9bb7b3bbb30776e87ce14d2bd85588f/src/constants.rs#L150-L169
       "form-data; filename=file-name.txt; name=file", "form-data; filename=\"file-name.txt\"; name=\"file\"",
      // multer #72 reproducers: quoted parameter contents cannot override the
      // real filename "safe.txt" or name "realName".
      // https://github.com/rwf2/multer/issues/72
       "form-data; name=\"upload\"; note=\"x; filename=evil.exe \"; filename=\"safe.txt\"",
      "form-data; note=\"x; name=fakeName \"; name=\"realName\"",
    ] {
    let wire = "--boundary\r\nContent-Disposition: \{disposition}\r\nX-Extension: kept\r\n\r\npayload\r\n--boundary--\r\n"
    let source = @io.MemoryReader(writer => writer.write(wire))
    defer source.close()
    let form = @multipart.Form(source, boundary="boundary")
    guard form.next_part() is Some(part) else { fail("missing fixture part") }
    t.writeln(
      Repr(
        (
          part.name(),
          part.filename(),
          part.content_type(),
          part.headers().get("X-Extension"),
          part.read_all().text(),
        ),
      ),
    )
  }
  t.snapshot(filename="form_disposition.txt")
}

///|
async test "invalid form dispositions fail before returning a part" (
  t : @test.Test,
) {
  // Mutations of RFC 7578 §4.2's required form-data/name fields and the
  // token/quoted-string productions in RFC 2045 §5.1 and RFC 2183 §2.
  for
    (title, header) in [
      ("missing disposition", ""),
      ("wrong disposition", "Content-Disposition: attachment; name=field\r\n"),
      ("missing name", "Content-Disposition: form-data; filename=a.txt\r\n"),
      ("empty token", "Content-Disposition: form-data; name=\r\n"),
      ("unterminated quote", "Content-Disposition: form-data; name=\"field\r\n"),
      ("dangling escape", "Content-Disposition: form-data; name=\"field\\\r\n"),
      (
        "unquoted special", "Content-Disposition: form-data; name=field; filename=a/b\r\n",
      ),
      ("missing equals", "Content-Disposition: form-data; name field\r\n"),
      (
        "duplicate name", "Content-Disposition: form-data; name=one; NAME=two\r\n",
      ),
      (
        "trailing junk", "Content-Disposition: form-data; name=\"field\"junk\r\n",
      ),
      (
        "unterminated comment", "Content-Disposition: form-data; name=field (unfinished\r\n",
      ),
      ("trailing separator", "Content-Disposition: form-data; name=field;\r\n"),
    ] {
    let source = @io.MemoryReader(writer => {
      writer.write("--boundary\r\n\{header}\r\npayload\r\n--boundary--\r\n")
    })
    defer source.close()
    let form = @multipart.Form(source, boundary="boundary")
    try form.next_part() catch {
      @multipart.MultipartError(message) => t.writeln("\{title}: \{message}")
      error => raise error
    } noraise {
      _ => fail("accepted invalid fixture: \{title}")
    }
  }
  t.snapshot(filename="form_invalid_disposition.txt")
}

///|
async test "form part forwards buffered reader operations" (t : @test.Test) {
  let source = @io.MemoryReader(writer => {
    writer.write(
      "--boundary\r\nContent-Disposition: form-data; name=first\r\n\r\nfirst payload\r\n--boundary\r\nContent-Disposition: form-data; name=second\r\n\r\nsecond payload\r\n--boundary--\r\n",
    )
  })
  defer source.close()
  let form = @multipart.Form(source, boundary="boundary")
  guard form.next_part() is Some(first) else { fail("missing first part") }
  t.writeln(Repr(first.read_exactly(2)))
  t.writeln(Repr(first.read_until(" ")))
  // Advance with the first body only partly consumed, then mix Reader methods
  // again to exercise FormPart's shared internal buffer and direct-read path.
  guard form.next_part() is Some(second) else { fail("missing second part") }
  t.writeln(second.name())
  t.writeln(Repr(second.read_exactly(3)))
  t.writeln(second.read_all().text())
  t.writeln(Repr(form.next_part() is None))
  t.snapshot(filename="form_streaming.txt")
}
