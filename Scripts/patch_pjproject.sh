#!/bin/sh

set -eu

PJSIP_DIR="${1:-Vendor/pjproject}"
FILE="$PJSIP_DIR/pjmedia/src/pjmedia-audiodev/coreaudio_dev.m"

if [ ! -f "$FILE" ]; then
  echo "Missing PJPROJECT file: $FILE" >&2
  exit 1
fi

# Fix CoreAudio buffer sizes for multi-byte samples and keep macOS on HALOutput.
perl -0pi -e '
  s/buf->mBuffers\[0\]\.mDataByteSize = inNumberFrames \*
\s+strm->streamFormat\.mChannelsPerFrame;/buf->mBuffers[0].mDataByteSize = inNumberFrames *
                                     strm->streamFormat.mChannelsPerFrame *
                                     strm->streamFormat.mBitsPerChannel \/ 8;/g;

  s/desc\.componentSubType = \(\*\(pj_bool_t\*\)pval\)\?\s*
                                kAudioUnitSubType_VoiceProcessingIO :\s*
#if COREAUDIO_MAC\s*
                                kAudioUnitSubType_HALOutput;\s*
#else\s*
                                kAudioUnitSubType_RemoteIO;\s*
#endif/desc.componentSubType =
#if COREAUDIO_MAC
                                kAudioUnitSubType_HALOutput;
#else
                                (*(pj_bool_t*)pval)?
                                kAudioUnitSubType_VoiceProcessingIO :
                                kAudioUnitSubType_RemoteIO;
#endif/g;
' "$FILE"
