import SwiftUI

@main
struct VoiceApp: App {
    @StateObject private var store = VoiceStore()
    @AppStorage("appearanceMode") private var appearance = "system"
    @State private var splash = true
    var body: some Scene {
        WindowGroup {
            ContentView().overlay { if splash { ZStack { VoiceTheme.background.ignoresSafeArea(); VStack(spacing: 20) { Image("MurmurMark").resizable().scaledToFit().frame(width: 110, height: 110); Text("Murmur").font(.largeTitle.bold()); ProgressView() } } } }.task { try? await Task.sleep(nanoseconds: 600_000_000); splash = false }.environmentObject(store).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    await store.liveActivity.clearOrphans()
                    #if DEBUG
                    await store.runStreamingSmokeTestIfRequested()
                    await store.runModelSmokeTestIfRequested()
                    await store.runLiveCorrectionSmokeTestIfRequested()
                    await store.runNotesFeatureSmokeTestIfRequested()
                    await store.runRecordFixesTestIfRequested()
                    await store.runSpeakerSmokeTestIfRequested()
                    await store.runManagementTestIfRequested()
                    await store.runPreferencesTestIfRequested()
                    await store.runLiveActivityTestIfRequested()
                    #endif
                }


        }
    }
}
