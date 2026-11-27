# Testing

`just ci` runs everything below except the nightly job and mutation testing. Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x.

## Examples and unit tests

`test/multipartkit/*_test.gleam` checks the parser, the streaming parser, the encoder, the part builders, `Content-Disposition`, limits and queries, one area per file. `test/multipartkit/golden_fixtures_test.gleam` pins the exact bytes of representative messages, and each fixed bug keeps its reproduction in a `regression_*_test.gleam` file or next to the related tests. `test/readme_test.gleam` runs the second README example and the examples in the doc comments. `just examples` builds and runs every program under `examples/`, and `just check-readme` keeps the README quick start equal to `examples/quick_start`.

## Generated properties

`test/multipartkit_metamon_test.gleam` uses metamon: an encoded form parses back to the same fields, files, filenames and content types, field order and duplicates survive, and names or filenames with CR / LF / NUL are rejected.

## Differential testing

`test/multipartkit/stream_differential_test.gleam` compares the buffered parser (`multipartkit.parse`) with the streaming parser (`stream.parse`), two implementations of the same grammar. For random forms whose file bodies are full of CR, LF, `--` and delimiter prefixes, cut into random chunk sizes, both must return the same parts. The same holds for damaged messages (a byte range dropped or a byte inserted), where both must fail with the same error, and with every limit set one below, at and one above what the message needs. A second generator writes messages by hand from the pieces of the RFC 2046 grammar that `encode_form` never writes: LF-only lines, transport padding, preambles, epilogues, folded and malformed headers and empty bodies. Those are compared at the default limits, at random small limits, and between two different splits of the same input. This test found that the streaming parser ignored the epilogue for `max_body_bytes` when it arrived in a later chunk, and that with small limits the result depended on the split: a body over `max_body_bytes` with an earlier problem, transport padding counted as part body, and an unfinished part over `max_part_bytes`.

## Boundary tables

`test/multipartkit/char_class_test.gleam` walks every ASCII code point through the RFC 5987 `attr-char` set (which characters a `filename*` value may hold), the RFC 7230 `quoted-pair` grammar, and the quoted `filename` that `new_file` writes, which round-trips every byte but CR, LF and NUL. `test/regression_rfc_conformance_test.gleam` holds the cases found by reading RFC 2046 §5.1 and RFC 7578 against the code.

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed and the shrunk input, so the case can be replayed with `metamon.Config(..metamon.default_config(), seed: Some(seed))` and kept as a regression test.

## Mutation testing

`gleam run -m metamon/mutation` changes one operator, `!` or boolean literal in a module under `src/` at a time and runs `gleam test --target erlang` on each change. `.github/workflows/mutation.yml` mutates the modules a pull request or push changes and fails on a survivor that `doc/mutation/baseline.json` does not list; the weekly run mutates every module. `just mutation` runs it locally and `just mutation-record` records a new baseline.

The first run (2026-11-27) scored 84.2% (186 killed, 35 lived). Tests were then added for the first and last lead byte of each UTF-8 range and the lowest and highest continuation byte in a header line that is not UTF-8, every ASCII character in a header name and in an unquoted parameter value, a non-ASCII character in `filename*`, a dash-boundary inside a body line, the carry that `stream.encode` keeps between body chunks, and the header and part limits at exactly the limit for unfinished input and in `stream.parse`, and the score rose to 93.2% (206 killed, 15 lived). The 15 survivors left give the same result:

- Loop bounds in `internal/bytes` and `skip_lwsp` where `>=` and `>` (or a step past the end) take the same path because slicing past the end already fails (6).
- The offset after the closing delimiter in `consume_closing_tail`, which neither parser reads because the epilogue is ignored (4).
- The checks of `check_line_starts` that cannot change the carry: starting the newline search one byte past the end, a last line as long as the boundary (it equals the boundary and was rejected already, or is no prefix of it), and searching below the lowest offset, where a line is longer than the boundary (3).
- `body_end_for` at offset 2, where the result is clamped to the start of the body either way (1).
- The unaligned bit array case of the header name check, which a `String` never reaches (1).

<!-- mutation:start -->
| Module | Killed | Lived | Timed out | Score |
|---|---:|---:|---:|---:|
| `multipartkit` | 25 | 0 | 0 | 100.0% |
| `multipartkit/internal/bytes` | 15 | 5 | 0 | 75.0% |
| `multipartkit/internal/disposition` | 18 | 0 | 0 | 100.0% |
| `multipartkit/internal/headers` | 32 | 1 | 0 | 97.0% |
| `multipartkit/internal/scan` | 30 | 9 | 0 | 76.9% |
| `multipartkit/internal/text` | 56 | 0 | 0 | 100.0% |
| `multipartkit/stream` | 30 | 0 | 0 | 100.0% |
| all | 206 | 15 | 0 | 93.2% |
<!-- mutation:end -->
