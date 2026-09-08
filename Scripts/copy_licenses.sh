#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="${1:?Usage: copy_licenses.sh ABSOLUTE_DESTINATION}"
mkdir -p "$destination"
cp THIRD_PARTY_NOTICES.md "$destination/"
for source in \
  Vendor/pjproject/COPYING \
  Vendor/pjproject/third_party/srtp/LICENSE \
  Vendor/pjproject/third_party/speex/COPYING \
  Vendor/pjproject/third_party/gsm/COPYRIGHT \
  Vendor/pjproject/third_party/resample/COPYING \
  Vendor/pjproject/third_party/webrtc/LICENSE \
  Vendor/pjproject/third_party/webrtc/LICENSE_THIRD_PARTY \
  .build/checkouts/Sparkle/LICENSE \
  .build/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt
do
  name=$(printf '%s' "$source" | tr '/' '_')
  cp "$source" "$destination/$name"
done
