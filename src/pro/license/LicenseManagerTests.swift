import XCTest

final class LicenseManagerTests: XCTestCase {
    var clock: MockClock!
    var keychain: MockKeychain!
    var api: MockLicenseAPI!
    var defaults: UserDefaults!
    var suiteName: String!
    var manager: LicenseManager!

    override func setUp() {
        super.setUp()
        suiteName = "com.lwouis.alt-tab-macos.tests.license"
        defaults = TestDefaults.make(suiteName)
        clock = MockClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        keychain = MockKeychain()
        api = MockLicenseAPI()
        manager = LicenseManager(clock: clock, keychain: keychain, api: api, defaults: defaults)
    }

    override func tearDown() {
        TestDefaults.tearDown(defaults, suiteName)
        super.tearDown()
    }

    func testFeaturesAreAvailableWithoutInitializingOrActivating() {
        XCTAssertEqual(manager.state, .pro)
        XCTAssertTrue(manager.isProAvailable)
        XCTAssertFalse(manager.isProLocked)
    }

    func testInitializeAndRefreshIgnoreExpiredTrialAndInvalidLicense() {
        setupTrial(daysAgo: 365)
        setupActivatedLicense(variantId: "pro")
        defaults.set(false, forKey: "lastValidationResult")
        let storedDefaults = defaults.dictionaryRepresentation()
        manager.initialize()
        clock.advance(days: 365)
        manager.refreshState()
        drainMainQueue()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertTrue(manager.isProAvailable)
        XCTAssertFalse(manager.isProLocked)
        XCTAssertTrue(api.activateCalls.isEmpty)
        XCTAssertTrue(api.deactivateCalls.isEmpty)
        XCTAssertTrue(keychain.valueCalls.isEmpty)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, storedDefaults as NSDictionary)
    }

    // MARK: - Launch / initialize

    func testFirstLaunchEnablesAllFeaturesWithoutStartingTrial() {
        let storedDefaults = defaults.dictionaryRepresentation()
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(manager.trialStartDate)
        XCTAssertTrue(keychain.valueCalls.isEmpty)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, storedDefaults as NSDictionary)
    }

    func testRelaunchPreservesTrialStartAndFeatureAccess() {
        setupTrial(daysAgo: 365)
        let originalStart = manager.trialStartDate
        manager.initialize()
        clock.advance(days: 365)
        let manager2 = LicenseManager(clock: clock, keychain: keychain, api: api, defaults: defaults)
        manager2.initialize()
        XCTAssertEqual(manager2.trialStartDate, originalStart)
        XCTAssertEqual(manager2.state, .pro)
        XCTAssertFalse(manager2.isProLocked)
    }

    func testTrialDatesDoNotRestrictFeatureAccess() {
        for daysAgo in [-2, 0, 7, 13, 14, 365] {
            setupTrial(daysAgo: daysAgo)
            manager.initialize()
            XCTAssertEqual(manager.state, .pro)
            XCTAssertTrue(manager.isProAvailable)
            XCTAssertFalse(manager.isProLocked)
        }
    }

    func testExistingLicenseDoesNotRequireValidationResult() {
        keychain.setValue("KEY", account: LicenseManager.keychainKeyAccount)
        keychain.setValue("instance-1", account: LicenseManager.keychainInstanceAccount)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertTrue(keychain.valueCalls.isEmpty)
    }

    func testInitializeAndRefreshDoNotContactServerOrChangeStoredLicense() {
        setupActivatedLicense(variantId: "pro_lifetime")
        let oldValidation = clock.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970
        defaults.set(oldValidation, forKey: "lastValidation")
        manager.initialize()
        manager.refreshState()
        drainMainQueue()
        XCTAssertTrue(api.activateCalls.isEmpty)
        XCTAssertTrue(api.deactivateCalls.isEmpty)
        XCTAssertTrue(keychain.valueCalls.isEmpty)
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "instance-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro_lifetime")
        XCTAssertEqual(defaults.double(forKey: "lastValidation"), oldValidation)
        XCTAssertEqual(manager.state, .pro)
    }

    // MARK: - Activate

    func testActivateSuccessTransitionsToPro() {
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: "alice@example.com"))
        let exp = expectation(description: "activate")
        manager.activate("LICENSE-KEY-ABC") { result in
            if case .failure(let e) = result { XCTFail("expected success, got \(e)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-KEY-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "inst-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro")
        XCTAssertEqual(defaults.bool(forKey: "lastValidationResult"), true)
        XCTAssertEqual(defaults.double(forKey: "lastValidation"), clock.now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(manager.customerEmail, "alice@example.com")
    }

    func testActivateFailurePreservesState() {
        setupTrial(daysAgo: 3)
        manager.initialize()
        api.activateResult = .failure(LicenseAPIError.activationRejected("invalid"))
        let exp = expectation(description: "activate")
        manager.activate("BAD-KEY") { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testActivateWithoutCustomerEmailLeavesCustomerEmailNil() {
        api.activateResult = .success(ActivateResult(instanceId: "inst", variantId: nil, customerEmail: nil))
        let exp = expectation(description: "activate")
        manager.activate("KEY") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNil(manager.customerEmail)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainVariantAccount))
    }

    func testActivateSeatLimitExceededSurfacesInstances() {
        setupTrial(daysAgo: 3)
        manager.initialize()
        let instances = [
            ActiveInstance(id: "inst-old-1", machineName: "Work laptop", lastSeenAt: clock.now.addingTimeInterval(-86400)),
            ActiveInstance(id: "inst-old-2", machineName: nil, lastSeenAt: clock.now.addingTimeInterval(-86400 * 7)),
        ]
        api.activateResult = .failure(LicenseAPIError.seatLimitExceeded(instances: instances))
        let exp = expectation(description: "activate")
        var surfaced: [ActiveInstance] = []
        manager.activate("KEY") { result in
            if case .failure(let e) = result, case LicenseAPIError.seatLimitExceeded(let list) = e {
                surfaced = list
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(surfaced.count, 2)
        XCTAssertEqual(surfaced[0].id, "inst-old-1")
        XCTAssertEqual(surfaced[0].machineName, "Work laptop")
        XCTAssertNil(surfaced[1].machineName)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testActivateFailsAndRollsBackIfKeychainWriteFails() {
        setupTrial(daysAgo: 3)
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: "alice@example.com"))
        keychain.setValueStatus = { _ in errSecAuthFailed }
        let exp = expectation(description: "activate")
        var surfaced: Error?
        manager.activate("LICENSE-KEY-ABC") { result in
            if case .failure(let e) = result { surfaced = e }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        guard case LicenseAPIError.keychainWriteFailed(let account, let status) = surfaced as? LicenseAPIError ?? .noData else {
            return XCTFail("expected keychainWriteFailed, got \(String(describing: surfaced))")
        }
        XCTAssertEqual(account, LicenseManager.keychainKeyAccount)
        XCTAssertEqual(status, errSecAuthFailed)
        XCTAssertEqual(manager.state, .pro)
        // Rollback: nothing should remain in keychain
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainVariantAccount))
        // Validation timestamps must NOT be written either
        XCTAssertNil(defaults.object(forKey: "lastValidation"))
        XCTAssertNil(defaults.object(forKey: "lastValidationResult"))
        XCTAssertNil(defaults.object(forKey: "customerEmail"))
    }

    func testActivateRollsBackPartialKeychainWritesOnLaterFailure() {
        setupTrial(daysAgo: 3)
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: nil))
        // First write succeeds, second fails. Verifies the rollback removes the first one too.
        var calls = 0
        keychain.setValueStatus = { _ in
            calls += 1
            return calls == 1 ? errSecSuccess : errSecAuthFailed
        }
        let exp = expectation(description: "activate")
        manager.activate("LICENSE-KEY-ABC") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
    }

    func testActivateFailureKeepsAnAlreadyStoredLicense() {
        setupActivatedLicense(variantId: "pro")
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "inst-2", variantId: "pro", customerEmail: nil))
        // Re-activating with a different key on a machine whose keychain stopped accepting writes.
        keychain.setValueStatus = { _ in errSecAuthFailed }
        let exp = expectation(description: "activate")
        manager.activate("LICENSE-KEY-XYZ") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        // The rollback must not delete what the failed write left untouched.
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "instance-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro")
        XCTAssertEqual(manager.state, .pro)
    }

    func testDeactivateInstanceCallsApiWithoutTouchingLocalState() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        api.deactivateResult = .success(())
        let exp = expectation(description: "deactivate-instance")
        manager.deactivateInstance(licenseKey: "KEY", instanceId: "other-instance") { result in
            if case .failure(let e) = result { XCTFail("expected success, got \(e)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(api.deactivateCalls.count, 1)
        XCTAssertEqual(api.deactivateCalls[0].0, "KEY")
        XCTAssertEqual(api.deactivateCalls[0].1, "other-instance")
        // Local keychain is untouched — the deactivated instance was another machine.
        XCTAssertNotNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertEqual(manager.state, .pro)
    }

    // MARK: - Deactivate

    func testDeactivateSuccessKeepsFeaturesAvailableDuringTrial() {
        setupActivatedLicense(variantId: nil)
        setupTrial(daysAgo: 3)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)

        api.deactivateResult = .success(())
        let exp = expectation(description: "deactivate")
        manager.deactivate { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
    }

    func testDeactivateSuccessKeepsFeaturesAvailableAfterTrialExpiry() {
        setupActivatedLicense(variantId: nil)
        setupTrial(daysAgo: 100)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)

        api.deactivateResult = .success(())
        let exp = expectation(description: "deactivate")
        manager.deactivate { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
    }

    func testDeactivateFailurePreservesState() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        api.deactivateResult = .failure(LicenseAPIError.deactivationRejected)
        let exp = expectation(description: "deactivate")
        manager.deactivate { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNotNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testDeactivateWithoutLicenseErrors() {
        manager.initialize()
        let exp = expectation(description: "deactivate")
        manager.deactivate { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(api.deactivateCalls.count, 0)
    }

    // MARK: - State change callback

    func testOnStateChangedFiresOnInitialize() {
        var observed: [LicenseState] = []
        manager.onStateChanged = { observed.append($0) }
        manager.initialize()
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed, [.pro])
    }

    func testOnStateChangedFiresOnActivateSuccess() {
        var observed: [LicenseState] = []
        manager.onStateChanged = { observed.append($0) }
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "i", variantId: nil, customerEmail: nil))
        let exp = expectation(description: "activate")
        manager.activate("K") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed.last, .pro)
        XCTAssertGreaterThanOrEqual(observed.count, 2)
    }

    // MARK: - isProLocked + onBeforeProUnlock

    func testInitializeRestoresPreferencesBeforeNotifyingObservers() {
        var events: [String] = []
        manager.onBeforeProUnlock = { events.append("restore") }
        manager.onStateChanged = { _ in events.append("notify") }
        manager.initialize()
        manager.refreshState()
        XCTAssertEqual(events, ["restore", "notify"])
    }

    func testActivationRestoresPreferencesBeforeNotifyingObservers() {
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "i", variantId: nil, customerEmail: nil))
        var events: [String] = []
        manager.onBeforeProUnlock = { events.append("restore") }
        manager.onStateChanged = { _ in events.append("notify") }
        let exp = expectation(description: "activate")
        manager.activate("K") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(events, ["restore", "notify"])
        XCTAssertEqual(manager.state, .pro)
    }

    #if DEBUG
    func testOnBeforeProUnlockFiresOnMockProUser() {
        manager.initialize()
        var hookFired = false
        manager.onBeforeProUnlock = { hookFired = true }
        manager.mockProUser()
        XCTAssertTrue(hookFired)
        XCTAssertEqual(manager.state, .pro)
    }

    func testMockProUserDoesNotAlterPersistedLicense() {
        setupActivatedLicense(variantId: "pro_lifetime")
        defaults.set("real@example.com", forKey: LicenseManager.customerEmailKey)
        let storedDefaults = defaults.dictionaryRepresentation()
        manager.mockProUser()
        manager.refreshState()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertEqual(manager.customerEmail, "john@cool-software.com")
        XCTAssertFalse(manager.isLifetimeVariant)
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "instance-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro_lifetime")
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, storedDefaults as NSDictionary)
    }

    func testMockTrialDayDoesNotAlterPersistedLicense() {
        setupActivatedLicense(variantId: "pro_lifetime")
        defaults.set("real@example.com", forKey: LicenseManager.customerEmailKey)
        let storedDefaults = defaults.dictionaryRepresentation()
        manager.mockTrialDay(4)
        manager.refreshState()
        XCTAssertEqual(manager.state, .trial(daysRemaining: 11))
        XCTAssertEqual(manager.daysSinceTrialStart, 3)
        XCTAssertNil(manager.customerEmail)
        XCTAssertFalse(manager.isLifetimeVariant)
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "instance-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro_lifetime")
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, storedDefaults as NSDictionary)
    }
    #endif

    // MARK: - Trial day

    func testTrialDay_isNilWithoutTrial() {
        XCTAssertNil(manager.trialDay)
    }

    func testTrialDay_isOneIndexed() {
        setupTrial(daysAgo: 0)
        XCTAssertEqual(manager.trialDay, 1)
        setupTrial(daysAgo: 34)
        XCTAssertEqual(manager.trialDay, 35)
        setupTrial(daysAgo: 99)
        XCTAssertEqual(manager.trialDay, 100)
    }

    func testTrialDay_isNilWhenClockIsBeforeTrialStart() {
        setupTrial(daysAgo: -2)
        XCTAssertNil(manager.trialDay)
    }

    // MARK: - Helpers

    private func setupTrial(daysAgo: Int) {
        let start = clock.now.addingTimeInterval(-Double(daysAgo) * 86400)
        defaults.set(start.timeIntervalSince1970, forKey: "trialStartDate")
    }

    private func setupActivatedLicense(variantId: String?) {
        keychain.setValue("LICENSE-ABC", account: LicenseManager.keychainKeyAccount)
        keychain.setValue("instance-1", account: LicenseManager.keychainInstanceAccount)
        if let variantId { keychain.setValue(variantId, account: LicenseManager.keychainVariantAccount) }
        defaults.set(clock.now.timeIntervalSince1970, forKey: "lastValidation")
        defaults.set(true, forKey: "lastValidationResult")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}

// MARK: - Mocks

final class MockClock: Clock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    func advance(days: Int) { now = now.addingTimeInterval(Double(days) * 86400) }
}

final class MockKeychain: Keychain {
    private var store: [String: String] = [:]
    var setValueStatus: (String) -> OSStatus = { _ in errSecSuccess }
    var removeStatus: (String) -> OSStatus = { _ in errSecSuccess }

    private(set) var valueCalls: [String] = []

    func value(account: String) -> String? {
        valueCalls.append(account)
        return store[account]
    }

    @discardableResult
    func setValue(_ value: String, account: String) -> OSStatus {
        let status = setValueStatus(account)
        if status == errSecSuccess { store[account] = value }
        return status
    }

    @discardableResult
    func remove(account: String) -> OSStatus {
        let status = removeStatus(account)
        if status == errSecSuccess { store.removeValue(forKey: account) }
        return status
    }
}

final class MockLicenseAPI: LicenseAPI {
    var activateResult: Result<ActivateResult, Error> = .failure(LicenseAPIError.noData)
    var deactivateResult: Result<Void, Error> = .failure(LicenseAPIError.noData)

    var activateCalls: [String] = []
    var deactivateCalls: [(String, String)] = []

    func activate(_ licenseKey: String, completion: @escaping (Result<ActivateResult, Error>) -> Void) {
        activateCalls.append(licenseKey)
        let r = activateResult
        DispatchQueue.main.async { completion(r) }
    }

    func deactivate(_ licenseKey: String, instanceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        deactivateCalls.append((licenseKey, instanceId))
        let r = deactivateResult
        DispatchQueue.main.async { completion(r) }
    }
}
