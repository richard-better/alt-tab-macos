# Permission flow

Accessibility is required to focus windows. Browser Automation is an optional second step for reading and switching tabs in Safari and Chrome. Screen Recording is never checked or requested.

- Accessibility comes first. Only quitting is offered until it is granted.
- Automation consent is separate for each running supported browser. The Grant button requests consent on the collector's serial background queue, without reading tabs or starting a script.
- Silent permission checks pass `askUserIfNeeded: false`. A denied browser does not prevent requests for other browsers. Denials offer Automation settings.
- With no running supported browser, the Automation step stays unresolved. Grant explains that Safari or Chrome must be opened. Set up later allows window switching immediately.
- Set up later persists the skipped state. A real grant takes precedence over that state.
- Completion is remembered independently of live browser permissions. Later launches require only Accessibility, even if browsers are closed or Automation has been revoked. Browser tabs still request consent when summoned or refreshed.
- Check permissions reopens the live status of both steps. Skipped Automation can be requested there again.
- Repeated Grant clicks cannot queue duplicate consent requests. A system consent dialog can take focus without dismissing setup.

`PermissionFlowTests` covers ordering, skipping, revocation, the complete status grid, empty browser lists, mixed consent, and grants after skipping. `BrowserTabsTests.testAutomationSetupRequestsEveryBrowserAndKeepsDenialsSeparate` covers consent requests without tab collection.
