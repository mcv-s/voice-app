import SwiftUI
import UIKit

enum VoiceTheme {
    static let background = adaptive(light: UIColor(red: 0.97, green: 0.98, blue: 0.96, alpha: 1), dark: UIColor(red: 0.025, green: 0.075, blue: 0.055, alpha: 1))
    static let surface = adaptive(light: .white, dark: UIColor(red: 0.055, green: 0.14, blue: 0.105, alpha: 1))
    static let button = Color(red: 0.10, green: 0.36, blue: 0.26)
    static let accent = adaptive(light: UIColor(red: 0.10, green: 0.36, blue: 0.26, alpha: 1), dark: UIColor(red: 0.43, green: 0.83, blue: 0.62, alpha: 1))
    private static func adaptive(light: UIColor, dark: UIColor) -> Color { Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light }) }
    static func speaker(_ index: Int?) -> Color {
        guard let index else { return .primary }
        return [accent, Color.blue, Color.orange, Color.purple, Color.cyan, Color.pink][index % 6]
    }
}

enum TranscriptTypography {
    static func font(size: Double, family: String, bold: Bool, italic: Bool) -> Font {
        let design: Font.Design = family == "rounded" ? .rounded : family == "serif" ? .serif : family == "monospaced" ? .monospaced : .default
        let font = Font.system(size: size, weight: bold ? .bold : .medium, design: design)
        return italic ? font.italic() : font
    }
}
struct AppearancePage: View {
    @AppStorage("captionSize") private var size = 36.0
    @AppStorage("appearanceMode") private var appearance = "system"
    @AppStorage("transcriptFont") private var family = "system"
    @AppStorage("transcriptBold") private var bold = false
    @AppStorage("transcriptItalic") private var italic = false
    var body: some View {
        Form {
            Section("Preview") {
                Text("The garden meeting starts on Saturday at ten. Bring a notebook and your ideas.")
                    .font(TranscriptTypography.font(size: size, family: family, bold: bold, italic: italic)).lineSpacing(8).padding(.vertical, 16)
            }.listRowBackground(VoiceTheme.surface)
            Section("Transcript size") {
                Slider(value: $size, in: 20...64, step: 1).accessibilityLabel("Transcript text size")
                Text("\(Int(size)) pt").font(.caption).foregroundColor(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) { Text("Automatic").tag("system"); Text("Light").tag("light"); Text("Dark green").tag("dark") }
                Picker("Font", selection: $family) { Text("System").tag("system"); Text("Rounded").tag("rounded"); Text("Serif").tag("serif"); Text("Monospaced").tag("monospaced") }
                Toggle("Bold", isOn: $bold)
                Toggle("Italic", isOn: $italic)
            }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Appearance")
    }
}

struct BetaPage: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var refinement: RefinementSettings
    @ObservedObject var notesAI: NotesAISettings
    @ObservedObject var library: ModelLibrary
    @AppStorage("betaSpeakers") private var speakers = false
    var body: some View {
        Form {
            Section { Text("Experimental features. All start switched off.").font(.footnote).foregroundColor(.secondary) }
            Section("Local notes AI") {
                Toggle("Automatic titles", isOn: $notesAI.automaticTitles)
                Toggle("Automatic summaries", isOn: $notesAI.automaticSummaries)
                NavigationLink { ModelDetailView(model: notesAI.selectedModel, library: library, refinement: refinement, notesAI: notesAI) } label: { Label("Local language model", systemImage: "sparkles") }
                NavigationLink { ModelLibraryView(library: library, refinement: refinement, notesAI: notesAI) } label: { Text("Other local language models") }
                Text("Both use the same selected model, after transcription processing finishes. You can also generate either from a recording. Summaries may miss or misinterpret details.").font(.footnote).foregroundColor(.secondary)
            }
            if let model = library.downloading { Section { Text("Downloading " + model.title); ProgressView(value: library.progress); Button("Cancel", role: .cancel) { library.cancelDownload() } } }
            if !library.message.isEmpty { Section { Text(library.message).font(.footnote) } }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Beta")
            .alert("Model download", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) { Button("OK") { library.issue = nil } } message: { Text(library.issue ?? "") }
    }
}

struct ListeningModeMenu: View {
    @EnvironmentObject private var store: VoiceStore
    var body: some View {
        Menu {
            Button { store.ambientListening = false } label: { Label("Conversation", systemImage: store.ambientListening ? "person.wave.2" : "checkmark") }
            Button { store.ambientListening = true } label: { Label("Ambient", systemImage: store.ambientListening ? "checkmark" : "ear") }
        } label: { Label(store.ambientListening ? "Ambient" : "Conversation", systemImage: store.ambientListening ? "ear" : "person.wave.2").font(.caption) }
            .accessibilityLabel("Listening mode: " + (store.ambientListening ? "Ambient" : "Conversation"))
    }
}
struct ListeningModeOptions: View {
    @EnvironmentObject private var store: VoiceStore
    var body: some View {
        Picker("Listening mode", selection: $store.ambientListening) { Text("Conversation").tag(false); Text("Ambient").tag(true) }
        Text("Ambient lifts quiet and distant sound for rooms, TV and public spaces. It also picks up more background noise. Both modes use unfiltered microphone input.").font(.footnote).foregroundColor(.secondary)
    }
}
