import HomelabDesign
import HomelabKit
import SwiftUI

// Haptics in one place (research #10), next to `Motion` (HomelabDesign): success on an Approve or a started action,
// a selection tick on a tick-off, a toggle or a Deny, an error buzz when something didn't run, a warning when a
// refresh brings a new problem.

extension Motion {
    /// The haptic for a finished press or start (`ActionOutcome.feel`); an error buzz when it didn't run.
    static func haptic(_ outcome: ActionOutcome) -> SensoryFeedback {
        guard outcome.ok else { return .error }
        return switch outcome.feel {
        case .success: .success
        case .selection: .selection
        }
    }
}

extension View {
    /// A light selection tick each time `trigger` changes: a tile toggled, an item ticked off.
    func selectionFeedback<T: Equatable>(trigger: T) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }

    /// A warning tap when a refresh lists a problem the last answer didn't have (`ProblemWatch`), wherever the owner
    /// is in the app. Put it once, on the tabs.
    func newProblemFeedback(_ model: AppModel) -> some View {
        let watch = ProblemWatch(server: model.selected?.target, state: model.selectedStatus.snapshot?.state)
        return sensoryFeedback(trigger: watch) { old, new in ProblemWatch.warns(from: old, to: new) ? .warning : nil }
    }
}
