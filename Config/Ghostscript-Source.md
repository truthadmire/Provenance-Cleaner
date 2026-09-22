# Ghostscript corresponding source

Provenance Cleaner invokes Ghostscript 10.07.1 as a standalone command-line
program for PDF embedded-image metadata cleaning. It is distributed under
AGPL-3.0-or-later; its dependencies retain the notices in the original source.

The release DMG includes this directory under `Third-Party Source/Ghostscript`,
containing the original Artifex archive, complete AGPL text, and the exact
standalone build recipe used for the bundled executable. Keep this source
directory with redistributions of the release.

Source: https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/tag/gs10071

Archive: `ghostscript-10.07.1.tar.xz`

SHA-256: `1cdb766de8db8f1e589c817f09c5855ea5f65dfc8540e465a69ac14c18416025`

To rebuild on an Apple-silicon Mac with Xcode command-line tools, run:

```sh
./build_ghostscript.sh ghostscript-10.07.1.tar.xz /absolute/path/to/new-output 10.07.1
```

The recipe uses source-bundled codecs and compiled-in initialization files,
fonts and profiles. It targets macOS 14+, uses only system dynamic libraries,
and disables printer services, OCR and GUI support. No Ghostscript source
patches are applied. The finished binary is `new-output/gs`.
