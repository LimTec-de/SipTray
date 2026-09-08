# Third-Party Software

SipTray links the components below. Their original copyright notices and license
texts are included in the application's Contents/Resources/Licenses directory.
Scripts/copy_licenses.sh collects these texts from the exact dependency checkout
used for the build; a missing text fails packaging.

| Component | License / source |
| --- | --- |
| PJSIP / PJPROJECT | GPL-2.0-or-later or a separate commercial agreement; https://www.pjsip.org/licensing.htm |
| Sparkle (including its bundled third-party notices) | MIT and bundled notices; https://github.com/sparkle-project/Sparkle/blob/HEAD/LICENSE |
| libSRTP | BSD-style; Vendor/pjproject/third_party/srtp/LICENSE |
| Speex | BSD-style; Vendor/pjproject/third_party/speex/COPYING |
| GSM | See Vendor/pjproject/third_party/gsm/COPYRIGHT |
| Resample | See Vendor/pjproject/third_party/resample/COPYING |
| WebRTC | BSD-style and additional notices; Vendor/pjproject/third_party/webrtc/LICENSE* |
| iLBC | Internet Society (2004), RFC 3951 source; https://www.rfc-editor.org/rfc/rfc3951 |
| G.722 | Public-domain algorithm in PJSIP; pjmedia/src/pjmedia-codec/g722/ |

## Release Requirements

PJSIP's license does not replace the licenses of its third-party components.
Review https://docs.pjsip.org/en/latest/overview/license_3rd_party.html for the
enabled codecs and applicable conditions before distributing binaries.

G.722.1 and G.722.1C are excluded via --disable-g7221-codec and are not linked
by Package.swift. Normal G.722 remains enabled. This avoids distributing the
G.722.1 implementation with its separate Poly licensing requirements; it does
not remove the upstream source files from the PJPROJECT submodule.

For GPL distribution, provide the corresponding source for the distributed
binary, including modifications, dependency revisions and build scripts.
Publishing only a ZIP or a license notice is not a substitute for that source.

The license for SipTray's own code remains to be selected by its rights holder;
these third-party notices do not relicense SipTray or third-party code.
