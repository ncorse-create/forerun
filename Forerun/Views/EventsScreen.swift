import ForerunCore
import SwiftData
import SwiftUI

/// Placeholder. Built in Sprint 3.
struct EventsScreen: View {
    var body: some View {
        NavigationStack {
            EmptyStateSentence(sentence: "Nothing tracked yet. Tap an event to have Forerun plan the run-up.")
                .frame(maxHeight: .infinity)
                .paperBackground()
                .navigationTitle("Events")
        }
    }
}
