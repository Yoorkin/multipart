///|
struct FormWriter {
  writer : Writer
}

///|
/// Create a form writer. The boundary defaults to 192 bits of platform
/// entropy, so that it cannot occur in the part bodies (RFC 2046 section
/// 5.1.1). Pass one explicitly when the platform cannot provide secure
/// randomness, or when the wire bytes must be reproducible; in that case it is
/// the caller's responsibility that no part body contains it.
pub fn FormWriter::FormWriter(
  target : &@io.Writer,
  boundary? : String,
) -> Self raise MultipartError {
  let boundary = match boundary {
    Some(explicit) => explicit
    None => {
      guard @env.rand(24) is Some(bytes) else {
        raise MultipartError(
          "secure randomness is unavailable for multipart boundary",
        )
      }
      @hex.encode(bytes)
    }
  }
  { writer: Writer(target, boundary~), }
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
fn form_content_disposition(name : String, filename? : String) -> String {
  fn quote(value : String) -> String {
    value
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
    .replace_all(old="\r", new="%0D")
    .replace_all(old="\n", new="%0A")
  }

  let disposition = "form-data; name=\"\{quote(name)}\""
  if filename is Some(filename) {
    disposition + "; filename=\"\{quote(filename)}\""
  } else {
    disposition
  }
}
