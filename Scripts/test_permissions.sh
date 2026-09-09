#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Permissions/*.swift \
  Tests/SipTrayTests/PermissionTests.swift -o "$test_dir/permission-tests"
"$test_dir/permission-tests"
