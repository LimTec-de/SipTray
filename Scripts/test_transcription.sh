#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library \
  Sources/Models.swift Sources/TranscriptionProvider.swift \
  Sources/CloudTranscription.swift Sources/CallTranscriptionService.swift \
  Tests/SipTrayTests/TranscriptionTests.swift -o "$test_dir/transcription-tests"
"$test_dir/transcription-tests"
