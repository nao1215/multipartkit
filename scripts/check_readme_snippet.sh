#!/bin/sh
# check_readme_snippet.sh -- Verify that the first ```gleam code block in
# README.md matches the canonical quick-start example file
# byte-for-byte. Catches doc/example drift in CI.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
EXAMPLE="$ROOT/examples/quick_start/src/multipartkit_quick_start.gleam"

if [ ! -f "$README" ]; then
  echo "error: README.md not found at $README" >&2
  exit 1
fi
if [ ! -f "$EXAMPLE" ]; then
  echo "error: quick-start example not found at $EXAMPLE" >&2
  exit 1
fi

EXTRACTED="$(mktemp)"
trap 'rm -f "$EXTRACTED"' EXIT

awk '
  BEGIN { capture = 0; done = 0 }
  /^```gleam$/ && !done { capture = 1; next }
  /^```$/ && capture { done = 1; capture = 0; exit }
  capture { print }
' "$README" > "$EXTRACTED"

if ! diff -u "$EXAMPLE" "$EXTRACTED"; then
  cat <<EOF >&2

error: the first \`\`\`gleam\`\`\` block in README.md drifted from
$EXAMPLE.

Update one of them so that they match. The example file is the source
of truth: it is built and run on every CI push.
EOF
  exit 1
fi

echo "README quick-start snippet matches $EXAMPLE"
