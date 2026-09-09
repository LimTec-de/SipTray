#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Models.swift Sources/TranscriptionProvider.swift \
  Sources/ConversationMinutes.swift Tests/SipTrayTests/ConversationMinutesTests.swift \
  -o "$test_dir/minutes-tests"
"$test_dir/minutes-tests"
