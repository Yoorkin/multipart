# Multipart reader fixtures

These files contain raw wire bytes, including CRLF, NUL, and non-UTF-8 bytes.
Do not normalize their line endings. The fixture payloads are authored for this
package, derived from the primary references below; they are not copied from an
implementation's output. `reader_test.mbt` records decoded headers and escaped
body bytes in `__snapshot__/reader-fixtures.txt`.

## Successful inputs

| File | Reference and purpose |
| --- | --- |
| `rfc2046-simple.mime` | [RFC 2046 §5.1.1](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1), simplified two-part example: preamble/epilogue, empty headers, interior-space boundary, and exactly one body-owned CRLF in the second part. |
| `rfc2046-padding.mime` | RFC 2046 §5.1.1 grammar: SP/HTAB transport padding on every delimiter; final delimiter has no trailing CRLF. |
| `rfc2046-empty.mime` | RFC 2046 §5.1.1: empty headers and zero-length bodies, with and without a Content-Type. |
| `rfc2046-compact-empty.mime` | RFC 2046 §5.1.1 optional body separator; [Go 1.25.0 empty-part cases](https://github.com/golang/go/blob/go1.25.0/src/mime/multipart/multipart_test.go#L582-L627): a delimiter immediately after the header section, with and without headers. |
| `rfc2046-nested.mime` | RFC 2046 §5.1.1: a nested multipart body stays raw; its inner delimiter does not terminate the outer part. |
| `rfc2046-binary.mime` | RFC 2046 §5.1.1 `OCTET` grammar and [RFC 7578 §4.7](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.7): all 256 byte values survive unchanged. |
| `rfc2046-body-lines.mime` | RFC 2046 §5.1.1 delimiter grammar: inline boundary text, a shorter boundary, different case, CR/LF body bytes, and a trailing body CRLF. |
| `rfc5322-folding.mime` | [RFC 5322 §§2.2–2.2.3](https://www.rfc-editor.org/rfc/rfc5322.html#section-2.2): case-insensitive field names, repeated extension fields, continuation lines, and trailing whitespace. Repeated values are comma-joined to fit `@http.Headers`. |
| `rfc7578-raw-encoding.mime` | RFC 7578 §4.7 and [Go 1.25.0 `TestRawPart`](https://github.com/golang/go/blob/go1.25.0/src/mime/multipart/multipart_test.go): Reader returns encoded bytes and the original transfer-encoding header without decoding. |
| `go-boundary-prefixes.mime` | [Go 1.25.0 `TestParse` cases “fake separator as data” and “issue 10616 minimal”](https://github.com/golang/go/blob/go1.25.0/src/mime/multipart/multipart_test.go#L637-L681): non-delimiter suffixes (letters, underscore, or a single hyphen) remain payload, including at the start of a part body. This is a compatibility regression input, not a claim that a sender may include a boundary prefix at the start of a body line under RFC 2046. |
| `actix-short-boundary.mime` | [Actix `one_byte_boundary_parses_valid_body`, `one_byte_boundary_parses_when_split_across_chunks`, and `short_preamble_lines_before_boundary_are_skipped`](https://github.com/actix/actix-web/blob/1a41c774ec829174608b4d6cff6e8ff3c2151a41/actix-multipart/src/multipart.rs#L715-L794), combined: a one-byte boundary, short preamble lines, and two bodies. Content-Length is omitted because part framing is determined by the boundary. All delimiter lines use CRLF; the bare LF belongs to discarded preamble text. |
| `actix-empty-multipart.mime` | [Actix `first_boundary_can_be_final`](https://github.com/actix/actix-web/blob/1a41c774ec829174608b4d6cff6e8ff3c2151a41/actix-multipart/src/multipart.rs#L797-L803): the first delimiter closes a zero-part multipart body, matching this package's empty Writer output. |

## Malformed inputs

All malformed fixtures use `bad` as the supplied boundary. Rejection snapshots
are in `__snapshot__/reader-errors.txt`.

| File | Violation |
| --- | --- |
| `missing-first.mime` | RFC 2046 §5.1.1: no initial delimiter. |
| `bare-lf-framing.mime` | RFC 2046 §5.1.1: LF substituted for framing CRLF. |
| `header-without-colon.mime` | RFC 5322 §2.2: missing field separator. |
| `header-empty-name.mime` | RFC 5322 §2.2: empty field name. |
| `header-space-in-name.mime` | RFC 5322 §2.2: SP inside a field name. |
| `header-orphan-fold.mime` | RFC 5322 §2.2.3: continuation without a preceding field. |
| `header-nul.mime` | RFC 5322 §3.2.5: NUL inside a field value. |
| `header-bare-lf.mime` | RFC 5322 §2.2: bare LF inside the header block. |
| `header-truncated.mime` | Header block ends before CRLF and the separator. |
| `header-invalid-utf8.mime` | Invalid UTF-8 in a header value; the package exposes UTF-8 metadata as strings ([RFC 6532 §3.2](https://www.rfc-editor.org/rfc/rfc6532.html#section-3.2)). |
| `body-truncated.mime` | RFC 2046 §5.1.1: no complete closing delimiter. |
| `close-invalid-suffix.mime` | An invalid character follows the closing double hyphen. |
| `delimiter-invalid-padding.mime` | Non-whitespace follows transport padding. |
| `delimiter-invalid-crlf.mime` | A delimiter line has CR without LF. |

## Streaming checks

Every successful fixture is compared against its snapshot with transport reads
limited to 1, 2, 7, and 31 bytes. The folded-header fixture is also split at each
byte offset. Every strict prefix of a small complete message must fail, including
prefixes ending within the header, separator, body, and final delimiter.

A gated source makes reads fail until more bytes are explicitly made available.
It verifies that a part yields ordinary body bytes while a split delimiter is
still incomplete. [Go 1.26.0 `TestMultipartStreamReadahead`](https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/multipart_test.go#L349-L401)
adds a second gate: once that delimiter is complete, the current body must reach
EOF without requesting the next part's headers. The original LF-only input is
adapted to CRLF framing. [Go 1.26.0 `TestReadForm_NoReadAfterEOF`](https://github.com/golang/go/blob/go1.26.0/src/mime/multipart/formdata_test.go#L187-L220)
supplies another source invariant: the fixture reader fails if read again after
EOF, including closing delimiters without a final CRLF and repeated `next_part`.
Advancing the iterator also verifies that unread body bytes
are drained after a one-byte direct read and retained readers cannot consume
the next part. A nested Reader
consumes a part directly and leaves its parent ready for the following part.

A generated RFC 2046 grammar case exercises preamble, binary bodies, and delimiter
padding larger than 16 KiB, with delimiters straddling 8192-byte source reads. It
checks offset reads alternating between 1 and 17 bytes against the complete
expected body, zero-length reads, and
draining a large partly consumed body; its snapshot records only short results.

## Form parameter regressions

`form_test.mbt` extends the existing disposition snapshot with [multer 3.1.0
`test_content_distribution_misordered_fields`](https://github.com/rwf2/multer/blob/09cc7300c9bb7b3bbb30776e87ce14d2bd85588f/src/constants.rs#L150-L169):
`filename` preceding `name`, in token and quoted forms. Reproducers from
[multer issue #72](https://github.com/rwf2/multer/issues/72) check that apparent
`name=` and `filename=` parameters inside a quoted extension value are ignored.
These latter cases are adapted bug reports, not upstream passing test cases.

`parser_test.mbt` checks the shared parameter parser with Content-Type examples
from RFC 2045 §5.1 / RFC 2046 §5.1.1 and Content-Disposition examples from
RFC 2183 §2. A parsed boundary is used to read an RFC 1867 form; malformed
type/subtype values and control characters are rejected at the public entry point.

Run from the repository root:

```sh
moon test reader_test.mbt
moon test reader_test.mbt --update
```

Review changes to both fixture bytes and snapshots when updating. Sources were
checked on 2026-09-16–17; Go references are pinned to release tags, and Rust
references to the commits linked above.
