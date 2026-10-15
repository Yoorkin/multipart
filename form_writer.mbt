///|
struct FormWriter {
  writer : Writer
}

///|
/// Create a form writer with a boundary containing 192 bits of platform entropy.
pub fn FormWriter::FormWriter(
  target : &@io.Writer,
) -> Self raise MultipartError {
  guard @env.rand(24) is Some(bytes) else {
    raise MultipartError(
      "secure randomness is unavailable for multipart boundary",
    )
  }
  { writer: Writer(target, boundary=@hex.encode(bytes)), }
}

///|
/// The generated boundary, for constructing a matching reader or MIME header.
pub fn FormWriter::boundary(self : Self) -> String {
  self.writer.boundary
}

///|
/// The HTTP Content-Type for the generated form body.
pub fn FormWriter::content_type(self : Self) -> String {
  "multipart/form-data; boundary=\{self.writer.boundary}"
}

///|
/// Write a part with caller-supplied MIME headers.
pub async fn FormWriter::write_part(
  self : Self,
  headers~ : @http.Headers,
  callback : Callback,
) -> Unit {
  self.writer.write_part(headers~, callback)
}

///|
/// Write a UTF-8 text field, preserving the value's line endings.
pub async fn FormWriter::write_field(
  self : Self,
  name : String,
  value : String,
) -> Unit {
  let headers : @http.Headers = {
    "Content-Disposition": form_content_disposition(name),
  }
  self.write_part(headers~, target => target.write(value))
}

///|
/// Write a JSON field with Content-Type application/json.
pub async fn FormWriter::write_json(
  self : Self,
  name : String,
  value : Json,
) -> Unit {
  let headers : @http.Headers = {
    "Content-Disposition": form_content_disposition(name),
    "Content-Type": "application/json",
  }
  self.write_part(headers~, target => target.write(value))
}

///|
/// Stream a file without closing its reader. An unspecified content type uses
/// application/octet-stream; filename is optional (RFC 7578 sections 4.2–4.4).
pub async fn FormWriter::write_file(
  self : Self,
  name : String,
  filename? : String,
  content_type? : String,
  file : &@io.Reader,
) -> Unit {
  let headers : @http.Headers = {
    "Content-Disposition": form_content_disposition(name, filename?),
    "Content-Type": content_type.unwrap_or("application/octet-stream"),
  }
  self.writer.write_reader(headers~, file)
}

///|
pub async fn FormWriter::finish(self : Self) -> Unit {
  self.writer.finish()
}

///|
// MIME quoted-pair escaping preserves literal backslashes and quotes. CR/LF
// uses RFC 7578 section 2 percent encoding, as in Go's FileContentDisposition.
// One pass over the value, so no rule can feed another; the quoted-string
// decoder in parser.mbt is the other half of the quoted-pair rule. The
// disposition is assembled in one StringBuilder, so nothing is concatenated
// or copied through a per-field intermediate String.
fn form_content_disposition(name : String, filename? : String) -> String {
  fn write_quoted(out : StringBuilder, value : String) -> Unit {
    for ch in value {
      match ch {
        '\\' => out.write_string("\\\\")
        '"' => out.write_string("\\\"")
        '\r' => out.write_string("%0D")
        '\n' => out.write_string("%0A")
        _ => out.write_char(ch)
      }
    }
  }

  let disposition = StringBuilder()
  disposition.write_string("form-data; name=\"")
  write_quoted(disposition, name)
  disposition.write_char('"')
  if filename is Some(filename) {
    disposition.write_string("; filename=\"")
    write_quoted(disposition, filename)
    disposition.write_char('"')
  }
  disposition.to_string()
}
