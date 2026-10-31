# Nunito Sans

Bundled under the SIL Open Font License; see OFL.txt. Copyright 2016 The Nunito
Sans Project Authors (https://github.com/Fonthausen/NunitoSans).

Source: Google Fonts `ofl/nunitosans`, retrieved 2026-10-30:
- NunitoSans[YTLC,opsz,wdth,wght].ttf
- NunitoSans-Italic[YTLC,opsz,wdth,wght].ttf

These are static instances of the upstream variable fonts, generated with
fontTools 4.68.0 at optical size 12, width 100 and the default YTLC axis. Upright
weights in this app: 400, 500, 600, 700. Italics: 400 and 700. Name records are normalized
to the Nunito Sans typographic family and NunitoSans-* PostScript names so AppKit
bold/italic conversion and SwiftUI resolve the same faces reliably. Outlines,
glyph coverage and OpenType features are preserved. There is no runtime font
conversion or network dependency.

The reproducible generator lives in the macOS repository:
[generate_nunito_fonts.py at the source commit](https://github.com/Muesli-HQ/muesli/blob/3d8e3f6d689f1c0ba27c0894c3586c7f6a4f2ceb/scripts/generate_nunito_fonts.py).
It takes the two upstream variable font files and an output directory. Generate
the static faces there, then copy the six faces listed in UIAppFonts into this
folder (omit ExtraBold). XcodeGen packages them through Shared; the host and
keyboard Info.plist files register them at launch. Do not depend on locally
installed fonts or SwiftPM resource loading.

Upstream SHA-256 checksums (upright, italic):

```text
f934d7142fb4784bf828da485b7dcbd90c0c80d514e9d49a5da0ed3a1ae2491d
d9d5db18f3c11221a4fbb553cbc709391c1179964c7eaa4466ef43c78aa4492f
```

## iOS packaging

Copied from macOS PR #705 (3d8e3f6d). XcodeGen includes these resources in the host and keyboard targets through Shared. UIAppFonts registers the six included faces at launch; the unused extra-bold face is omitted. MuesliTheme uses relative SwiftUI custom fonts for Dynamic Type.
