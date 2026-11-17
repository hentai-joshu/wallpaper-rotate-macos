# Wallpaper Rotate (macOS)

A menu-bar app that rotates your desktop wallpaper from a folder of your own pictures — and gives **every desktop (Space) and every display its own different picture**.

Apple's built-in folder rotation gives every desktop the same image. This one doesn't.

```
~/Applications/WallpaperRotate.app          menu-bar app
~/Library/LaunchAgents/local.wallpaper-rotate.plist   starts it at login
```

Requires macOS 13+ and the Command Line Tools (`xcode-select --install`). No dependencies, no network, one `clang` invocation.

## What it does

- Picks a random picture from your folder every N minutes (5 min … 4 h, default 30 min).
- Each desktop gets a **different** picture, and on multi-monitor setups each display gets a different one too.
- Remembers the last 40 pictures so you don't see the same one twice in a row.
- **New desktops are adopted automatically** — create a Space and it gets its own picture within a few seconds.
- "Pause" means *go back to your normal wallpaper*: it restores a snapshot you saved earlier and stops rotating. "Resume" rotates immediately and restarts the clock.
- Prunes the wallpaper cache macOS accumulates (~3–7 MB per picture per display) down to the newest 10 entries.

Menu, top to bottom: 立即换一张 (rotate now) · 暂停 / 恢复 (pause — restores your saved default — / resume) · 把当前壁纸设为办公默认 (save current as the default to return to) · 切回办公默认壁纸（并暂停） (restore it) · 换图间隔 (interval) · 选择图库文件夹 (choose folder) · 打开图库文件夹 (open folder) · 打开墙纸设置 (Wallpaper settings) · 退出 (quit).

## Install

```sh
git clone https://github.com/hentai-joshu/wallpaper-rotate-macos.git
cd wallpaper-rotate-macos
./install.sh              # build, install, load
```

`./install.sh --dry-run` prints what it would do; `--no-load` installs without starting the agent.

Then click the menu-bar icon → **选择图库文件夹…** ("choose folder") and point it at a folder of pictures.

The menu is in Chinese. A folder is only used once you pick one; until then the app looks for `~/Pictures/Wallpapers`, then `~/Pictures/壁纸`. Every desktop and display gets its own picture on the next rotation.

中文使用说明（菜单各项、缓存、卸载）：[使用说明与卸载.md](使用说明与卸载.md)

Uninstall:

```sh
./uninstall.sh            # unload + remove app and agent
./uninstall.sh --purge    # also delete saved settings
```

## How it works, and the four things that cost the most time

The app is a single Objective-C file. It does not use AppleScript or Accessibility APIs — it edits the system wallpaper store directly.

**1. `NSWorkspace setDesktopImageURL:forScreen:` only affects the *currently visible* Space.**
There is no public API for the other desktops. For those you have to write the store file:

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
```

with `AllSpacesAndDisplays`, `SystemDefault`, `Spaces` and `Displays` at the top, and per Space a `Default` plus one entry per display. Each entry is a `Desktop` → `Content.Choices[0]` holding a `Provider`, `Files` and a binary `Configuration` blob. Copy an existing choice as a template; don't synthesize one.

**2. Never kill `WallpaperAgent` to make the change visible.**
`killall WallpaperAgent` does refresh the screen — at the cost of about a second of black. Worse, `SIGTERM` makes the agent flush its in-memory state back over your edit. Writing the store only takes effect on the next Space switch, which is fine: the active Space is repainted by the public API, and the others are correct by the time you look at them.

**3. Never change `AllSpacesAndDisplays.Type`, and never empty `Spaces` / `Displays`.**
Trying to collapse the config to "one picture everywhere" makes macOS rewrite `Type` to `linked`, set `Provider` to `default`, and drop every wallpaper back to `DefaultDesktop.heic`. Keep the structure and edit the image inside each entry.

**4. Don't guess the current Space from the pictures on screen.**
The obvious trick — compare what is displayed against the store — fails exactly when it matters: while a rotation is in flight, so the app concludes it is looking at a *different* desktop and writes the new picture there. Use the private-but-stable SkyLight call instead:

```c
void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
CGSConnectionID c = ((CGSConnectionID (*)(void))dlsym(h, "_CGSDefaultConnection"))();
CFArrayRef spaces = ((CFArrayRef (*)(CGSConnectionID))dlsym(h, "CGSCopyManagedDisplaySpaces"))(c);
```

Each display dictionary has an `Identifier` and a `Current Space` with the Space UUID. (`_CGSGetActiveSpace` does not exist in the shipped framework.)

### The bug worth mentioning: two writers, one screen

Rotation and "repair what drifted" both write the same screen. Repair ran on a 4-second timer and on every Space-change notification, reading a record that rotation only updated 1.5 s later — so it treated the brand-new picture as drift and put the old one back, then the real record landed and the wallpaper service repainted again. Result: **two visible changes per rotation.**

The fix is not a longer delay. It is (a) ask SkyLight which Space is current and write the record *synchronously* in the same turn as the screen change, (b) ignore repair for 4 s after a rotation, (c) require two consecutive observations before calling something drift.

### Cache

macOS renders a full-screen PNG per wallpaper per display:

```
~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/
```

Deleting it never changes the current wallpaper; the service re-renders on demand. The app keeps the newest 10 files after each rotation.

## Files

```
app/main.m          the whole app (menu bar, store editing, SkyLight, cache pruning)
app/probe_url.m     tiny helper: prints what each display is currently showing
app/make_default.sh snapshot the system wallpaper config by hand
使用说明与卸载.md   Chinese user guide: menu items, cache, uninstall
install.sh          build + install + load
uninstall.sh        unload + remove
```

## License

MIT.
