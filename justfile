set shell := ["sh", "-cu"]

# Make the mise-managed toolchain (erlang / gleam / rebar / node)
# visible to every recipe even when the invoking shell has not run
# `mise activate`.
export PATH := shell('. scripts/lib/mise_bootstrap.sh; printf %s "$PATH"')

default:
  @just --list

deps:
  gleam deps download

format:
  gleam format src/ test/

format-check:
  gleam format --check src/ test/

lint:
  gleam run -m glinter

typecheck:
  gleam check

build:
  gleam build --warnings-as-errors

build-erlang:
  gleam build --warnings-as-errors --target erlang

build-javascript:
  gleam build --warnings-as-errors --target javascript

build-all-targets: build-erlang build-javascript

test:
  gleam test

test-erlang:
  gleam test --target erlang

test-javascript:
  gleam test --target javascript

test-all-targets: test-erlang test-javascript

docs:
  gleam docs build

check: clean
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter
  gleam build --warnings-as-errors
  gleam test
  just check-readme

# Verify that the first ```gleam``` snippet in README.md still matches
# examples/quick_start (the source of truth for the quick-start code).
check-readme:
  sh scripts/check_readme_snippet.sh

ci: deps check build-javascript test-javascript examples

all: clean deps
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter
  gleam build --warnings-as-errors --target erlang
  gleam build --warnings-as-errors --target javascript
  gleam test --target erlang
  gleam test --target javascript
  gleam docs build
  just examples
  @echo ""
  @echo "All checks passed."

# Build and run every runnable example under examples/ with
# --warnings-as-errors. CI runs this on every push.
examples: example-quick-start example-parse-request example-streaming-parse example-mimetype

example-quick-start:
  cd examples/quick_start && gleam deps download && gleam build --warnings-as-errors && gleam run

example-parse-request:
  cd examples/parse_request && gleam deps download && gleam build --warnings-as-errors && gleam run

example-streaming-parse:
  cd examples/streaming_parse && gleam deps download && gleam build --warnings-as-errors && gleam run

example-mimetype:
  cd examples/mimetype_inference && gleam deps download && gleam build --warnings-as-errors && gleam run

clean:
  gleam clean
