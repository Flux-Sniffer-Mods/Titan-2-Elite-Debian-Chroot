# Third-party components

Everything in this repository is licensed under GPL-3.0-or-later (see [LICENSE](LICENSE)),
with the exception noted below for files that come from other projects.

## Prebuilt binaries in `titan-addons-bundle.tar.gz`

This archive is a convenience build. It contains compiled binaries of two other
projects, so that a fresh install does not have to spend 20 to 40 minutes compiling
them on the phone. Nothing in it was written here; it is `titan_addons.sh` output,
built from unmodified upstream sources.

`titan-addons-bundle.key` records which KWin release the archive was built against.

### Klassy

- Upstream: https://github.com/paulmcauley/klassy
- Copyright: Paul McAuley and the Klassy contributors
- License: a mix, including GPL-2.0-only, GPL-3.0-only, GPL-2.0-or-later,
  LGPL-2.1-or-later and MIT. See the `COPYING` and per-file headers in the upstream
  source for exact terms.
- Files in the archive: `klassy6.so`, `org.kde.klassy.so`, `klassystyleconfig.so`,
  `kcm_klassydecoration.so`, and the bundled decoration presets

### KDE Rounded Corners (ShapeCorners)

- Upstream: https://github.com/matinlotfali/KDE-Rounded-Corners
- Copyright: Matin Lotfali and contributors
- License: GPL-3.0
- Files in the archive: `kwin4_effect_shapecorners.so`,
  `kwin_shapecorners_config.so`

## Obtaining the source

Both projects are under licenses that require the corresponding source to be
available to anyone who receives the binaries. The source is the upstream Git
repository linked above, at the release the archive was built from.

You can also rebuild the archive yourself from those sources, which is what
`titan_addons.sh` does:

```sh
REBUILD_ADDONS=1 bash ~/boot_desktop.sh
```

That fetches the upstream sources, compiles them, and writes a fresh
`titan-addons-bundle.tar.gz` and `titan-addons-bundle.key`.

If you would rather not use the prebuilt archive at all, delete both bundle files
before installing and the scripts will compile from source instead.

## Other projects this one uses but does not redistribute

These are downloaded or installed at run time. No part of them is stored here.

- Plasma Drawer launcher: https://github.com/p-connor/plasma-drawer
- Termux, Termux:X11, Termux:Widget and Termux:API: https://termux.dev
- Debian, KDE Plasma and KWin, installed from the Debian archive
