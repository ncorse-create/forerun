import ForerunCore
import SwiftUI

/// The snippet Siri and Spotlight show alongside the spoken answer.
///
/// Same restraint as the Today screen: the sentences and who they are for, and nothing else. No
/// count, no progress, no "3 of 7."
struct IntentStepsView: View {
    let rows: [IntentStepRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                Text("Nothing due.")
                    .font(TypeRamp.body())
                    .foregroundStyle(Palette.muted)
            } else {
                ForEach(rows.prefix(6)) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Palette.forAudience(row.audience))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.copy)
                                .font(TypeRamp.body())
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(row.eventTitle) · \(row.whenLabel)")
                                .font(TypeRamp.micro())
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.paper)
    }
}
