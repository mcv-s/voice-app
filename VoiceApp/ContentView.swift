import SwiftUI

private let green = VoiceTheme.accent
private enum VoicePage: Hashable { case recording, transcript(UUID), export(UUID) }

struct ContentView: View {
    @EnvironmentObject private var store: VoiceStore
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage("recordTourPending") private var showTour = false
    @State private var undoPrompt = false
    @State private var tab = 0
    @State private var path: [VoicePage] = []
    @State private var captionPath: [VoicePage] = []
    var body: some View {
        Group {
            TabView(selection: $tab) {
                page(notes: false).tabItem { Label("Record", systemImage: "mic.fill") }.tag(0)
                page(notes: true).tabItem { Label("Recordings", systemImage: "waveform") }.tag(1)
                NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
            }
        }.onOpenURL { url in
            if url.scheme == "voiceapp" && url.host == "record" { tab = 0; captionPath = [] }
        }.tint(green).background(VoiceTheme.background.ignoresSafeArea())
            .toolbarBackground(VoiceTheme.background, for: .tabBar, .navigationBar)
            .fullScreenCover(isPresented: Binding(get: { !setupComplete }, set: { _ in })) { SetupFlow().tint(green) }
            .overlay(alignment: .bottom) { if setupComplete && showTour && tab == 0 { RecordTour().padding(.bottom, 82) } }
            .background(ShakeToUndo { if !store.deletedRecordings.isEmpty { undoPrompt = true } }.frame(width: 0, height: 0))
            .alert("Undo delete?", isPresented: $undoPrompt) { Button("Restore recording") { store.undoDelete() }; Button("Cancel", role: .cancel) {} } message: { Text("Restore the last deleted recording and its audio.") }
            .alert("Transcription", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private func page(notes: Bool) -> some View {
        NavigationStack(path: notes ? $path : $captionPath) {
            Group { if notes { notesList } else { CaptionsPanel(saveAudio: true) } }.background(VoiceTheme.background)
                .navigationTitle(notes ? "Recordings" : "Record").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !notes {
                        ToolbarItem(placement: .navigationBarLeading) { NavigationLink { AppearancePage() } label: { Image(systemName: "paintbrush") }.accessibilityLabel("Appearance") }
                        ToolbarItem(placement: .navigationBarTrailing) { NavigationLink { TranscriptionSettingsPage() } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Transcription settings") }
                    }
                    if !notes && (!store.text.isEmpty || store.activeRecordingID != nil) {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            CopyTextButton(text: store.text)
                            if let item = store.recordings.first(where: { $0.id == (store.activeRecordingID ?? store.lastSavedID) }) {
                                TranscriptExportMenu(transcript: item, audio: store.audioURL(for: item))
                            }
                        }
                    }
                }
                .navigationDestination(for: VoicePage.self) { page in
                    switch page {
                    case .recording:
                        CaptionsPanel(saveAudio: true).navigationTitle("Recording").navigationBarTitleDisplayMode(.inline)
                            .navigationBarBackButtonHidden(store.recording || store.busy)
                            .onChange(of: store.busy) { busy in
                                if !busy, !store.recording, let id = store.lastSavedID { path = [.transcript(id)] }
                            }
                            .onChange(of: store.lastSavedID) { id in
                                if let id, !store.recording { path = [.transcript(id)] }
                            }
                    case .transcript(let id): TranscriptPage(id: id)
                    case .export(let id):
                        if let item = store.recordings.first(where: { $0.id == id }) { ExportPage(transcript: item, audio: store.audioURL(for: item)) }
                    }
                }
        }
    }

    private var notesList: some View {
        VStack(spacing: 0) {
            List {
                if store.recordings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No recordings yet").font(.headline)
                        Text("Record a note or meeting to save its audio and transcript.").foregroundColor(.secondary)
                    }.padding(.vertical, 20).listRowSeparator(.hidden)
                }
                ForEach(store.recordings) { item in
                    Button { path.append(.transcript(item.id)) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.audioFile == nil ? "doc.text" : "waveform").font(.title2).foregroundColor(green)
                                .frame(width: 42, height: 48)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item.title).font(.headline).foregroundColor(.primary).lineLimit(2)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                                Text(item.audioFile == nil ? "Text only" : "Audio · \(timeLabel(item.duration))").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.contextMenu {
                        Button { path.append(.export(item.id)) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = item.text } label: { Label("Copy text", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete", systemImage: "trash").foregroundColor(.red) }.tint(.red)
                    }.swipeActions {
                        Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete", systemImage: "trash").foregroundColor(.red) }.tint(.red)
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            VStack(spacing: 10) {
                if !store.deletedRecordings.isEmpty { Button { store.undoDelete() } label: { Label("Undo delete", systemImage: "arrow.uturn.backward") }.font(.subheadline) }
                if store.refiningID != nil { Label(store.refinementStatus, systemImage: "sparkles").font(.caption).foregroundColor(.secondary) }
                Button {
                    Task {
                        await store.start(saveAudio: true)
                        if store.recording { path.append(.recording) }
                        else if let id = store.lastSavedID { path.append(.transcript(id)) }
                    }
                } label: {
                    Label(store.busy ? "Preparing…" : "Record", systemImage: "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(20)
                        .foregroundColor(.white).background(VoiceTheme.button, in: RoundedRectangle(cornerRadius: 16))
                }.disabled(store.busy || store.recording)
            }.padding(18)
        }
    }
}

private struct CaptionsPanel: View {
    @EnvironmentObject private var store: VoiceStore
    @AppStorage("captionSize") private var captionSize = 36.0
    @AppStorage("transcriptFont") private var family = "system"
    @AppStorage("transcriptBold") private var bold = false
    @AppStorage("transcriptItalic") private var italic = false
    let saveAudio: Bool
    var body: some View {
        VStack(spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView {
                    if store.captionBlocks.isEmpty {
                        Text(store.text.isEmpty ? (store.recording ? "Listening…" : "Tap Record to see speech here.") : store.text)
                            .font(TranscriptTypography.font(size: captionSize, family: family, bold: bold, italic: italic)).lineSpacing(8)
                            .foregroundColor(store.text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(20)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(store.captionBlocks) { block in
                                StableCaptionParagraph(block: block, size: captionSize)
                            }
                        }.padding(20).transaction { $0.animation = nil }
                    }
                    Color.clear.frame(height: 1).id("end")
                }.background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .onChange(of: store.captionScrollVersion) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 12) {
                Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
                if store.recording && !store.correctionStatus.isEmpty {
                    Label(store.correctionStatus == "Whisper correction complete" ? "Corrected" : "Whisper", systemImage: "sparkles").font(.caption).foregroundColor(green)
                        .accessibilityLabel(store.correctionStatus)
                }
                Spacer(minLength: 0)
                MicrophoneLevel(level: store.level, active: store.recording && !store.paused && !store.muted, hint: store.microphoneHint)
                Text(timeLabel(store.elapsed)).font(.caption.monospacedDigit())
            }
            if store.recording && !store.paused && !store.muted && store.microphoneHint != "Microphone active" {
                Text(store.microphoneHint).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.refinementStatus.isEmpty && !store.recording {
                Text(store.refinementStatus).font(.caption).foregroundColor(.secondary)
            }
            if store.recording {
                HStack(spacing: 14) {
                    control(store.paused ? "play.fill" : "pause.fill", label: store.paused ? "Resume recording" : "Pause recording", fill: VoiceTheme.surface, color: green) { store.togglePause() }
                    control(store.muted ? "mic.slash.fill" : "mic.fill", label: store.muted ? "Unmute microphone" : "Mute microphone", fill: store.muted ? Color.red.opacity(0.15) : VoiceTheme.surface, color: store.muted ? .red : green) { store.toggleMute() }
                    control("stop.fill", label: "Stop recording", fill: VoiceTheme.button, color: .white) { store.stop() }
                }
            } else {
                Button { Task { await store.start(saveAudio: true) } } label: {
                    HStack { if store.busy { ProgressView().tint(.white) }; Image(systemName: "mic.fill"); Text(store.busy ? "Finishing…" : "Record") }
                        .font(.title3.bold()).frame(maxWidth: .infinity).padding(20)
                        .foregroundColor(.white).background(VoiceTheme.button, in: RoundedRectangle(cornerRadius: 16))
                }.disabled(store.busy)
            }

        }.padding(18)
    }
    private func control(_ icon: String, label: String, fill: Color, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title2).frame(maxWidth: .infinity).frame(height: 62).foregroundColor(color).background(fill, in: RoundedRectangle(cornerRadius: 16)) }
            .accessibilityLabel(label)
    }

}

private struct MicrophoneLevel: View {
    let level: Float
    let active: Bool
    let hint: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill").font(.system(size: 10)).foregroundColor(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray4))
                    Capsule().fill(level > 0.9 ? Color.orange : green)
                        .frame(width: geometry.size.width * CGFloat(active ? min(max(level, 0), 1) : 0))
                }
            }.frame(width: 64, height: 5).animation(.easeOut(duration: 0.08), value: level)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Microphone level")
            .accessibilityValue(active ? "\(Int(level * 100)) percent. \(hint)" : "Off")
    }
}

private struct TranscriptPage: View {
    @EnvironmentObject private var store: VoiceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = AudioPlayback()
    @AppStorage("captionSize") private var captionSize = 36.0
    @AppStorage("transcriptFont") private var family = "system"
    @AppStorage("transcriptBold") private var bold = false
    @AppStorage("transcriptItalic") private var italic = false
    let id: UUID
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var titleDraft = ""
    private var item: Transcript? { store.recordings.first { $0.id == id } }
    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(item.title).font(.title.bold())
                        Text(item.date.formatted(date: .long, time: .shortened)).font(.subheadline).foregroundColor(.secondary)
                        if item.audioFile != nil && store.activeRecordingID != id {
                            VStack(spacing: 12) {
                                HStack {
                                    Button { playback.toggle() } label: {
                                        Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 48, height: 48)
                                    }.accessibilityLabel(playback.playing ? "Pause recording" : "Play recording")
                                    Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(playback.duration, 0.01)).accessibilityLabel("Audio position")
                                }
                                HStack {
                                    Text(timeLabel(playback.position)); Spacer(); Text(timeLabel(playback.duration))
                                }.font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                if let error = playback.error { Text(error).font(.caption).foregroundColor(.red) }
                            }.padding(16).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        if store.refiningID == id { Label("Improving transcript…", systemImage: "sparkles").font(.subheadline).foregroundColor(.secondary) }
                        if store.generatingNotesID == id {
                            HStack { ProgressView(); Text(store.notesAIMessage.isEmpty ? "Processing notes…" : store.notesAIMessage).font(.caption).foregroundColor(.secondary) }
                        }
                        if let summary = item.summary {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Summary", systemImage: "sparkles").font(.headline)
                                Text(summary).font(.body).textSelection(.enabled)
                            }
                        }
                        if !store.notesAIMessage.isEmpty && store.generatingNotesID == nil {
                            Text(store.notesAIMessage).font(.caption).foregroundColor(.secondary)
                        }
                        if editing {
                            TextEditor(text: $draft).font(.title3).frame(minHeight: 400).accessibilityLabel("Edit transcript")
                        } else {
                            Text(item.text.isEmpty ? "No speech was recognized. Your audio is saved above." : item.text)
                                .font(TranscriptTypography.font(size: captionSize, family: family, bold: bold, italic: italic)).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let original = item.originalText {
                            DisclosureGroup("Original live text") { Text(original).font(.body).textSelection(.enabled).padding(.top, 8) }
                        }
                    }.padding(24)
                }.navigationTitle("Transcript").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            CopyTextButton(text: editing ? draft : item.text)
                            TranscriptExportMenu(transcript: item, audio: store.audioURL(for: item))
                            if editing {
                                Button { store.update(id, text: draft); editing = false } label: { Image(systemName: "checkmark") }.accessibilityLabel("Save transcript")
                            } else {
                                Menu {
                                    Button { draft = item.text; editing = true } label: { Label("Edit transcript", systemImage: "pencil") }.disabled(store.activeRecordingID == id)
                                    Button { titleDraft = item.title; renaming = true } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
                                    Menu {
                                        Button("Refine with Whisper") { store.refineRecording(id, model: store.refinement.liveModel) }
                                        Button("Run saved-text pass") { store.refineRecording(id, model: store.refinement.selectedModel) }
                                        Button("Generate title · Beta") { store.generateNotes(id, force: true, title: true, summary: false) }
                                        Button("Generate summary · Beta") { store.generateNotes(id, force: true, title: false, summary: true) }
                                    } label: { Label("Process recording", systemImage: "sparkles") }
                                        .disabled(store.generatingNotesID != nil || store.refiningID != nil || store.recording || store.busy)
                                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").foregroundColor(.red) }.tint(.red)
                                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Recording options")
                            }
                        }
                    }
                    .alert("Rename recording", isPresented: $renaming) {
                        TextField("Title", text: $titleDraft)
                        Button("Save") { store.rename(id, title: titleDraft) }
                        Button("Cancel", role: .cancel) {}
                    }
                    .confirmationDialog("Delete this transcript and its audio recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete recording", role: .destructive) { playback.stop(); store.delete(id); dismiss() }
                    }
                    .task(id: id) { playback.load(store.audioURL(for: item)) }
                    .onDisappear { playback.stop() }
            } else { Text("Recording unavailable") }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: VoiceStore
    var body: some View { SettingsForm(library: store.models) }
}
private struct SettingsForm: View {
    @EnvironmentObject private var store: VoiceStore
    @ObservedObject var library: ModelLibrary
    @State private var confirmReset = false
    @State private var finalReset = false
    @State private var resetting = false
    var body: some View {
        Form {
            Section {
                NavigationLink { ModelLibraryView(library: library, refinement: store.refinement, notesAI: store.notesAISettings) } label: { Label("Models", systemImage: "square.stack.3d.up") }
                NavigationLink { TranscriptionSettingsPage() } label: { Label("Transcription settings", systemImage: "waveform") }
            }
            Section {
                NavigationLink { AppearancePage() } label: { Label("Appearance", systemImage: "paintbrush") }
                NavigationLink { BetaPage(refinement: store.refinement, notesAI: store.notesAISettings, library: library) } label: { Label("Beta", systemImage: "flask") }
                NavigationLink { ManageDataPage(library: library) } label: {
                    Label("Manage Data · " + ByteCountFormatter.string(fromByteCount: library.downloadedBytes, countStyle: .decimal), systemImage: "internaldrive")
                }
            }
            Section {
                Button(resetting ? "Resetting…" : "Reset app", role: .destructive) { confirmReset = true }.disabled(resetting)
            } footer: { Text("Reset removes recordings, downloaded models and preferences, then starts setup again.") }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Settings")
            .alert("Reset Murmur?", isPresented: $confirmReset) {
                Button("Continue", role: .destructive) { Task { try? await Task.sleep(nanoseconds: 300_000_000); finalReset = true } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes all recordings, model downloads and settings from this app.") }
            .alert("Permanently erase all app data?", isPresented: $finalReset) {
                Button("Erase and restart setup", role: .destructive) { Task { resetting = true; _ = await store.resetApp(); resetting = false } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This cannot be undone. Export anything you want to keep first.") }
    }
}

private func timeLabel(_ seconds: Double) -> String {
    String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
}


private struct CaptionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct StableCaptionParagraph: View {
    let block: LiveCaptionBlock
    let size: Double
    @AppStorage("transcriptFont") private var family = "system"
    @AppStorage("transcriptBold") private var bold = false
    @AppStorage("transcriptItalic") private var italic = false
    @State private var reservedHeight: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let speaker = block.speaker { Text("Speaker \(speaker + 1)").font(.caption.bold()).foregroundColor(VoiceTheme.speaker(speaker)) }
            Text(block.text).foregroundColor(VoiceTheme.speaker(block.speaker)).font(TranscriptTypography.font(size: size, family: family, bold: bold, italic: italic)).lineSpacing(8)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            .background(GeometryReader { geometry in Color.clear.preference(key: CaptionHeightKey.self, value: geometry.size.height) })
            .onPreferenceChange(CaptionHeightKey.self) { reservedHeight = max(reservedHeight, $0) }
            .frame(minHeight: reservedHeight, alignment: .topLeading)
            .onChange(of: size) { _ in reservedHeight = 0 }
            .onChange(of: family) { _ in reservedHeight = 0 }
            .onChange(of: bold) { _ in reservedHeight = 0 }
            .onChange(of: italic) { _ in reservedHeight = 0 }
            .accessibilityLabel(block.text + (block.corrected ? ". Revised by Whisper." : ""))
            .transaction { $0.animation = nil }
        }
    }
}
