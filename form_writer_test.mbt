///|
// RFC 7578 sections 4.2–4.4 and 5.2: optional filenames, MIME content types,
// and repeated field names. JSON is this API's explicitly typed convenience.
// https://www.rfc-editor.org/rfc/rfc7578#section-4.2
async test "form writer writes fields, JSON, named and unnamed files in order" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let form = @multipart.FormWriter(sink, boundary="BOUNDARY")
  form.write_field("field", "one\ntwo\rthree\r\nfour")
  form.write_json("metadata", { "answer": 42, "label": "中文" })
  let named_file = @io.MemoryReader(target => target.write(b"a\x00b\r\n"))
  defer named_file.close()
  form.write_file(
    "files",
    filename="one.txt",
    content_type="text/plain",
    named_file,
  )
  let unnamed_file = @io.MemoryReader(target => target.write("unnamed"))
  defer unnamed_file.close()
  form.write_file("files", unnamed_file)
  form.write_part(
    headers={ "Content-Disposition": "form-data; name=\"custom\"" },
    target => target.write("custom body"),
  )
  form.finish()
  assert_eq(form.content_type(), "multipart/form-data; boundary=BOUNDARY")
  json_inspect(
    @utf8.decode(sink.bytes.to_bytes()),
    content="--BOUNDARY\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\none\ntwo\rthree\r\nfour\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{\"answer\":42,\"label\":\"中文\"}\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"files\"; filename=\"one.txt\"\r\nContent-Type: text/plain\r\n\r\na\u0000b\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"files\"\r\nContent-Type: application/octet-stream\r\n\r\nunnamed\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"custom\"\r\n\r\ncustom body\r\n--BOUNDARY--\r\n",
  )
}

///|
async test "form writer generates a 192-bit hex boundary by default" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let form = @multipart.FormWriter(sink)
  form.write_field("field", "value")
  form.finish()
  assert_eq(form.boundary().length(), 48)
  assert_eq(
    form.content_type(),
    "multipart/form-data; boundary=\{form.boundary()}",
  )
  let wire = @utf8.decode(sink.bytes.to_bytes())
  assert_true(
    wire.contains(
      "--\{form.boundary()}\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue\r\n--\{form.boundary()}--\r\n",
    ),
  )
}

///|
// RFC 2046 section 5.1.1: boundary values containing MIME tspecials or spaces
// must be quoted in Content-Type, but the delimiters use the original value.
// https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1
async test "form writer quotes special boundary characters in Content-Type" {
  for
    (boundary, parameter) in [
      ("abcXYZ012'+_-.", "abcXYZ012'+_-."),
      ("simple boundary", "\"simple boundary\""),
      (" leading", "\" leading\""),
      ("abc(def)", "\"abc(def)\""),
      ("a(b", "\"a(b\""),
      ("a)b", "\"a)b\""),
      ("a,b", "\"a,b\""),
      ("a/b", "\"a/b\""),
      ("a:b", "\"a:b\""),
      ("a=b", "\"a=b\""),
      ("a?b", "\"a?b\""),
    ] {
    let sink = ByteSink::{ bytes: @buffer.Buffer(), }
    let form = @multipart.FormWriter(sink, boundary~)
    assert_eq(form.boundary(), boundary)
    assert_eq(form.content_type(), "multipart/form-data; boundary=\{parameter}")
    let (media_type, parameters) = @multipart.parse_header_value(
      form.content_type(),
    )
    assert_eq(media_type, "multipart/form-data")
    assert_eq(parameters.get("boundary"), Some(boundary))
    form.write_field("field", "value")
    form.finish()
    assert_eq(
      @utf8.decode(sink.bytes.to_bytes()),
      "--\{boundary}\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue\r\n--\{boundary}--\r\n",
    )
  }
}

///|
// Adapted from Go TestFileContentDisposition (quotes, backslashes, CR/LF),
// plus RFC 7578 section 5.1 UTF-8 names and filenames.
// https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/writer_test.go
// https://www.rfc-editor.org/rfc/rfc7578#section-5.1
async test "form writer escapes MIME disposition parameters" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let form = @multipart.FormWriter(sink, boundary="BOUNDARY")
  for
    (name, filename) in [
      ("somefield", "somefile.txt"),
      ("field\"withquotes\"", "somefile.txt"),
      ("somefield", "somefile\"withquotes\".txt"),
      ("somefield\\withbackslash", "somefile.txt"),
      ("somefield", "somefile\\withbackslash.txt"),
      ("a\rb\nc", "e\rf\ng"),
      ("字段", "文件.txt"),
      ("", ""),
    ] {
    let file = @io.MemoryReader(_ => ())
    defer file.close()
    form.write_file(name, filename~, file)
  }
  form.finish()
  json_inspect(
    @utf8.decode(sink.bytes.to_bytes()),
    content="--BOUNDARY\r\nContent-Disposition: form-data; name=\"somefield\"; filename=\"somefile.txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"field\\\"withquotes\\\"\"; filename=\"somefile.txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"somefield\"; filename=\"somefile\\\"withquotes\\\".txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"somefield\\\\withbackslash\"; filename=\"somefile.txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"somefield\"; filename=\"somefile\\\\withbackslash.txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"a%0Db%0Ac\"; filename=\"e%0Df%0Ag\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"字段\"; filename=\"文件.txt\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--BOUNDARY--\r\n",
  )
}

///|
// A pull-driven source observes writes before the next read. Implementing
// io.Reader requires the internal ReaderBuffer in async@0.21.3.
#warnings("-alert_internal")
priv struct StreamingFile {
  sink : ByteSink
  buffer : @io.ReaderBuffer
  mut emitted : Bool
}

///|
impl @io.Reader for StreamingFile with fn _get_internal_buffer(self) {
  self.buffer
}

///|
impl @io.Reader for StreamingFile with fn _direct_read(
  self,
  target,
  offset~,
  max_len~,
) {
  assert_true(max_len > 0)
  if self.emitted {
    // Reading ahead before writing the previous chunk would fail this check.
    assert_true(self.sink.bytes.to_bytes().has_suffix(b"x"))
    raise SourceFailed
  }
  assert_true(self.sink.bytes.to_bytes().has_suffix(b"\r\n\r\n"))
  target[offset] = b'x'
  self.emitted = true
  1
}

///|
#warnings("-alert_internal")
async test "form writer streams each file chunk before requesting the next" {
  let sink = ByteSink::{ bytes: @buffer.Buffer(), }
  let form = @multipart.FormWriter(sink, boundary="BOUNDARY")
  let file = StreamingFile::{
    sink,
    buffer: @io.ReaderBuffer::new(),
    emitted: false,
  }
  try form.write_file("file", file) catch {
    SourceFailed => ()
    error => raise error
  } noraise {
    _ => fail("file reader failure was lost")
  }
  json_inspect(
    @utf8.decode(sink.bytes.to_bytes()),
    content="--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\nx",
  )
}
