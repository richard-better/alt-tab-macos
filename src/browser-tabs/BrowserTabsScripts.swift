import Foundation

enum BrowserTabsScripts {
    static func collect(_ targets: [BrowserTabsTarget]) throws -> String {
        let data = try JSONEncoder().encode(targets)
        let targetsJSON = String(decoding: data, as: UTF8.self)
        return """
        var targets = \(targetsJSON);
        var result = {tabs: [], issues: []};
        targets.forEach(function(target) {
            try {
                var app = Application(Number(target.processId));
                if (!app.running()) return;
                var safari = target.browser === 'com.apple.Safari';
                app.windows().forEach(function(w) {
                    var selected = safari ? w.currentTab().index() : w.activeTabIndex();
                    w.tabs().forEach(function(t, offset) {
                        result.tabs.push({browser: target.browser, processId: Number(target.processId),
                            windowId: String(w.id()), tabId: safari ? null : String(t.id()),
                            index: offset + 1, title: String(safari ? t.name() : t.title()),
                            url: String(t.url() || ''), active: selected === offset + 1});
                    });
                });
            } catch (error) {
                result.issues.push({browser: target.browser, code: Number(error.errorNumber || error.number || 0)});
            }
        });
        JSON.stringify(result);
        """
    }

    static func activate(_ tab: BrowserTab) throws -> String {
        let data = try JSONEncoder().encode(tab)
        let targetJSON = String(decoding: data, as: UTF8.self)
        return """
        var target = \(targetJSON);
        var result = {activated: false, code: null};
        try {
            var app = Application(Number(target.processId));
            if (!app.running()) throw new Error('Browser closed');
            var safari = target.browser === 'com.apple.Safari';
            var found = false;
            app.windows().some(function(w) {
                if (safari && String(w.id()) !== target.windowId) return false;
                return w.tabs().some(function(t, offset) {
                    if (safari) {
                        if (offset + 1 !== target.index || String(t.url() || '') !== target.url
                            || String(t.name()) !== target.title) return false;
                    } else if (String(t.id()) !== target.tabId) return false;
                    if (safari) {
                        w.currentTab = t;
                        w.miniaturized = false;
                    } else {
                        w.activeTabIndex = offset + 1;
                        w.minimized = false;
                    }
                    w.index = 1;
                    app.activate();
                    found = true;
                    return true;
                });
            });
            result.activated = found;
        } catch (error) {
            result.code = Number(error.errorNumber || error.number || 0);
        }
        JSON.stringify(result);
        """
    }
}
