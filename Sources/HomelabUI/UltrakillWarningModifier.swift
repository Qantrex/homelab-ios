import SwiftUI
import HomelabKit

/// The one-time warning when the personality picker lands on Ultrakill (`UltrakillWarning`). The pick is undone at
/// once and only applied by "Enable", which also remembers that the warning was seen; "Back" leaves the previous level.
private struct UltrakillWarningModifier: ViewModifier {
    @Bindable var model: AppModel
    @State private var previous: Personality?
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .onAppear { previous = model.settings.voice }
            .onChange(of: model.settings.voice) { old, new in
                if new == .ultrakill, model.settings.needsWarning(for: .ultrakill) {
                    model.settings.voice = previous ?? old
                    asking = true
                } else {
                    previous = new
                }
            }
            .alert(UltrakillWarning.title, isPresented: $asking) {
                Button(UltrakillWarning.back, role: .cancel) {}
                Button(UltrakillWarning.enable) {
                    model.settings.confirmUltrakill()
                    previous = .ultrakill
                }
            } message: {
                Text(UltrakillWarning.message)
            }
    }
}

extension View {
    /// Asks once before Ultrakill is switched on from `model.settings.voice`.
    func ultrakillWarning(_ model: AppModel) -> some View { modifier(UltrakillWarningModifier(model: model)) }
}
