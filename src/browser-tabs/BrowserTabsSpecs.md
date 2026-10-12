# Browser tabs

A separate browser-tab panel lists tabs in running Safari and Google Chrome instances. It does not change the normal window switcher. The default shortcut is Control-Option-Tab and can be changed in Settings > Controls > Additional controls. Repeating the shortcut or pressing Tab advances the selection; Shift-Tab and Up move backwards. Return or a double-click activates a tab. Escape dismisses without switching. Releasing modifiers leaves the search panel open.

- Collect only running supported browsers. Request Automation consent through browser scripting when the user summons or refreshes the panel. Permission denial remains distinct from a successful empty list.
- Return structured JSON, preserving punctuation, Unicode and linefeeds in titles and URLs. No browsing data is logged or written to a script file.
- Request browser Automation consent on the serial background queue before launching osascript. Waiting for a human response is outside the eight-second script timeout. Denied browsers produce issues while permitted browsers still return tabs.
- Keep the panel visible when an Automation dialog takes focus during collection or activation. Restore search focus when the operation finishes. Escape or the close button still dismisses immediately, and a stale asynchronous result cannot reopen the panel.
- Script execution runs in a child osascript process on a serial background queue. Bound the process lifetime to eight seconds after consent. Summoning paints before starting collection.
- Keep successful results when the other browser fails. Show its permission/error status alongside available tabs. Refresh is explicit; there is no background polling.
- Chrome activation resolves the native tab ID across windows, including a tab moved after the snapshot. Safari resolves the window ID and position and validates the title and URL; reject a changed position. Safari does not provide a stable tab ID, so identical tabs cannot be distinguished after a reorder.
- Revalidate the browser process before activation. Never open a URL to approximate selecting a missing tab. A stale tab produces an explanatory message and can be refreshed.
- Search matches every whitespace-separated query term against title, URL or browser name. Preserve the selected tab by identity when refreshing/filtering where possible.
- Browser queries include whatever windows the browser exposes to its scripting interface; private-window visibility and profile completeness depend on the browser. Firefox and extension-based collection are outside this version.
