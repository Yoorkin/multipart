///|
/// Performance benchmarks for the multipart reader/writer hot paths.
///
/// The build profile matters more than anything measured here: `moon test`
/// builds **debug** and `moon bench` builds **release**, and the two differ by
/// far more than any two rows below differ from each other. In this tree
/// `BytesView::find` over an 8 KiB chunk measures ~26 µs in debug and ~0.34 µs
/// in release, and a 4 MiB part reads at ~270 MiB/s in debug and ~4.8 GiB/s in
/// release. Always measure with `--release`:
///
/// ```sh
/// moon test  --release --target native
/// moon bench --release --target native
/// ```
///
/// The pipeline and scan benchmarks time themselves with
/// `@bench.monotonic_clock_*` rather than `@bench.T`, because `@bench.T::bench`
/// calls the closure in a loop and a pure call with invariant inputs can be
/// hoisted out of it. The loops below keep a dependency on their result, and
/// the search is fed a differently trimmed needle on every pass.
///
/// `BytesSource` hands out bytes straight from a `Bytes`, so the pipeline
/// numbers isolate multipart framing from the pipe/coroutine/syscall noise a
/// `MemoryReader` or socket source would add.
///

///|
/// A byte source with no syscalls and no coroutine hand-off.
#warnings("-alert_internal")
priv struct BytesSource {
  data : Bytes
  buffer : @io.ReaderBuffer
  mut offset : Int
}

///|
#warnings("-alert_internal")
fn BytesSource::BytesSource(data : Bytes) -> BytesSource {
  { data, buffer: @io.ReaderBuffer::new(), offset: 0, }
}

///|
#warnings("-alert_internal")
impl @io.Reader for BytesSource with fn _get_internal_buffer(self) {
  self.buffer
}

///|
impl @io.Reader for BytesSource with fn _direct_read(
  self,
  target,
  offset~,
  max_len~,
) {
  let remaining = self.data.length() - self.offset
  if remaining == 0 {
    return 0
  }
  let size = @cmp.minimum(remaining, max_len)
  target.blit_from_bytesview(offset, self.data[self.offset:self.offset + size])
  self.offset += size
  size
}

///|
/// A sink that counts bytes and keeps nothing.
priv struct NullSink {
  mut written : Int
}

///|
impl @io.Writer for NullSink with fn write_once(self, _bytes, offset~, len~) {
  ignore(offset)
  self.written += len
  len
}

///|
/// One `multipart/form-data` part with a `Content-Disposition` header.
fn one_part_wire(boundary : String, body : String) -> String {
  let out = StringBuilder()
  out.write_string(
    "--\{boundary}\r\nContent-Disposition: form-data; name=\"field\"\r\nContent-Type: application/octet-stream\r\n\r\n",
  )
  out.write_string(body)
  out.write_string("\r\n--\{boundary}--\r\n")
  out.to_string()
}

///|
fn many_parts_wire(boundary : String, count : Int) -> String {
  let out = StringBuilder()
  for i in 0..<count {
    out.write_string(
      "--\{boundary}\r\nContent-Disposition: form-data; name=\"f\{i}\"\r\n\r\n",
    )
    out.write_string("v\{i}")
    out.write_string("\r\n")
  }
  out.write_string("--\{boundary}--\r\n")
  out.to_string()
}

///|
/// Time `iters` calls of `f`, which returns `(bytes_processed, units)`.
/// The first two calls are warm-up and are not measured.
async fn time_case(
  label : String,
  mib : Double,
  iters : Int,
  f : async () -> (Int, Int),
) -> Unit {
  ignore(f())
  ignore(f())
  let start = @bench.monotonic_clock_start()
  let mut checksum = 0
  let mut units = 0
  for _ in 0..<iters {
    let (bytes, count) = f()
    checksum += bytes
    units += count
  }
  let elapsed = @bench.monotonic_clock_end(start)
  let per_call = elapsed / iters.to_double()
  let rate = if per_call > 0.0 { mib * 1000000.0 / per_call } else { 0.0 }
  let per_unit = if units > 0 {
    elapsed * 1000.0 / units.to_double()
  } else {
    0.0
  }
  println(
    "\{label}\n    \{per_call.to_int()} µs/call, \{per_unit.to_int()} ns/unit, \{rate.to_int()} MiB/s, checksum=\{checksum}",
  )
}

///|
async test "bench: multipart pipeline" {
  let boundary = "----bench"
  // Periodic ASCII at 1 / 4 / 16 MiB: no CR, no LF, no boundary.
  let body1 = "0123456789abcdef".repeat(65536)
  let body4 = "0123456789abcdef".repeat(262144)
  let body16 = "0123456789abcdef".repeat(1048576)
  // ~4 MiB with a CR every three bytes: stresses the delimiter scan.
  let cr_body = "a\rb".repeat(1398102)
  let body_bytes = @utf8.encode(body4)
  let wire1 = @utf8.encode(one_part_wire(boundary, body1))
  let plain_wire = @utf8.encode(one_part_wire(boundary, body4))
  let wire16 = @utf8.encode(one_part_wire(boundary, body16))
  let cr_wire = @utf8.encode(one_part_wire(boundary, cr_body))
  let many_count = 10000
  let many_wire = @utf8.encode(many_parts_wire(boundary, many_count))
  //
  // A: the floor — one read_all of 4 MiB through the async reader, no multipart.
  time_case("A baseline: read_all(4 MiB)", 4.0, 20, async fn() {
    let source = BytesSource::BytesSource(body_bytes)
    let n = @io.Reader::read_all(source).binary().length()
    (n, n)
  })
  // B / B1 / B16: framing + refill + the caller's read_all, at three sizes.
  time_case("B Reader: 1 part, read_all(4 MiB)", 4.0, 10, async fn() {
    let source = BytesSource::BytesSource(plain_wire)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some((_, body)) else { fail("no part") }
    let n = body.read_all().binary().length()
    guard reader.next_part() is None else { fail("extra part") }
    (n, n)
  })
  time_case("B1 Reader: 1 part, read_all(1 MiB)", 1.0, 10, async fn() {
    let source = BytesSource::BytesSource(wire1)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some((_, body)) else { fail("no part") }
    let n = body.read_all().binary().length()
    guard reader.next_part() is None else { fail("extra part") }
    (n, n)
  })
  time_case("B16 Reader: 1 part, read_all(16 MiB)", 16.0, 3, async fn() {
    let source = BytesSource::BytesSource(wire16)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some((_, body)) else { fail("no part") }
    let n = body.read_all().binary().length()
    guard reader.next_part() is None else { fail("extra part") }
    (n, n)
  })
  // B2: the same body read into one reusable buffer, so only the reader differs.
  time_case("B2 Reader: 1 part, own 64 KiB reads", 4.0, 10, async fn() {
    let source = BytesSource::BytesSource(plain_wire)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some((_, part)) else { fail("no part") }
    let buf = FixedArray::make(65536, b'\x00')
    let mut n = 0
    for ;; {
      let got = @io.Reader::read(part, buf, max_len=65536)
      if got == 0 {
        break
      }
      n += got
    }
    (n, n)
  })
  // C: framing + refill, body skipped (next_part drains it).
  time_case("C Reader: 1 part, drained(4 MiB)", 4.0, 10, async fn() {
    let source = BytesSource::BytesSource(plain_wire)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some(_) else { fail("no part") }
    guard reader.next_part() is None else { fail("extra part") }
    (plain_wire.length(), plain_wire.length())
  })
  // D / D2: per-part overhead — headers, boundary, PartReader.
  time_case("D Reader: 10k parts, read_all each", 0.0, 3, async fn() {
    let source = BytesSource::BytesSource(many_wire)
    let reader = @multipart.Reader(source, boundary~)
    let mut bytes = 0
    let mut parts = 0
    while reader.next_part() is Some((_, body)) {
      bytes += body.read_all().binary().length()
      parts += 1
    }
    (bytes, parts)
  })
  time_case("D2 Reader: 10k parts, drained", 0.0, 3, async fn() {
    let source = BytesSource::BytesSource(many_wire)
    let reader = @multipart.Reader(source, boundary~)
    let mut parts = 0
    while reader.next_part() is Some(_) {
      parts += 1
    }
    (parts, parts)
  })
  // E: the delimiter scan when the body is full of CRs that never match.
  time_case("E Reader: CR-rich body(4 MiB)", 4.0, 10, async fn() {
    let source = BytesSource::BytesSource(cr_wire)
    let reader = @multipart.Reader(source, boundary~)
    guard reader.next_part() is Some((_, body)) else { fail("no part") }
    let n = body.read_all().binary().length()
    guard reader.next_part() is None else { fail("extra part") }
    (n, n)
  })
  // F / F2: the writer path into a sink that copies nothing.
  time_case("F Writer: 1 part(4 MiB) -> null", 4.0, 10, async fn() {
    let sink = NullSink::{ written: 0, }
    let writer = @multipart.Writer(sink, boundary~)
    let body = BytesSource::BytesSource(body_bytes)
    writer.write_reader(headers={}, body)
    writer.finish()
    (sink.written, sink.written)
  })
  time_case("F2 Writer: 10k parts -> null", 0.0, 3, async fn() {
    let sink = NullSink::{ written: 0, }
    let writer = @multipart.Writer(sink, boundary~)
    for _ in 0..<many_count {
      writer.write_part(
        headers={ "Content-Disposition": "form-data; name=\"f\"" },
        target => target.write("v"),
      )
    }
    writer.finish()
    (sink.written, many_count)
  })
  // G: the Form layer on top of the same bytes.
  time_case("G Form: 1 field, read_all(4 MiB)", 4.0, 10, async fn() {
    let source = BytesSource::BytesSource(plain_wire)
    let form = @multipart.Form(source, boundary~)
    guard form.next_part() is Some(part) else { fail("no part") }
    let n = part.read_all().binary().length()
    (n, n)
  })
  // H: the refill primitive on its own — the `read_some` window the reader uses
  // (8 KiB) and the same read into a caller-owned 64 KiB buffer.
  time_case("H1 read_some(8 KiB) over 4 MiB", 4.0, 10, async fn() {
    let source : &@io.Reader = BytesSource::BytesSource(body_bytes)
    let mut n = 0
    while @io.Reader::read_some(source, max_len=8192) is Some(chunk) {
      n += chunk.length()
    }
    (n, n)
  })
  time_case("H2 read(own 64 KiB buf) over 4 MiB", 4.0, 10, async fn() {
    let source : &@io.Reader = BytesSource::BytesSource(body_bytes)
    let buf = FixedArray::make(65536, b'\x00')
    let mut n = 0
    for ;; {
      let got = @io.Reader::read(source, buf, max_len=65536)
      if got == 0 {
        break
      }
      n += got
    }
    (n, n)
  })
}

///|
/// Count `target` bytes over `repeats` passes of `chunk` with a plain scalar
/// loop.
fn count_bytes(chunk : Bytes, target : Byte, repeats : Int) -> Int {
  let mut total = 0
  for _ in 0..<repeats {
    for i = 0; i < chunk.length(); i = i + 1 {
      if chunk.unsafe_get(i) == target {
        total += 1
      }
    }
  }
  total
}

///|
/// `BytesView::find` over `repeats` passes. The needle is trimmed differently
/// on each pass so the pure call cannot be hoisted out of the loop.
fn find_bytes(chunk : Bytes, needle : Bytes, repeats : Int) -> Int {
  let mut total = 0
  for i = 0; i < repeats; i = i + 1 {
    total += match chunk.find(needle[i % 8:]) {
      Some(index) => index + 1
      None => 1
    }
  }
  total
}

///|
/// The delimiter scan is the whole cost of a large-body read, so compare the
/// primitive the reader uses against a plain byte loop over the same bytes.
fn report_scan(label : String) -> Unit {
  let chunk = @utf8.encode("0123456789abcdef".repeat(512))
  let needle = @utf8.encode("\r\n------bench")
  let repeats = 512
  let start = @bench.monotonic_clock_start()
  let counted = count_bytes(chunk, b'\r', repeats)
  let byte_us = @bench.monotonic_clock_end(start) / repeats.to_double()
  let start = @bench.monotonic_clock_start()
  let found = find_bytes(chunk, needle, repeats)
  let find_us = @bench.monotonic_clock_end(start) / repeats.to_double()
  println(
    "\{label} per 8 KiB: scalar byte scan \{byte_us} µs, BytesView::find \{find_us} µs (counted=\{counted} found=\{found})",
  )
}

///|
test "bench: delimiter scan (sync)" {
  report_scan("sync ")
}

///|
async test "bench: delimiter scan (async)" {
  report_scan("async")
}

///|
test "bench: sync micro" (b : @bench.T) {
  let mut counter = 0
  b.bench(name="parse_header_value(Content-Disposition)", fn() {
    // Vary the input, otherwise the pure call is hoisted out of the loop.
    counter += 1
    let value = "form-data; name=\"field\{counter % 8}\"; filename=\"a.txt\""
    let parsed = @multipart.parse_header_value(value) catch {
      _ => ("", Map([]))
    }
    b.keep(parsed)
  })
}
