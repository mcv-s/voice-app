import SwiftUI
import UIKit

struct TranscriptionSettingsPage: View {
    @EnvironmentObject private var store: VoiceStore
    var body: some View {
        TranscriptionOptions(refinement: store.refinement, library: store.models)
    }
}
private struct TranscriptionOptions: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var refinement: RefinementSettings
    @ObservedObject var library: ModelLibrary
    @AppStorage("betaSpeakers") private var speakers = false
    var body: some View {
        Form {
            LiveActivityOption(controller: store.liveActivity)
            Section {
                Toggle("Live Whisper corrections", isOn: $refinement.liveEnabled)
                NavigationLink { ModelDetailView(model: refinement.liveModel, library: library, refinement: refinement, notesAI: store.notesAISettings) } label: { Text(refinement.liveModel.title) }
                if !ModelCatalog.installed(refinement.liveModel) { Text("Download the correction model to use Whisper.").font(.footnote).foregroundColor(.secondary) }
            } footer: { Text("Experimental and off by default. Corrections are not consistently good: Whisper can lag and replace correct words with mistakes. You can instead run it manually from a recording.") }
            Section("Listening") { ListeningModeOptions() }
            Section {
                Toggle("Detect different speakers · Beta", isOn: $speakers)
                if speakers {
                    NavigationLink { ModelDetailView(model: .speakers, library: library, refinement: refinement, notesAI: store.notesAISettings) } label: { Label("Speaker model", systemImage: "person.2") }
                }
            } footer: { Text("Moonshine only. Optional speaker colors require the small speaker model. Changes apply to the next recording.") }
            Section {
                Toggle("Extra saved-text pass", isOn: $refinement.enabled)
                if refinement.enabled {
                    NavigationLink { ModelLibraryView(library: library, refinement: refinement, notesAI: store.notesAISettings) } label: { LabeledContent("Saved-text model", value: refinement.selectedModel.title) }
                }
            } footer: { Text("After you stop and Whisper finishes, transcribe the full recording again using another model. This takes extra time and may improve difficult audio. Original wording is preserved. Summaries run afterwards.") }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Transcription settings").navigationBarTitleDisplayMode(.inline)
    }
}

struct ManageDataPage: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var library: ModelLibrary
    private var downloaded: [CaptionModel] {
        CaptionModel.allCases.filter { $0.spec != nil && ModelCatalog.installed($0) }.sorted { ($0.spec?.bytes ?? 0) > ($1.spec?.bytes ?? 0) }
    }
    var body: some View {
        List {
            Section {
                ForEach(downloaded) { model in
                    NavigationLink { ModelDetailView(model: model, library: library, refinement: store.refinement, notesAI: store.notesAISettings) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(model.title); Text(model.sizeLabel).font(.caption).foregroundColor(.secondary) }
                            Spacer()
                            if store.isSelected(model) { Image(systemName: "checkmark.circle.fill").foregroundColor(VoiceTheme.accent) }
                        }
                    }.swipeActions { Button(role: .destructive) { store.removeModel(model) } label: { Label("Remove download", systemImage: "trash").foregroundColor(.red) }.tint(.red) }
                }
                if downloaded.isEmpty { Text("No downloaded models") }
            } header: { Text("Models · " + ByteCountFormatter.string(fromByteCount: library.downloadedBytes, countStyle: .decimal)) } footer: { Text("Largest first. Swipe left to remove a download. Your only downloaded live voice model is protected.") }

        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Manage Data")
            .alert("Model", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) { Button("OK") { library.issue = nil } } message: { Text(library.issue ?? "") }
    }
}

struct SetupFlow: View {
    @EnvironmentObject private var store: VoiceStore
    @AppStorage("setupComplete") private var complete = false
    @AppStorage("recordTourPending") private var tour = false
    @AppStorage("captionSize") private var size = 36.0
    @State private var step = 0
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                ProgressView(value: Double(step), total: 4).tint(VoiceTheme.accent)
                ScrollView { VStack(alignment: .leading, spacing: 24) {
                    switch step {
                    case 0:
                        Image("MurmurMark").resizable().scaledToFit().frame(height: 95).accessibilityHidden(true)
                        Text("Welcome to Murmur").font(.largeTitle.bold())
                        Text("Read conversations as they happen, or record notes and meetings to return to later.").font(.title3)
                        Label("Transcription stays on this iPhone", systemImage: "iphone")
                        Text("Choose a comfortable text size and an offline model. Model downloads need internet once.").foregroundColor(.secondary)
                    case 1:
                        Text("Make it easy to read").font(.largeTitle.bold())
                        Text("You can change this anytime with the paintbrush.").foregroundColor(.secondary)
                        Slider(value: $size, in: 20...64, step: 1).accessibilityLabel("Transcript text size")
                        Text("\(Int(size)) pt").font(.caption)
                        Group { Text("Your words appear here, clearly and comfortably.").font(.system(size: size, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    case 2:
                        Text("Choose your voice model").font(.largeTitle.bold())
                        Text("Both run offline after download. Choose one to download or use an existing model.").foregroundColor(.secondary)
                        SetupModels(library: store.models)
                    case 3:
                        Text("Make it yours").font(.largeTitle.bold())
                        SetupPreferences(notesAI: store.notesAISettings)
                    default:
                        Text("Ready for your first recording").font(.largeTitle.bold())
                        Label("Record saves audio and live text", systemImage: "mic.fill")
                        Label("Pause takes a break; mute keeps time with silence", systemImage: "pause.fill")
                        Label("Recordings holds your notes, audio and exports", systemImage: "waveform")
                        Text("Next, a short guide shows the controls on Record. You can adjust listening mode and Whisper in transcription settings.").foregroundColor(.secondary)
                        NavigationLink { TranscriptionSettingsPage() } label: { Label("Customize transcription", systemImage: "waveform") }
                    }
                } }
                Spacer(minLength: 0)
                HStack {
                    if step > 0 { Button("Back") { step -= 1 }.padding() }
                    Button(step == 4 ? "Start using Murmur" : "Continue") {
                        if step == 4 { tour = true; complete = true } else { step += 1 }
                    }.font(.headline).frame(maxWidth: .infinity).padding(18).foregroundColor(.white).background(VoiceTheme.button, in: RoundedRectangle(cornerRadius: 16))
                        .disabled(step == 2 && (!ModelCatalog.installed(store.selectedModel) || !store.selectedModel.isLive))
                }
            }.padding(24).background(VoiceTheme.background).toolbar(.hidden, for: .navigationBar)
        }.tint(VoiceTheme.accent).interactiveDismissDisabled()
    }
}
private struct SetupPreferences: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var notesAI: NotesAISettings
    @AppStorage("appearanceMode") private var appearance = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Theme", selection: $appearance) { Text("Automatic").tag("system"); Text("Light").tag("light"); Text("Dark green").tag("dark") }.pickerStyle(.segmented)
            Picker("Listening", selection: $store.ambientListening) { Text("Conversation").tag(false); Text("Ambient").tag(true) }.pickerStyle(.segmented)
            Text("Ambient lifts quiet room sound, including TV and distant voices.").font(.footnote).foregroundColor(.secondary)
            Toggle("Automatic titles · Beta", isOn: $notesAI.automaticTitles)
            Toggle("Automatic summaries · Beta", isOn: $notesAI.automaticSummaries)
            Text("Both start off and need an optional local language model. You can generate either manually later.").font(.footnote).foregroundColor(.secondary)
            NavigationLink { AppearancePage() } label: { Label("Font and appearance", systemImage: "textformat") }
        }
    }
}
private struct SetupModels: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var library: ModelLibrary
    var body: some View {
        VStack {
            VStack(spacing: 14) {
                option(.fastConformer, detail: "Recommended · Speed & efficiency")
                option(.moonshineTiny, detail: "Accuracy & multiple speakers · speaker colors optional")
                NavigationLink { ModelLibraryView(library: library, refinement: store.refinement, notesAI: store.notesAISettings) } label: { Label("Choose a different model", systemImage: "square.stack.3d.up") }.padding()
                if let downloading = library.downloading {
                    Text("Downloading " + downloading.title).font(.footnote)
                    ProgressView(value: library.progress)
                    Button("Cancel download", role: .cancel) { library.cancelDownload() }
                }
                if !library.message.isEmpty { Text(library.message).font(.footnote).foregroundColor(.secondary) }
                if ModelCatalog.installed(store.selectedModel) { Label("Selected: " + store.selectedModel.title, systemImage: "checkmark.circle.fill").font(.footnote) }
            }
        }.alert("Model", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) { Button("OK") { library.issue = nil } } message: { Text(library.issue ?? "") }
    }
    private func option(_ model: CaptionModel, detail: String) -> some View {
        Button { library.download(model) { store.selectModel(model) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title).font(.headline)
                    Text(detail).font(.subheadline)
                    Text(ModelCatalog.installed(model) ? "Use downloaded model" : "Download · " + model.sizeLabel).font(.caption)
                }
                Spacer()
                Image(systemName: store.isSelected(model) ? "checkmark.circle.fill" : "arrow.down.circle")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }.disabled(library.downloading != nil)
    }
}

struct RecordTour: View {
    @AppStorage("recordTourPending") private var pending = false
    @State private var step = 0
    private let hints = [("paintbrush", "Make it comfortable", "The paintbrush at the top left opens Appearance: text size, preview and theme."), ("ellipsis", "Adjust listening", "The three dots at the top right open transcription settings here: Ambient, Whisper and speakers."), ("mic.fill", "Start recording", "Tap Record to save audio and see words. During recording, Stop is on the right, with Pause and Mute beside it.")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hints[step].1, systemImage: hints[step].0).font(.title3.bold())
            Text(hints[step].2)
            HStack { Button("Skip guide") { pending = false }; Spacer(); Button(step == 2 ? "Done" : "Next") { if step == 2 { pending = false } else { step += 1 } }.bold() }
        }.padding(20).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 20)).shadow(radius: 12).padding(20)
    }
}

struct ShakeToUndo: UIViewControllerRepresentable {
    let action: () -> Void
    func makeUIViewController(context: Context) -> ShakeController { let controller = ShakeController(); controller.action = action; return controller }
    func updateUIViewController(_ controller: ShakeController, context: Context) { controller.action = action }
    final class ShakeController: UIViewController {
        var action: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) { if motion == .motionShake { action?() } }
    }
}

#if DEBUG
extension VoiceStore {
    func runManagementTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--management-test"), Bundle.main.bundleIdentifier == "com.voiceapp.setupqa" else { return }
        var report: [String: Bool] = [:]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let audio = Self.directory.appendingPathComponent("Recordings/qa.wav")
            try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: documents.appendingPathComponent("streaming-fixture.wav"), to: audio)
            let item = Transcript(text: "Recoverable test recording", audioFile: "qa.wav", duration: 6)
            recordings.insert(item, at: 0); delete(item.id)
            report["delete_preserves_audio"] = !recordings.contains(where: { $0.id == item.id }) && FileManager.default.fileExists(atPath: audio.path)
            undoDelete()
            report["undo_restores_recording_and_audio"] = recordings.contains(where: { $0.id == item.id }) && FileManager.default.fileExists(atPath: audio.path)
            selectedModel = .moonshineTiny
            removeModel(.moonshineTiny)
            report["selected_model_removal_switches_to_transducer"] = !ModelCatalog.installed(.moonshineTiny) && selectedModel == .fastConformer
            removeModel(.fastConformer)
            report["last_live_model_removal_explains_reason"] = ModelCatalog.installed(.fastConformer) && models.issue?.contains("only downloaded live") == true
            models.issue = nil
            UserDefaults.standard.set(true, forKey: "setupComplete")
            report["reset_succeeds"] = await resetApp()
            report["reset_starts_setup_without_model_download"] = !UserDefaults.standard.bool(forKey: "setupComplete") && selectedModel == .fastConformer && models.downloadedBytes == 0 && recordings.isEmpty && !FileManager.default.fileExists(atPath: audio.path)
        } catch { report["unexpected_error"] = false; self.error = error.localizedDescription }
        report["passed"] = !report.values.contains(false)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: documents.appendingPathComponent("management-result.json")) }
    }
}
#endif
