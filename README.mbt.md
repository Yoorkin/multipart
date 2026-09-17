# multipart

A streaming multipart reader/writer library integrated with `moonbitlang/async`.

`Reader`/`Writer` handle MIME multipart, `Form`/`FormWriter` handle
`multipart/form-data`. Part bodies are streamed as raw bytes.

## Examples

Upload a field and a file through an HTTP client:

```mbt nocheck
///|
async fn upload(client : @http.Client, file : &@io.Reader) -> @http.Response {
  let form = @multipart.FormWriter(client)
  client.request(Post, "/upload", extra_headers={
    "Content-Type": form.content_type(),
  })
  form.write_field("description", "Release archive")
  form.write_file("archive", filename="release.zip", file)
  form.finish()
  client.end_request()
}
```

Read an upload using the request's Content-Type and copy its `archive` part:

```mbt nocheck
///|
async fn receive_archive(
  source : &@io.Reader,
  target : &@io.Writer,
  content_type : String,
) -> Unit {
  let (media_type, parameters) = @multipart.parse_header_value(content_type)
  guard @http.CaseInsensitiveString(media_type) == "multipart/form-data" else {
    raise Failure("expected multipart/form-data")
  }
  guard parameters.get("boundary") is Some(boundary) else {
    raise Failure("missing multipart boundary")
  }
  let form = @multipart.Form(source, boundary~)
  while form.next_part() is Some(part) {
    if part.name() == "archive" {
      target.write_reader(part)
    }
  }
}
```

`next_part()` discards unread content from the previous part. Process parts
sequentially; `finish()` leaves the underlying writer open.

For other multipart subtypes, use `Reader`/`Writer` with your own headers:

```mbt nocheck
///|
async fn copy_parts(source : &@io.Reader, target : &@io.Writer) -> Unit {
  let reader = @multipart.Reader(source, boundary="incoming")
  let writer = @multipart.Writer(target, boundary="outgoing")
  while reader.next_part() is Some((headers, body)) {
    writer.write_reader(headers~, body)
  }
  writer.finish()
}
```

Choose an output boundary that does not occur in the content. FormWriter
creates a random boundary automatically.

## Tests

See [fixtures](fixtures/README.md) for specification sources and snapshot tests.
