import ForerunCore
import SwiftData
import SwiftUI

/// Placeholder. Built in Sprint 8 — restraint is the feature, so it stays empty until then.
struct TodayScreen: View {
    var body: some View {
        NavigationStack {
            EmptyStateSentence(sentence: "Nothing needs you today.")
                .frame(maxHeight: .infinity)
                .paperBackground()
                .navigationTitle("Today")
        }
    }
}
