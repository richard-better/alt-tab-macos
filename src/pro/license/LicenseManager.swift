import Foundation

class LicenseManager {
    static var keychainService: String {
        #if DEBUG
        if QaLifecycleEnvironment.enabled { return QaLifecycleEnvironment.namespace }
        #endif
        return "\(App.bundleIdentifier).license"
    }
    static var defaultsSuiteName: String {
        #if DEBUG
        if QaLifecycleEnvironment.enabled { return QaLifecycleEnvironment.namespace }
        #endif
        return "\(App.bundleIdentifier).license"
    }

    static let shared: LicenseManager = {
        let keychain = SystemKeychain(service: keychainService)
        return LicenseManager(
            clock: SystemClock(),
            keychain: keychain,
            api: RemoteLicenseClient(baseUrl: Endpoints.licenseApiBaseUrl, keychain: keychain),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!
        )
    }()

    static let trialDuration = 14
    static let keychainKeyAccount = "licenseKey"
    static let keychainInstanceAccount = "instanceId"
    static let keychainVariantAccount = "variantId"
    static let customerEmailKey = "customerEmail"
    static let lifetimeVariants: Set<String> = ["pro_lifetime"]

    let clock: Clock
    let keychain: Keychain
    let api: LicenseAPI
    let defaults: UserDefaults

    /// Called whenever `state` changes (including the initial `initialize()` assignment).
    /// Production wires this up in App.swift to refresh Menubar, sync Sparkle cookie, and notify ProTransitionManager.
    /// Tests leave it unset to avoid side effects.
    var onStateChanged: ((LicenseState) -> Void)?

    /// Restores preferences saved when features were locked, before observers refresh the UI.
    var onBeforeProUnlock: () -> Void = { }

    private(set) var state: LicenseState = .pro {
        didSet { onStateChanged?(state) }
    }

    #if DEBUG
    private var hasMockedLicense = false
    private var mockedTrialStartDate: Date?
    private var mockedCustomerEmail: String?
    private var mockedVariant: String?
    #endif

    var customerEmail: String? {
        #if DEBUG
        if hasMockedLicense { return mockedCustomerEmail }
        #endif
        return defaults.string(forKey: Self.customerEmailKey)
    }

    var isLifetimeVariant: Bool {
        #if DEBUG
        if hasMockedLicense { return mockedVariant.map(Self.lifetimeVariants.contains) ?? false }
        #endif
        guard let variant = keychain.value(account: Self.keychainVariantAccount) else { return false }
        return Self.lifetimeVariants.contains(variant)
    }

    var isProAvailable: Bool { state.isProAvailable }

    var isMocked: Bool {
        #if DEBUG
        return hasMockedLicense
        #else
        return false
        #endif
    }

    /// Only debug QA overlays can lock features. Normal launches always resolve to `.pro`.
    var isProLocked: Bool {
        switch state {
        case .pro, .trial: return false
        case .proExpired, .trialExpired: return true
        }
    }

    var trialStartDate: Date? {
        #if DEBUG
        if hasMockedLicense { return mockedTrialStartDate }
        #endif
        guard defaults.object(forKey: "trialStartDate") != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: "trialStartDate"))
    }

    var daysSinceTrialStart: Int {
        guard let start = trialStartDate else { return 0 }
        return Int(clock.now.timeIntervalSince(start) / 86400)
    }

    /// 1-indexed, like the "Day N" of `ProTransitionSpecs.md`. Nil when no trial ever started, or when the clock
    /// is set before the trial start, rather than a made-up day.
    var trialDay: Int? {
        guard let start = trialStartDate, clock.now >= start else { return nil }
        return daysSinceTrialStart + 1
    }

    init(clock: Clock, keychain: Keychain, api: LicenseAPI, defaults: UserDefaults) {
        self.clock = clock
        self.keychain = keychain
        self.api = api
        self.defaults = defaults
    }

    func initialize() {
        if !isMocked { onBeforeProUnlock() }
        state = computeState()
    }

    /// Preserves debug QA overlays and notifies observers only when the state changes.
    func refreshState() {
        let newState = computeState()
        if newState != state { state = newState }
    }

    func activate(_ licenseKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        api.activate(licenseKey) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    var writes: [(String, String)] = [
                        (Self.keychainKeyAccount, licenseKey),
                        (Self.keychainInstanceAccount, response.instanceId),
                    ]
                    if let variantId = response.variantId {
                        writes.append((Self.keychainVariantAccount, variantId))
                    }
                    var written: [String] = []
                    for (account, value) in writes {
                        let status = self.keychain.setValue(value, account: account)
                        if status != errSecSuccess {
                            // Only roll back what this activation actually wrote. A failed write left the
                            // previous value in place, so removing that account would delete a license we
                            // never wrote, which is the exact loss `setValue` avoids by not deleting.
                            written.forEach { self.keychain.remove(account: $0) }
                            completion(.failure(LicenseAPIError.keychainWriteFailed(account: account, status: status)))
                            return
                        }
                        written.append(account)
                    }
                    self.defaults.set(self.clock.now.timeIntervalSince1970, forKey: "lastValidation")
                    self.defaults.set(true, forKey: "lastValidationResult")
                    if let email = response.customerEmail, !email.isEmpty {
                        self.defaults.set(email, forKey: Self.customerEmailKey)
                    }
                    self.onBeforeProUnlock()
                    self.state = .pro
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func deactivate(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let licenseKey = keychain.value(account: Self.keychainKeyAccount),
              let instanceId = keychain.value(account: Self.keychainInstanceAccount) else {
            completion(.failure(LicenseAPIError.invalidKey))
            return
        }
        api.deactivate(licenseKey, instanceId: instanceId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.keychain.remove(account: Self.keychainKeyAccount)
                    self.keychain.remove(account: Self.keychainInstanceAccount)
                    self.keychain.remove(account: Self.keychainVariantAccount)
                    self.defaults.removeObject(forKey: "lastValidation")
                    self.defaults.removeObject(forKey: "lastValidationResult")
                    self.defaults.removeObject(forKey: Self.customerEmailKey)
                    self.state = self.computeState()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Remote-deactivate a specific instance that isn't this machine — used to reclaim a seat
    /// before re-running activation. Does not touch local keychain/UserDefaults state.
    func deactivateInstance(licenseKey: String, instanceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        api.deactivate(licenseKey, instanceId: instanceId) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    func computeState() -> LicenseState {
        #if DEBUG
        if hasMockedLicense { return state }
        #endif
        return .pro
    }

    #if DEBUG
    /// `day` is 1-based: day 1 is the day the trial started.
    func mockTrialDay(_ day: Int) {
        hasMockedLicense = true
        mockedTrialStartDate = clock.now.addingTimeInterval(-Double(day - 1) * 86400)
        mockedCustomerEmail = nil
        mockedVariant = nil
        let daysRemaining = Self.trialDuration - (day - 1)
        state = daysRemaining > 0 ? .trial(daysRemaining: daysRemaining) : .trialExpired
    }

    func mockProUser() {
        hasMockedLicense = true
        mockedTrialStartDate = nil
        mockedCustomerEmail = "john@cool-software.com"
        mockedVariant = "pro"
        onBeforeProUnlock()
        state = .pro
    }
    #endif
}
