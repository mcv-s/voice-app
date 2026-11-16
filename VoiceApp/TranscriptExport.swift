import AVFoundation
import SwiftUI
import UIKit

struct TranscriptCue: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var speaker: Int? = nil
}
enum TranscriptExports {
    static func vtt(_ transcript: Transcript) -> String {
        let source = transcript.cues?.isEmpty == false ? transcript.cues! : [TranscriptCue(start: 0, end: max(0.001, transcript.duration), text: transcript.text)]
        var previous = 0.0
        let cues = source.enumerated().map { index, cue in
            let start = max(previous, max(0, cue.start))
            let end = max(start + 0.001, cue.end)
            previous = end
            let text = cue.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let spoken = cue.speaker.map { "<v Speaker \($0 + 1)>\(text)</v>" } ?? text
            return "\(index + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(spoken)\n"
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n")
    }
    static func markdown(_ transcript: Transcript) -> String {
        let title = transcript.title.replacingOccurrences(of: "\n", with: " ")
        let summary = transcript.summary.map { "## Summary\n\n\($0)\n\n## Transcript\n\n" } ?? ""
        return "# \(title)\n\n\(summary)\(transcript.text)\n"
    }
    static func filename(_ transcript: Transcript) -> String {
        let safe = transcript.title.map { $0.isLetter || $0.isNumber || " -_".contains($0) ? $0 : "_" }
        return String(String(safe).prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Transcript" : String(String(safe).prefix(80))
    }
    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

actor AudioExporter {
    func m4a(from source: URL) throws -> Data {
        let input = try AVAudioFile(forReading: source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.processingFormat.sampleRate,
                                       AVNumberOfChannelsKey: input.processingFormat.channelCount, AVEncoderBitRateKey: 48000]
        // Scope closes/finalizes the container before it is read for export.
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            while input.framePosition < input.length {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(16000 * 5, input.length - input.framePosition))
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)!
                try input.read(into: buffer); try output.write(from: buffer)
            }
        }
        return try Data(contentsOf: url)
    }
}

struct CopyTextButton: View {
    let text: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    var body: some View {
        Button {
            UIPasteboard.general.string = text; copied = true; reset?.cancel()
            reset = Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if !Task.isCancelled { copied = false } }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .accessibilityLabel(copied ? "Copied" : "Copy transcript")
            .onDisappear { reset?.cancel() }
    }
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct TranscriptExportMenu: View {
    let transcript: Transcript
    let audio: URL?
    var body: some View {
        NavigationLink { ExportPage(transcript: transcript, audio: audio) } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("Export recording")
    }
}

@MainActor
final class ExportFiles: ObservableObject {
    @Published var files: [String: URL] = [:]
    @Published var audioError: String?
    @Published var preparing = false
    private var folder: URL?
    func refreshText(_ transcript: Transcript) {
        guard let folder else { return }
        for (suffix, text) in [("txt", transcript.text), ("md", TranscriptExports.markdown(transcript)), ("vtt", TranscriptExports.vtt(transcript))] {
            let url = folder.appendingPathComponent(TranscriptExports.filename(transcript)).appendingPathExtension(suffix)
            do { try Data(text.utf8).write(to: url, options: .atomic); files[suffix] = url } catch { audioError = error.localizedDescription }
        }
    }
    func prepare(_ transcript: Transcript, audio: URL?) async {
        guard folder == nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceAppExport-" + UUID().uuidString, isDirectory: true)
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = TranscriptExports.filename(transcript)
            for (suffix, text) in [("txt", transcript.text), ("md", TranscriptExports.markdown(transcript)), ("vtt", TranscriptExports.vtt(transcript))] {
                let url = folder.appendingPathComponent(name).appendingPathExtension(suffix)
                try Data(text.utf8).write(to: url, options: .atomic); files[suffix] = url
            }
            if let audio {
                files["original"] = audio; preparing = true
                defer { preparing = false }
                let data = try await AudioExporter().m4a(from: audio)
                let url = folder.appendingPathComponent(name).appendingPathExtension("m4a")
                try data.write(to: url, options: .atomic); files["m4a"] = url
            }
        } catch { audioError = error.localizedDescription }
    }
}

struct ExportPage: View {
    @EnvironmentObject private var store: VoiceStore
    let transcript: Transcript
    let audio: URL?
    @StateObject private var exports = ExportFiles()
    @State private var sharing: ExportItem?
    private var current: Transcript { store.recordings.first(where: { $0.id == transcript.id }) ?? transcript }
    private var active: Bool { store.activeRecordingID == transcript.id && store.recording }
    var body: some View {
        List {
            Section("Audio") {
                if active { Label("Stop recording to export the complete audio.", systemImage: "mic.fill") }
                else if audio != nil {
                    file("M4A audio", suffix: "m4a", icon: "waveform")
                    file("Original audio", suffix: "original", icon: "waveform.path")
                    if exports.preparing { HStack { ProgressView(); Text("Preparing audio…") } }
                } else { Text("This older text-only recording has no saved audio.").foregroundColor(.secondary) }
                if let error = exports.audioError { Text(error).foregroundColor(.red) }
            }
            Section {
                file("WebVTT subtitles", suffix: "vtt", icon: "captions.bubble")
                file("Plain text", suffix: "txt", icon: "doc.text")
                file("Markdown", suffix: "md", icon: "text.alignleft")
            } header: { Text("Subtitles") } footer: {
                Text(transcript.cues?.isEmpty == false ? "Tap to share a file. Hold and drag to move it to another app." : "Tap to share, or hold and drag a file. This transcript has no phrase timings; VTT uses one cue for the full recording.")
            }
        }.scrollContentBackground(.hidden).background(VoiceTheme.background).navigationTitle("Export")
            .task { await exports.prepare(current, audio: active ? nil : audio) }
            .onChange(of: current.text) { _ in exports.refreshText(current) }
            .sheet(item: $sharing) { FileShareSheet(url: $0.url) }
    }
    private func file(_ title: String, suffix: String, icon: String) -> some View {
        let url = exports.files[suffix]
        return Button {
            if let url { sharing = ExportItem(url: url) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let url { Text(url.lastPathComponent).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                Spacer()
                if url == nil { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
            }.padding(.vertical, 8)
        }.disabled(url == nil).listRowBackground(VoiceTheme.surface)
            .onDrag {
                guard let url else { return NSItemProvider() }
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.suggestedName = url.lastPathComponent
                return provider
            }
    }
}
