import ForerunCore
import SwiftData
import SwiftUI

@main
struct ForerunApp: App {
    /// Built once, at launch. A SwiftData schema error surfaces here and nowhere else, so the
    /// failure path has to be a real screen rather than a crash — a user whose store is corrupt
    /// needs a way out that is not "delete the app."
    private let container: Result<ModelContainer, any Error>
    @State private var app: AppEnvironment?

    init() {
        NavigationBarAppearance.apply()

        // The process-wide container. App Intents run inside this same process, so they must not
        // build their own — two containers over one store file do not share change notifications.
        let result: Result<ModelContainer, any Error> = ForerunStore.shared
            .map { .success($0) } ?? Result { try ForerunStore.container() }
        container = result

        // Background task registration has to happen before launch finishes, so it cannot wait
        // for a view's `.task`. The environment is built here for the same reason.
        if case .success(let container) = result {
            let environment = AppEnvironment(container: container)
            _app = State(initialValue: environment)
            // Before launch finishes, so a cold launch from a notification tap still delivers
            // its response.
            environment.registerNotificationHandling()
            BackgroundRefresh.register {
                await environment.refresh()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch (container, app) {
            case (.success, .some(let app)):
                RootView()
                    .modelContainer(app.context.container)
                    .environment(app)
                    .task { await app.start() }
            case (.failure(let error), _):
                StoreFailureView(error: error)
            case (.success, .none):
                // Unreachable: `app` is set in the same branch that produced `.success`.
                StoreFailureView(error: ForerunStartupError.environmentUnavailable)
            }
        }
    }
}

enum ForerunStartupError: LocalizedError {
    case environmentUnavailable

    var errorDescription: String? {
        "Forerun could not start its services."
    }
}
