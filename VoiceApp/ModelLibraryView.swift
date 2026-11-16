import SwiftUI

struct ModelLibraryView: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var library: ModelLibrary
    @ObservedObject var refinement: RefinementSettings
    @ObservedObject var notesAI: NotesAISettings
    var body: some View {
        List {
            if library.downloading != nil {
                Section { Text(library.message); ProgressView(value: library.progress); Button("Cancel download", role: .cancel) { library.cancelDownload() } }
            } else if !library.message.isEmpty && library.message != "Model is selected." { Section { Text(library.message).font(.footnote) } }
            Section {
                row(.fastConformer); row(.moonshineTiny)
            } header: { Text("Recommended live voice models") } footer: {
                Text("FastConformer Transducer is the default recommendation for speed and efficiency. Try Moonshine Tiny for accuracy and optional speaker colors. Results vary with the room and speakers.")
            }
            Section("More live voice models") {
                ForEach(CaptionModel.allCases.filter { $0.isLive && ![.fastConformer, .moonshineTiny].contains($0) }) { row($0) }
            }
            Section {
                ForEach(CaptionModel.allCases.filter { $0.spec?.family == "whisper" }) { row($0) }
            } header: { Text("Optional Whisper models") } footer: { Text("Experimental correction can be slow and can make wording worse. Off by default. Downloading or selecting a model does not enable automatic correction. Run it from a recording, or opt in under Transcription settings.") }
            Section {
                ForEach(CaptionModel.allCases.filter { $0.isNotesAI }) { row($0) }
            } header: { Text("Titles & summaries · Beta") } footer: { Text("Optional local notes AI runs after Whisper. Enable it in Beta settings.") }
            Section("Speaker detection") { row(.speakers) }
            Section {
                ForEach(CaptionModel.allCases.filter { !$0.isLive && $0.spec?.family != "whisper" && !$0.isNotesAI && $0 != .speakers }) { row($0) }
            } header: { Text("Extra saved-text pass") } footer: { Text("An optional second transcription after stopping, for another attempt at difficult audio. It takes longer and can replace the corrected transcript; original text is kept.") }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Models")
            .alert("Model", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) { Button("OK") { library.issue = nil } } message: { Text(library.issue ?? "") }
    }
    private func selected(_ model: CaptionModel) -> Bool { store.isSelected(model) }
    private func purpose(_ model: CaptionModel) -> String { model.purpose }
    private func row(_ model: CaptionModel) -> some View {
        NavigationLink { ModelDetailView(model: model, library: library, refinement: refinement, notesAI: notesAI) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.title + (model == .fastConformer ? " · Recommended" : "")).font(.headline)
                    Spacer()
                    Image(systemName: selected(model) ? "checkmark.circle.fill" : ModelCatalog.installed(model) ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundColor(selected(model) ? .accentColor : .secondary)
                }
                Text(purpose(model) + " · " + (model.isSupported ? model.sizeLabel : "iOS 17+"))
                    .font(.caption).foregroundColor(.secondary)
            }.padding(.vertical, 5)
        }
    }
}

struct ModelDetailView: View {
    @EnvironmentObject private var store: VoiceStore
    let model: CaptionModel
    @ObservedObject var library: ModelLibrary
    @ObservedObject var refinement: RefinementSettings
    @ObservedObject var notesAI: NotesAISettings
    @AppStorage("betaSpeakers") private var speakers = false
    private var selected: Bool { store.isSelected(model) }
    var body: some View {
        Form {
            Section {
                Text(model.title).font(.title2.bold())
                Text(model.details)
                LabeledContent("Used for", value: model.purpose)
                LabeledContent("Storage", value: model.sizeLabel)
                if let spec = model.spec { Link("Source & license", destination: spec.source) }
            }
            Section {
                if !model.isSupported { Text("Requires iOS 17 or later. Other models remain available on iPhone X.") }
                else if model == .speakers && store.selectedModel.spec?.family != "moonshine" {
                    Text("Select a Moonshine live voice model to download or use speaker detection.")
                    if ModelCatalog.installed(model) { Button("Remove model", role: .destructive) { store.removeModel(model) } }
                }
                else if ModelCatalog.installed(model) {
                    if selected { Label("Model is selected", systemImage: "checkmark.circle.fill").foregroundColor(VoiceTheme.accent).font(.headline) }
                    else { Button { useModel() } label: { Label("Use model", systemImage: "checkmark.circle") }.accessibilityIdentifier("use-model") }
                    if store.recording || store.busy { Text("Selections apply to your next recording.").font(.footnote).foregroundColor(.secondary) }
                    Button("Remove model", role: .destructive) { store.removeModel(model) }
                    if model == .apple { Text("Apple's speech resources are managed by iOS.").font(.footnote).foregroundColor(.secondary) }
                } else {
                    Button {
                        library.download(model) { useModel() }
                    } label: { Label("Download & use · \(model.sizeLabel)", systemImage: "arrow.down.circle") }
                        .disabled(library.downloading == model)
                }
                if library.downloading == model { ProgressView(value: library.progress); Button("Cancel download", role: .cancel) { library.cancelDownload() } }
                if !library.message.isEmpty && library.message != "Model is selected." { Text(library.message).font(.footnote).foregroundColor(.secondary) }
            }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
            .alert("Model", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) { Button("OK") { library.issue = nil } } message: { Text(library.issue ?? "") }
    }
    private func useModel() { store.selectModel(model) }

}
