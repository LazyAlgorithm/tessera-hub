# Tessera Hub

Installs, updates and starts games made with [Tessera](https://github.com/LazyAlgorithm/Tessera), and the engine
itself, from their GitHub releases. Nothing needs to be installed to run it: unzip and start `TesseraHub`
(`TesseraHub.exe` on Windows).

- **Games and the engine** come from the catalog, `src/Data/catalog.json`. The Hub reads the newest copy from this
  repository each time it starts (and uses the copy built into it when offline), so adding a game or a tool is an edit
  to that file, with no new Hub needed.
- **Updates.** The Hub checks when it starts and from Settings. An installed game with a newer release shows
  *Update available*. Downloads are checked against the release's `SHA256SUMS.txt`, unpacked beside the installed
  copy, and only then put in its place, so a failed update leaves the game working.
- **Betas.** An item marked `"beta": true` shows a BETA badge, and a release marked as a pre-release on GitHub is
  shown as a beta version. **Get beta builds** in Settings (on by default, as nearly everything is in beta) decides
  whether pre-releases are offered at all.
- **Tools a game or the engine needs** (the engine's Beef compiler, Python, Microsoft's libraries on Windows, a C
  compiler and system libraries on Linux) are listed in the catalog with how to find and install them. The Hub
  checks for them before installing, says what is missing, how big it is and its licence, and installs them only
  after you agree. Tools go into the folder the Tessera editor looks in.
- **The Hub updates itself** from this repository's releases.

Where things go: `%LOCALAPPDATA%\Tessera Hub` on Windows, `~/.local/share/Tessera Hub` on Linux (installed games
and the engine, `library.json`, `install.log`), and tools in `…/Tessera/toolchain`.

## The catalog

```json
{
  "id": "ringfall", "kind": "game", "name": "Ringfall", "beta": true,
  "summary": "One or two sentences.",
  "repo": "LazyAlgorithm/ringfall-releases",
  "tagPrefix": "",
  "assets": { "windows": "Ringfall-Windows.zip", "linux": "Ringfall-Linux.zip" },
  "run":    { "windows": "Ringfall-Windows/Ringfall.exe", "linux": "Ringfall-Linux/Ringfall" },
  "requires": [],
  "banner": "UI/banner_ringfall.png", "icon": "UI/icon_ringfall.png", "accent": "#ffc145"
}
```

`kind` is `game` or `engine`. `tagPrefix` limits which releases count (the engine's builds are `build-…`).
`requires` names entries of `dependencies`, each with `found` checks (`file`, `program`, `env`, `command`,
`libraries`, `visualStudio`, or `all` of several) and per-platform `install` steps (`download` + `unpack`, `run`,
`packages` for the Linux package managers, `write`, `delete`). `{tools}` in a path is the tools folder.

The banner is 1500 by 600 and fades into the page at the bottom and left; `tools/make_art.py` makes the built-in
ones.

## Building

The Hub is a Tessera project. With the engine checked out beside it:

```sh
cd Tessera
python3 tools/build_player.py ../tessera-hub --output ../TesseraHub-Linux
python3 tools/build_player.py ../tessera-hub --platform windows --output ../TesseraHub-Windows
```

Pushing to the `release` branch (or a `v*` tag) builds both on GitHub Actions and publishes a release here, which
installed Hubs then update to.

## Layout

- `src/Core/` does the work: the catalog, GitHub releases, downloads and checksums, installing tools, the library of
  installed items, the Hub updating itself. Nothing in it draws.
- `src/Scripts/HubUi.bf` is the window, and `src/UI/hub.tui` and `hub.tcss` how it looks.

macOS is planned; the code already knows the platform, and a Mac build waits on the engine's.

The Windows engine entry requires a configured Beef compiler plus the Microsoft C runtime and Windows SDK libraries for compiling projects. The Hub verifies all three library directories and the managed compiler's settings. It checks these requirements when launching an already-installed engine too, and offers to repair missing tools before starting it. Games such as Polystrike are standalone and do not require these development tools.

Polystrike downloads are published separately at https://github.com/LazyAlgorithm/polystrike-releases; game source is not included in the public release repository.
