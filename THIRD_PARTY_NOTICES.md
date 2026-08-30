# Third-Party Notices

Provenance Cleaner includes or is built with the components below. Exact
artifacts, URLs, hashes, and roles are recorded in
Config/Dependencies.lock.json. Full license texts ship in
App/Resources/ThirdPartyLicenses.

## Runtime components

- **watermarks-remover**, commit
  3f84d3e3964368b82172112b09ef3e7c02b25749, copyright 2026 Guillaume
  Meyer and contributors. Licensed under the MIT License.
- **c2patool 0.27.16** from the Content Authenticity Initiative. The project
  is dual-licensed under Apache-2.0 or MIT; this distribution uses the MIT
  option.
- **ExifTool 13.59**, copyright 2003-2026 Phil Harvey. ExifTool is available
  under the same terms as Perl itself (the Perl Artistic License or GPL).
  This distribution selects Artistic-1.0-Perl, includes the complete Artistic
  License and the upstream copyright/license statement, and keeps ExifTool as
  its original Perl launcher and source modules. Exact source:
  https://github.com/exiftool/exiftool/tree/2200871d9cef988051d2a99d67df3bda6cbb30a8.
- **qpdf 12.4.1**, copyright 2005-2021 Jay Berkenbilt and 2022-2026 Jay
  Berkenbilt and Manfred Holger. Licensed under Apache-2.0. The upstream
  NOTICE is included.
- **libjpeg-turbo 3.2.0** is statically linked into qpdf. This software is
  based in part on the work of the Independent JPEG Group. Its upstream
  combined IJG and BSD license notice is included.

## Helper runtime and build tooling

- **CPython 3.14.7** is licensed under the Python Software Foundation License
  Version 2. The bundled Python standard library may contain incorporated
  software whose acknowledgements are reproduced in the CPython license.
- **OpenSSL 3.5.7** supplies the embedded CPython runtime's `libcrypto` and
  `libssl` libraries. It is licensed under Apache-2.0. The complete
  Apache-2.0 terms are included in
  `App/Resources/ThirdPartyLicenses/qpdf-LICENSE-Apache-2.0.txt` and apply to
  OpenSSL as well as qpdf.
- **Zstandard 1.5.7** supplies the embedded CPython runtime's `libzstd`
  library. It is licensed under BSD-3-Clause; the exact upstream license text
  is included.
- **PyInstaller 6.22.2** is licensed under GPL-2.0-or-later with a special
  bootloader exception that permits embedding and distributing compiled
  bootloader and related files with other programs. Its full terms are
  included.

CPython and PyInstaller are pinned helper build inputs. They are not fetched
or installed by script/fetch_dependencies.sh; script/build_helper.sh owns the
frozen helper build.

The PyInstaller build environment also pins **altgraph 0.17.5** (MIT),
**macholib 1.16.4** (MIT), **packaging 26.3** (Apache-2.0 or BSD-2-Clause),
**PyInstaller Hooks Contrib 2026.7** (GPL-2.0-or-later standard build hooks;
Apache-2.0 runtime hooks), and **setuptools 84.0.0** (MIT). Their official
wheels and SHA-256 values are recorded in the canonical dependency lock and
enforced with pip's hash-checking mode. These transitive packages are build
tools only and are not included in the shipped helper; the PyInstaller
bootloader exception terms above cover the embedded PyInstaller bootloader.

## Explicit exclusion

Ghostscript is not downloaded, linked, or shipped. Consequently, the app does
not offer Ghostscript-based deep PDF image rewriting.

These notices are informational and do not replace the complete license texts.
