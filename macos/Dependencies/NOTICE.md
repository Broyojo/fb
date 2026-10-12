# Bundled Pandoc

This app includes the unmodified Pandoc 3.12.1 executable, obtained from the
official macOS arm64 ZIP release. The app may replace the executable's code
signature during packaging; its program code is unchanged.

Copyright (c) 2006-2024 John MacFarlane and contributors.
Pandoc is distributed under the GNU General Public License, version 2 or later.
The complete license text is in `Pandoc-COPYING.md` next to this notice.
Pandoc is provided without warranty; see that license for details.

- Project: https://pandoc.org/
- Release: https://github.com/jgm/pandoc/releases/tag/3.12.1
- Source: https://github.com/jgm/pandoc/tree/3.12.1
- Source archive: https://github.com/jgm/pandoc/archive/refs/tags/3.12.1.tar.gz
- Build instructions: https://github.com/jgm/pandoc/blob/3.12.1/INSTALL.md
- Official release build configuration: https://github.com/jgm/pandoc/tree/3.12.1/.github/workflows

The exact binary URL, checksum, source version, license, and upstream signer are
recorded in `pandoc.json`. The executable embeds Pandoc's required data files.
The app invokes Pandoc as a separate executable; it does not link it into Swift
or Go. Optional external filters and TeX/PDF engines are not included.

For distributors: provide the complete corresponding source for this Pandoc
build and its linked components as required by the included license. Preserve
the upstream build configuration, package versions, license notices, and any
local modifications. Publish that material alongside the app's download;
these upstream links are provenance, not a substitute for a complete source
distribution. The packaging script produces the app archive and copies these
notices; it does not assemble that complete source distribution.
