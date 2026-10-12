# Switcheroo

This fork adds a separate, searchable Safari and Google Chrome tab switcher.

The app is named **Switcheroo** and uses the bundle ID `me.richardb.window-switcher`. Its preferences, license preferences, Keychain service, login item and URL scheme are separate from upstream AltTab. Existing AltTab settings and licenses are not imported.

- Press **Control-Option-Tab**, or choose **Browser tabs…** from Switcheroo's menu.
- Type to search titles, URLs and browser names. Tab/Shift-Tab or the arrow keys select a result; Return activates it; Escape closes the panel. Releasing the shortcut modifiers leaves the panel open.
- Change the shortcut under **Settings > Controls > Additional controls > Show browser tabs**.
- Allow browser Automation access when macOS asks. The panel includes an Automation settings button and an explicit Refresh button.
- Tabs are collected when opening or refreshing the panel. No background polling or browser extension is required.

Chrome tabs are located by their native ID, even after moving between windows. Safari uses a window ID and position with title/URL validation; a changed tab requires refreshing. Browser data stays local. Safari's private-window and profile coverage depends on what its scripting interface exposes.

Build with `ai/build.sh`. Debug builds use Richard's Apple Development team so macOS can recognize the app across rebuilds and retain permission grants. Other developers can override `DEVELOPMENT_TEAM` in `config/local.xcconfig`. Install `DerivedData/Build/Products/Debug/Switcheroo.app` in `/Applications` before granting permissions. Use `ai/test.sh` to run tests. Detailed behavior is in [BrowserTabsSpecs.md](src/browser-tabs/BrowserTabsSpecs.md).

The fork uses its own [update feed](browser-tabs-appcast.xml), which currently has no releases. Upstream AltTab updates cannot replace the browser-tab build through that feed. The original license and upstream information follow.

---

<div align="center">

<a href="https://alt-tab.app/"><img src="docs/readme/main.svg" alt="AltTab Pro — 7.4M downloads — 15K GitHub stars — Get AltTab"/></a>

<a href="https://jb.gg/OpenSource"><img src="docs/readme/sponsor.svg" alt="Sponsored by JetBrains" width="900"/></a>

</div>
