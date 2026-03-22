import SwiftUI

@main
struct GhostMicApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var jobStore: JobStore
    @StateObject private var queueProcessor: QueueProcessor

    init() {
        let settings = AppSettings()
        let jobStore = JobStore(settings: settings)

        _settings = StateObject(wrappedValue: settings)
        _jobStore = StateObject(wrappedValue: jobStore)
        _queueProcessor = StateObject(wrappedValue: QueueProcessor(jobStore: jobStore, settings: settings))
    }

    var body: some Scene {
        WindowGroup("Vukho.AI") {
            MainView()
                .environmentObject(settings)
                .environmentObject(jobStore)
                .environmentObject(queueProcessor)
                .task {
                    queueProcessor.start()
                }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
