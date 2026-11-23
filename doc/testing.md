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

There is no mutation testing tool for Gleam, so `gleam_mutate.py` (from the mutation-testing lab in nao1215/debimate, with integer comparison and arithmetic operators added) is run by hand on a copy of the project. It rewrites one operator or boolean result at a time (`==`/`!=`, `<`/`<=`, `>`/`>=`, `+`/`-`, `&&`/`||`, `-> True`/`-> False`, a dropped `!`) and runs `gleam test` on the Erlang target. The score is killed / (killed + lived).

| Date | Files | Killed | Lived | Score |
|---|---|---:|---:|---:|
| 2026-11-19 | every module under `src/`, before the differential and boundary tests | 116 | 112 | 50.9% |
| 2026-11-19 | every module under `src/`, after | 188 | 40 | 82.5% |

The remaining survivors, grouped:

- `internal/bytes` and `internal/scan` (26): loop bounds where `>=` and `>` take the same path because slicing past the end already fails, and the ASCII case folding of `equals_ascii_ci`, which has since been removed as unused.
- `stream` (4): the header-block and part-size checks at exactly the limit, and the 64 KiB body chunking, which no test reaches with a part that large.
- `internal/headers` (3): trailing whitespace trimming where a tab and a space are handled the same way downstream.
- Single cases in the Content-Disposition parser, the boundary length check, the Content-Type parser, the part builder, `internal/text` and the content type check. These modules were merged into `multipartkit` after the run.
