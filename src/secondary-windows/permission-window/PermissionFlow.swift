import Foundation

enum PermissionStatus {
    case granted
    case notGranted
    case skipped
}

enum PermissionFlow {
    enum Step: Equatable {
        case accessibility
        case automation
    }

    enum StepState: Equatable {
        case done
        case live
        case upcoming
    }

    /// An empty list means no supported browser is running, so setup remains optional and unresolved.
    static func automationStatus(results: [Int32], skipped: Bool) -> PermissionStatus {
        if !results.isEmpty && results.allSatisfy({ $0 == 0 }) { return .granted }
        return skipped ? .skipped : .notGranted
    }

    static func liveStep(accessibility: PermissionStatus, automation: PermissionStatus) -> Step? {
        if accessibility != .granted { return .accessibility }
        if automation == .notGranted { return .automation }
        return nil
    }

    static func state(of step: Step, accessibility: PermissionStatus, automation: PermissionStatus) -> StepState {
        if step == liveStep(accessibility: accessibility, automation: automation) { return .live }
        switch step {
            case .accessibility: return accessibility == .granted ? .done : .upcoming
            case .automation: return automation == .notGranted ? .upcoming : .done
        }
    }

    static func showsWaiveOption(accessibility: PermissionStatus, automation: PermissionStatus) -> Bool {
        return liveStep(accessibility: accessibility, automation: automation) == .automation
    }

    static func isStartupComplete(accessibility: PermissionStatus, automation: PermissionStatus, setupCompleted: Bool) -> Bool {
        accessibility == .granted && (setupCompleted || automation != .notGranted)
    }

    static func isComplete(accessibility: PermissionStatus, automation: PermissionStatus) -> Bool {
        return liveStep(accessibility: accessibility, automation: automation) == nil
    }

    static func offersGrantAfterSkip(_ step: Step, accessibility: PermissionStatus, automation: PermissionStatus) -> Bool {
        return step == .automation && automation == .skipped && accessibility == .granted
    }

    enum PrimaryAction: Equatable {
        case grant
        case close
    }

    static func primaryAction(accessibility: PermissionStatus, automation: PermissionStatus) -> PrimaryAction {
        return isComplete(accessibility: accessibility, automation: automation) ? .close : .grant
    }
}
