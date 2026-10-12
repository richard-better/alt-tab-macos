import XCTest

/// Pins the sequencing of the first-run permissions window: which of the two steps is live, how each
/// step's card collapses or expands, and when the bottom bar offers "Set up later".
///
/// The window walks one step at a time - Accessibility first (mandatory, the only alternative is
/// quitting), then Automation (waivable, `.skipped` resolves it like `.granted`). Every card
/// state is recomputed from the two live `PermissionStatus` values rather than from a stored cursor,
/// so revoking a permission walks the sequence backwards instead of stranding the user on a step.
final class PermissionFlowTests: XCTestCase {
    func testCompletedSetupDoesNotBlockLaterLaunchesWithoutBrowserConsent() {
        XCTAssertTrue(PermissionFlow.isStartupComplete(accessibility: .granted, automation: .notGranted, setupCompleted: true))
        XCTAssertFalse(PermissionFlow.isStartupComplete(accessibility: .notGranted, automation: .granted, setupCompleted: true))
        XCTAssertFalse(PermissionFlow.isStartupComplete(accessibility: .skipped, automation: .skipped, setupCompleted: true))
    }

    func testFirstSetupNeedsAutomationConsentOrAnExplicitSkip() {
        XCTAssertFalse(PermissionFlow.isStartupComplete(accessibility: .granted, automation: .notGranted, setupCompleted: false))
        XCTAssertTrue(PermissionFlow.isStartupComplete(accessibility: .granted, automation: .granted, setupCompleted: false))
        XCTAssertTrue(PermissionFlow.isStartupComplete(accessibility: .granted, automation: .skipped, setupCompleted: false))
    }

    func testAutomationNeedsAtLeastOneRunningBrowserAndAllRunningBrowsersAllowed() {
        XCTAssertEqual(PermissionFlow.automationStatus(results: [], skipped: false), .notGranted)
        XCTAssertEqual(PermissionFlow.automationStatus(results: [0, 0], skipped: false), .granted)
        XCTAssertEqual(PermissionFlow.automationStatus(results: [0, -1743], skipped: false), .notGranted)
        XCTAssertEqual(PermissionFlow.automationStatus(results: [-1744], skipped: false), .notGranted)
    }

    func testSkippingAutomationNeverMasksACompleteGrant() {
        XCTAssertEqual(PermissionFlow.automationStatus(results: [], skipped: true), .skipped)
        XCTAssertEqual(PermissionFlow.automationStatus(results: [0, -1743], skipped: true), .skipped)
        XCTAssertEqual(PermissionFlow.automationStatus(results: [0], skipped: true), .granted)
    }

    // MARK: - Fresh launch

    /// Nothing granted → the user is on Accessibility.
    func testFreshLaunchStartsOnAccessibility() {
        XCTAssertEqual(PermissionFlow.liveStep(accessibility: .notGranted, automation: .notGranted), .accessibility)
    }

    /// Automation is `.notGranted` too, but it is not the live step, so it collapses.
    func testFreshLaunchCollapsesAutomationAsUpcoming() {
        XCTAssertEqual(PermissionFlow.state(of: .automation, accessibility: .notGranted, automation: .notGranted), .upcoming)
    }

    /// The live step is the expanded one.
    func testFreshLaunchExpandsAccessibilityAsLive() {
        XCTAssertEqual(PermissionFlow.state(of: .accessibility, accessibility: .notGranted, automation: .notGranted), .live)
    }

    // MARK: - Advancing

    /// Granting Accessibility advances to Automation.
    func testAccessibilityGrantedMovesToAutomation() {
        XCTAssertEqual(PermissionFlow.liveStep(accessibility: .granted, automation: .notGranted), .automation)
    }

    /// The finished step shrinks to its title row.
    func testGrantedAccessibilityCollapsesAsDone() {
        XCTAssertEqual(PermissionFlow.state(of: .accessibility, accessibility: .granted, automation: .notGranted), .done)
    }

    /// Both granted → nothing left; the window closes.
    func testBothGrantedHasNoLiveStep() {
        XCTAssertNil(PermissionFlow.liveStep(accessibility: .granted, automation: .granted))
    }

    // MARK: - Waiving Automation

    /// "Set up later" persists `.skipped`, which resolves the step.
    func testSkippedAutomationHasNoLiveStep() {
        XCTAssertNil(PermissionFlow.liveStep(accessibility: .granted, automation: .skipped))
    }

    /// A waived step reads as finished, not as still pending.
    func testSkippedAutomationIsDone() {
        XCTAssertEqual(PermissionFlow.state(of: .automation, accessibility: .granted, automation: .skipped), .done)
    }

    // MARK: - Revocation walks backwards

    /// Losing Accessibility mid-flow sends the user back to step 1.
    func testRevokedAccessibilityReturnsToStepOne() {
        XCTAssertEqual(PermissionFlow.liveStep(accessibility: .notGranted, automation: .granted), .accessibility)
    }

    /// The already-granted second step stays `.done` while step 1 is live again - it is finished,
    /// just not reachable, which is different from never having been reached.
    func testRevokedAccessibilityCollapsesGrantedAutomationAsDone() {
        XCTAssertEqual(PermissionFlow.state(of: .automation, accessibility: .notGranted, automation: .granted), .done)
    }

    // MARK: - The waive option

    /// Offered on the Automation step only.
    func testWaiveOfferedOnlyOnAutomationStep() {
        XCTAssertTrue(PermissionFlow.showsWaiveOption(accessibility: .granted, automation: .notGranted))
        XCTAssertFalse(PermissionFlow.showsWaiveOption(accessibility: .notGranted, automation: .notGranted))
        XCTAssertFalse(PermissionFlow.showsWaiveOption(accessibility: .notGranted, automation: .granted))
    }

    /// Nothing to waive once the flow is resolved.
    func testWaiveNotOfferedWhenComplete() {
        XCTAssertFalse(PermissionFlow.showsWaiveOption(accessibility: .granted, automation: .granted))
        XCTAssertFalse(PermissionFlow.showsWaiveOption(accessibility: .granted, automation: .skipped))
    }

    // MARK: - Completion

    /// `isComplete` is exactly "no live step", over the whole grid of inputs.
    func testCompleteOnlyWhenNoLiveStep() {
        let statuses: [PermissionStatus] = [.granted, .notGranted, .skipped]
        for accessibility in statuses {
            for automation in statuses {
                XCTAssertEqual(
                    PermissionFlow.isComplete(accessibility: accessibility, automation: automation),
                    PermissionFlow.liveStep(accessibility: accessibility, automation: automation) == nil,
                    "accessibility:\(accessibility) automation:\(automation)")
            }
        }
    }

    // MARK: - After launch

    /// A skipped Automation offers to grant after all.
    func testSkippedAutomationOffersGrant() {
        XCTAssertTrue(PermissionFlow.offersGrantAfterSkip(.automation, accessibility: .granted, automation: .skipped))
    }

    /// Only a skip is reversed from the card: a granted or pending step, or Accessibility, never offers it.
    func testOnlySkippedAutomationOffersGrant() {
        XCTAssertFalse(PermissionFlow.offersGrantAfterSkip(.automation, accessibility: .granted, automation: .granted))
        XCTAssertFalse(PermissionFlow.offersGrantAfterSkip(.automation, accessibility: .granted, automation: .notGranted))
        XCTAssertFalse(PermissionFlow.offersGrantAfterSkip(.accessibility, accessibility: .granted, automation: .skipped))
    }

    /// While Accessibility is missing, it is the step to act on; the skip stays as it is.
    func testSkippedAutomationWaitsForAccessibility() {
        XCTAssertFalse(PermissionFlow.offersGrantAfterSkip(.automation, accessibility: .notGranted, automation: .skipped))
    }

    /// The bar's main button grants while a step is live, and closes once nothing is left.
    func testPrimaryActionGrantsUntilCompleteThenCloses() {
        XCTAssertEqual(PermissionFlow.primaryAction(accessibility: .notGranted, automation: .notGranted), .grant)
        XCTAssertEqual(PermissionFlow.primaryAction(accessibility: .granted, automation: .notGranted), .grant)
        XCTAssertEqual(PermissionFlow.primaryAction(accessibility: .granted, automation: .granted), .close)
        XCTAssertEqual(PermissionFlow.primaryAction(accessibility: .granted, automation: .skipped), .close)
    }
}
