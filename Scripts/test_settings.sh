#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Models.swift Sources/TranscriptionProvider.swift \
  Sources/SIPPasswordStore.swift Sources/SettingsStore.swift \
  Tests/SipTrayTests/SettingsStoreTests.swift -o "$test_dir/settings-tests"
"$test_dir/settings-tests"
