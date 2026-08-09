import ForerunCore
import SwiftData
import SwiftUI

@main
struct ForerunApp: App {
    /// Built once, at launch. A SwiftData schema error surfaces here and nowhere else, so the
    /// failure path has to be a real screen rather than a crash — a user whose store is corrupt
    /// needs a way out that is not "delete the app."
    private let container: Result<ModelContainer, any Error>

    init() {
        container = Result { try ForerunStore.container() }
    }

    var body: some Scene {
        WindowGroup {
            switch container {
            case .success(let container):
                RootView()
                    .modelContainer(container)
            case .failure(let error):
                StoreFailureView(error: error)
            }
        }
    }
}
