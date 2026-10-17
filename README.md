# Tessera Hub

Installs, updates and starts games made with [Tessera](https://github.com/LazyAlgorithm/Tessera), and the engine
itself, from their GitHub releases. Nothing needs to be installed to run it: unzip and start `TesseraHub`
(`TesseraHub.exe` on Windows).

- **Games and the engine** come from the catalog, `src/Data/catalog.json`. The Hub reads the newest copy from this
  repository each time it starts and when checking for updates (and uses the last downloaded copy when offline,
  falling back to the built-in copy on first launch), so adding a game or a tool is an edit
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
`libraries`, `visualStudio`, `beefLibraries`, or `all` of several) and per-platform `install` steps (`download` + `unpack`, `run`,
`packages` for the Linux package managers, `write`, `delete`). `{tools}` in a path is the tools folder.

To add a game, add an entry to this JSON file on GitHub's `main` branch and upload its banner and icon under
`src/UI/`. Existing Hubs will discover the entry, description, and pictures on their next update check; no Hub
rebuild is required after installing a version with remote artwork support. The catalog is the list of games to
offer; unrelated GitHub repositories are not automatically listed.

`banner` and `icon` accept `UI/...` paths relative to this repository's `src/` directory or full HTTPS image URLs
(including raw GitHub files in a game's own repository). Pictures download in the background with the catalog,
are cached under the Hub's data folder, and refresh even when their URL stays the same. If a download fails,
the previous picture or a built-in picture is used; missing artwork leaves a plain card. The last successful
catalog and downloaded pictures remain available offline. Descriptions come from each entry's `summary`.

The banner is 1500 by 600 and fades into the page at the bottom and left; `tools/make_art.py` makes the built-in
ones.

## Building

The Hub is a Tessera project. With the engine checked out beside it:

```sh
cd Tessera
python3 tools/build_player.py ../tessera-hub --output ../TesseraHub-Linux
python3 tools/build_player.py ../tessera-hub --platform windows --output ../TesseraHub-Windows
```

Pushing to `main`, `dev`, or `release` (or a `v*` tag) builds both on GitHub Actions and publishes a release here, which
installed Hubs then update to.

## Layout

- `src/Core/` does the work: the catalog, GitHub releases, downloads and checksums, installing tools, the library of
  installed items, the Hub updating itself. Nothing in it draws.
- `src/Scripts/HubUi.bf` is the window, and `src/UI/hub.tui` and `hub.tcss` how it looks.

macOS is planned; the code already knows the platform, and a Mac build waits on the engine's.

The Windows engine entry requires a configured Beef compiler plus the Microsoft C runtime and Windows SDK libraries for compiling projects. The Hub verifies all three library directories and the managed compiler's settings. It checks these requirements when launching an already-installed engine too, and offers to repair missing tools before starting it. Games such as Polystrike are standalone and do not require these development tools.

Polystrike downloads are published separately at https://github.com/LazyAlgorithm/polystrike-releases; game source is not included in the public release repository.

Microsoft requirements are installed into Windows with Microsoft’s official Build Tools, SDK, and x64 runtime installers. Setup runs quietly after the Windows administrator prompt. Registered installations can be used by other applications. The Hub discovers the installed library folders and configures its managed Beef compiler while preserving unrelated compiler settings. Existing suitable installations are reused. The previous xwin setup was replaced because its SDK alias symlinks could fail with Windows error 1314.
