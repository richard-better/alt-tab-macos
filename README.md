# Switcheroo

My personal fork of [AltTab](https://github.com/lwouis/alt-tab-macos). It adds Safari and Google Chrome tab switching and a different switcher layout. Everyone else should use the [original AltTab](https://alt-tab.app/).

Switcheroo uses its own bundle ID (`me.richardb.window-switcher`), so its settings, license, login item and URL scheme are separate from AltTab. AltTab settings and licenses are not imported.

## Browser tabs

- Press **Control-Option-Tab**, or choose **Browser tabs…** from the menu.
- Type to search titles and URLs. Arrow keys or Tab/Shift-Tab select, Return switches, Escape closes.
- Change the shortcut in **Settings > Controls > Browser tabs shortcut**.
- Allow Automation access when macOS asks. Tabs are read when the panel opens, with no polling or browser extension.

Details are in [BrowserTabsSpecs.md](src/browser-tabs/BrowserTabsSpecs.md).

## Development

Build with `ai/build.sh` and test with `ai/test.sh`. To build with your own team, set `DEVELOPMENT_TEAM` in `config/local.xcconfig`. Install `DerivedData/Build/Products/Debug/Switcheroo.app` in `/Applications` before granting permissions.

## Releases

Releases are published on [GitHub](https://github.com/richard-better/switcheroo/releases) with their own update feed. See the [release instructions](scripts/release/README.md) and the [changelog](changelog.md), which lists the upstream AltTab version in each release.
