import SwiftUI
import AVFoundation
import Speech
import OSLog

struct Transcript: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var text: String
    var audioFile: String?
    var originalText: String?
    var generatedTitle: String?
    var summary: String?
    var cues: [TranscriptCue]?
    var unfinished: Bool?
    var duration: TimeInterval
    var title: String { if let generatedTitle, !generatedTitle.isEmpty { return generatedTitle }; return text.isEmpty ? "Audio recording" : String(text.split(whereSeparator: { $0.isWhitespace }).prefix(7).joined(separator: " ")) }
}

@MainActor
final class VoiceStore: ObservableObject {
    @Published var text = ""
    @Published var captionBlocks: [LiveCaptionBlock] = []
    @Published var captionScrollVersion = 0
    @Published var correctionStatus = ""
    private var timeline = CaptionTimeline()
    private let correctionWorker = WhisperCorrectionWorker()
    private var correctionJobs: [CorrectionJob] = []
    private var correctionTask: Task<Void, Never>?
    private var liveCorrectionActive = false

    @Published var recordings: [Transcript] = []
    @Published var recording = false
    @Published var busy = false
    @Published private(set) var paused = false
    @Published private(set) var muted = false
    @Published var ambientListening = UserDefaults.standard.bool(forKey: "ambientListening") {
        didSet { UserDefaults.standard.set(ambientListening, forKey: "ambientListening"); syncAudioControls() }
    }
    @Published var status = "Ready"
    @Published var error: String?
    @Published var level: Float = 0
    @Published var microphoneDB: Float = -60
    @Published var microphoneInput = "Microphone"
    @Published var microphoneHint = "Tap Start, then speak or tap your microphone."
    @Published var elapsed: TimeInterval = 0
    @Published var selectedModel: CaptionModel = .fastConformer {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "captionModel") }
    }
    let models = ModelLibrary()
    let liveActivity = RecordingActivityController()
    private var finishBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    let notesAISettings = NotesAISettings()
    @Published var generatingNotesID: UUID?
    @Published var notesAIMessage = ""
    private let notesAI = NotesAI()
    private var notesAITask: Task<Void, Never>?
    private var attemptedNotes: Set<UUID> = []
    private var activeNotesModel: CaptionModel = .notesAI

    let refinement = RefinementSettings()
    @Published var refiningID: UUID?
    @Published var refinementStatus = ""
    private let refinementAudio = RefinementAudio()
    private let refiner = OfflineRecognizer()
    private var sessionRefinementModel: CaptionModel = .whisperBase
    private var refinementTask: Task<Void, Never>?
    private var captureForRefinement = false
    private var sessionSavesAudio = false
    @Published var lastSavedID: UUID?
    @Published private(set) var activeRecordingID: UUID?
    private var sessionCaptionModel: CaptionModel = .zipformer
    private var captureWritesAudio = false
    private var sessionCorrectionModel: CaptionModel = .whisperBase
    private var lastCheckpoint = Date.distantPast
    private let recognizer = CaptionEngine()
    private let audio = AudioCapture()
    private var loop: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var started = Date()
    private var interruption: NSObjectProtocol?
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceApp", isDirectory: true)
    @Published private(set) var deletedRecordings: [Transcript] = []
    private var trashURL: URL { Self.directory.appendingPathComponent("recently-deleted.json") }
    private var historyURL: URL { Self.directory.appendingPathComponent("transcripts.json") }

    init() {
        selectedModel = CaptionModel(rawValue: UserDefaults.standard.string(forKey: "captionModel") ?? "") ?? .fastConformer
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: historyURL.path) {
                recordings = try JSONDecoder().decode([Transcript].self, from: Data(contentsOf: historyURL))
                for index in recordings.indices where recordings[index].unfinished == true {
                    if let url = audioURL(for: recordings[index]), let audio = try? AVAudioFile(forReading: url) {
                        recordings[index].duration = Double(audio.length) / audio.processingFormat.sampleRate
                        recordings[index].unfinished = false
                    }
                }
                persist()
            }
            deletedRecordings = (try? JSONDecoder().decode([Transcript].self, from: Data(contentsOf: trashURL))) ?? []
            recoverTemporaryAudio()
        } catch { self.error = "Couldn't read saved transcripts: \(error.localizedDescription)" }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.stop(reason: "Audio interruption began") }
        }
    }

    private func recoverTemporaryAudio() {
        let manager = FileManager.default
        guard let leftovers = try? manager.contentsOfDirectory(at: RefinementAudio.directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let audio = leftovers.filter { $0.pathExtension == "caf" }
        let whole = audio.filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        let candidates = whole.isEmpty ? audio : whole
        for source in candidates {
            guard let file = try? AVAudioFile(forReading: source), file.length > 0 else { continue }
            let id = UUID(), name = id.uuidString + ".caf"
            let destination = Self.directory.appendingPathComponent("Recordings").appendingPathComponent(name)
            do {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let created = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                try manager.moveItem(at: source, to: destination)
                var transcript = Transcript(id: id, text: "", audioFile: name, generatedTitle: whole.isEmpty ? "Recovered audio fragment" : "Recovered recording", duration: Double(file.length) / file.processingFormat.sampleRate)
                transcript.date = created
                recordings.insert(transcript, at: 0)
            } catch { self.error = "Recoverable audio is still in temporary storage: " + error.localizedDescription }
        }
        if !whole.isEmpty {
            let archive = Self.directory.appendingPathComponent("RecoveredAudioFragments", isDirectory: true)
            try? manager.createDirectory(at: archive, withIntermediateDirectories: true)
            for fragment in audio where !whole.contains(fragment) { try? manager.moveItem(at: fragment, to: archive.appendingPathComponent(fragment.lastPathComponent)) }
        }
        // Never discard unknown or unreadable audio during recovery.
        if !candidates.isEmpty { persist() }
    }

    func start(saveAudio: Bool = true) async {
        guard !recording, !busy else { return }
        busy = true
        notesAITask?.cancel()
        await notesAITask?.value
        generatingNotesID = nil
        refinementTask?.cancel()
        await refinementTask?.value
        if refiningID != nil { refinementStatus = "Refinement cancelled · live transcript kept" }
        refiningID = nil
        defer { busy = false }
        let allowed: Bool
        #if DEBUG
        // Fixture capture never opens a microphone or an AVAudioSession.
        if ProcessInfo.processInfo.arguments.contains("--microphone-fixture") { allowed = true }
        else {
            allowed = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        #else
        allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        #endif
        guard allowed else { error = "Allow microphone access in Settings. Simulator also needs macOS microphone permission for its helper."; return }
        let sessionModel = selectedModel
        sessionCaptionModel = sessionModel
        guard sessionModel.isLive, sessionModel.isSupported, ModelCatalog.installed(sessionModel) else {
            error = "Download a supported live model in Settings → Models first."; return
        }
        if sessionModel == .apple {
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard permission == .authorized else {
                error = "Allow speech recognition in Settings to use Apple Speech, or choose Zipformer."
                return
            }
        }
        do {
            status = "Loading captions…"
            try await recognizer.start(model: sessionModel)
            sessionSavesAudio = true
            lastSavedID = nil
            sessionCorrectionModel = refinement.liveModel
            liveCorrectionActive = refinement.liveEnabled && ModelCatalog.installed(refinement.liveModel)
            if liveCorrectionActive {
                do { try await correctionWorker.start(model: refinement.liveModel); correctionStatus = "Whisper corrections ready" }
                catch { liveCorrectionActive = false; correctionStatus = error.localizedDescription }
            } else { correctionStatus = refinement.liveEnabled ? "Download Whisper in Models for live corrections" : "" }
            timeline = CaptionTimeline(); captionBlocks = []; correctionJobs = []
            sessionRefinementModel = refinement.selectedModel
            captureForRefinement = refinement.enabled && refinement.installed
            let id = UUID()
            let name = id.uuidString + ".caf"
            let destination = Self.directory.appendingPathComponent("Recordings").appendingPathComponent(name)
            try await refinementAudio.start(at: destination)
            captureWritesAudio = true
            paused = false; muted = false; syncAudioControls()
            try audio.start(audioSink: { [refinementAudio] samples in refinementAudio.enqueue(samples) })
            activeRecordingID = id
            recordings.insert(Transcript(id: id, text: "", audioFile: name, unfinished: true, duration: 0), at: 0)
            persist(); lastCheckpoint = Date()
            microphoneHint = "Speak or tap your microphone to test it."; level = 0; microphoneDB = -60
            text = ""; elapsed = 0; started = Date(); recording = true
            UIApplication.shared.isIdleTimerDisabled = true
            status = "Listening"
            await liveActivity.start(id: id)
            var lastSignal = Date()
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if let failure = await self.refinementAudio.recordingError() { self.error = failure; self.stop(reason: "Audio file error"); return }
                    let input = self.audio.microphoneSnapshot()
                    self.level = max(input.level, self.level * 0.75)
                    self.microphoneDB = input.decibels
                    self.microphoneInput = input.inputName
                    self.elapsed = Double(input.convertedFrames) / 16000
                    if input.decibels > -50 { lastSignal = Date() }
                    if self.paused { self.microphoneHint = "Paused" }
                    else if self.muted { self.microphoneHint = "Muted" }
                    else if self.elapsed > 2 && input.receivedBuffers == 0 {
                        self.microphoneHint = "No audio arriving. Check the microphone input and permissions."
                    } else if self.elapsed > 2 && input.convertedFrames == 0 {
                        self.microphoneHint = "Microphone connected, but audio isn't reaching captions."
                    } else if Date().timeIntervalSince(lastSignal) > 3 {
                        self.microphoneHint = "Input is quiet. Speak or tap the microphone to test it."
                    } else {
                        self.microphoneHint = "Microphone active"
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            loop = Task { [weak self] in await self?.process() }
        } catch {
            await recognizer.cancel()
            await correctionWorker.stop()
            liveCorrectionActive = false
            audio.stop()
            if let url = await refinementAudio.close(), activeRecordingID == nil { try? FileManager.default.removeItem(at: url) }
            captureWritesAudio = false
            liveActivity.end(elapsed: elapsed, saved: false)
            self.error = error.localizedDescription; status = "Couldn't start"
        }
    }

    private func process() async {
        do {
            while recording {
                if let slice = try audio.takeLatest() { try await consume(slice) }
                else {
                    if let update = try await recognizer.poll() { await apply(update) }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            while let tail = try audio.takeLatest(final: true) { try await consume(tail) }
            await apply(try await recognizer.accept([], final: true))
        } catch {
            Logger(subsystem: "com.mcvs.voice-app", category: "capture").error("Capture loop ended: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            stop(reason: "Recognition error")
        }
        await recognizer.cancel()
        // Finalize and checkpoint the persistent audio BEFORE waiting for Whisper.
        let audioURL = await refinementAudio.close()
        if let index = recordings.firstIndex(where: { $0.id == activeRecordingID }) { recordings[index].unfinished = false }
        checkpoint(final: true)
        if correctionTask != nil { status = "Whisper correcting…" }
        await correctionTask?.value
        await correctionWorker.stop()
        liveCorrectionActive = false; captureWritesAudio = false
        audio.stop(); recording = false; meter?.cancel(); level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        checkpoint(final: true)
        let savedID = activeRecordingID
        activeRecordingID = nil
        lastSavedID = savedID
        status = "Saved"
        liveActivity.end(elapsed: elapsed)
        endFinishingBackgroundTask()
        busy = false
        if let id = savedID, let transcript = recordings.first(where: { $0.id == id }) {
            if captureForRefinement, let audioURL { refine(transcript, audioURL: audioURL, deleteAudio: false) }
            else { generateNotes(id) }
        }
    }
    private func checkpoint(final: Bool = false) {
        guard let id = activeRecordingID, let index = recordings.firstIndex(where: { $0.id == id }), final || Date().timeIntervalSince(lastCheckpoint) >= 2 else { return }
        recordings[index].text = text
        recordings[index].duration = elapsed
        recordings[index].cues = timeline.blocks.map { TranscriptCue(start: $0.start, end: max($0.start, min($0.end, elapsed)), text: $0.text, speaker: $0.speaker) }
        if !timeline.original.isEmpty && timeline.original != text { recordings[index].originalText = timeline.original }
        lastCheckpoint = Date(); persist()
    }
    private func consume(_ slice: LiveAudioSlice) async throws {
        if slice.skippedFrames > 0 || slice.restartStream { await apply(try await recognizer.skip(to: Double(slice.startFrame) / 16000)) }
        try await consume(slice.samples)
    }
    private func display(_ raw: String) -> String {
        sessionCaptionModel.usesSentenceCase ? CaptionFormatter.sentenceCase(raw) : raw
    }
    private func consume(_ samples: [Float]) async throws {
        if !captureWritesAudio && (captureForRefinement || sessionSavesAudio || liveCorrectionActive) {
            do { try await refinementAudio.append(samples) }
            catch {
                captureForRefinement = false
                liveCorrectionActive = false
                correctionStatus = error.localizedDescription
                if sessionSavesAudio { self.error = error.localizedDescription; stop() }
                else if let url = await refinementAudio.close() { try? FileManager.default.removeItem(at: url) }
                refinementStatus = error.localizedDescription
            }
        }
        await apply(try await recognizer.accept(samples))
        checkpoint()
    }
    private func apply(_ result: CaptionResult) async {
        if result.lines.isEmpty { text = display(result.text); return }
        let old = timeline.text
        let completed = timeline.update(result.lines, sentenceCase: sessionCaptionModel.usesSentenceCase)
        text = timeline.text; captionBlocks = timeline.blocks
        if old != text { captionScrollVersion += 1 }
        guard liveCorrectionActive else { return }
        for line in completed {
            do {
                if let audio = try await refinementAudio.snapshot(start: line.start, end: line.end) {
                    correctionJobs.append(CorrectionJob(id: line.id, audio: audio))
                }
            } catch { correctionStatus = error.localizedDescription }
        }
        startCorrectionPump()
    }
    private func startCorrectionPump() {
        guard correctionTask == nil, !correctionJobs.isEmpty else { return }
        correctionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !self.correctionJobs.isEmpty {
                let job = self.correctionJobs.removeFirst()
                self.correctionStatus = "Whisper correcting…"
                do {
                    let corrected = try await self.correctionWorker.correct(audio: job.audio)
                    self.timeline.correct(id: job.id, text: corrected)
                    self.captionBlocks = self.timeline.blocks; self.text = self.timeline.text
                    self.correctionStatus = "Whisper correction complete"
                    self.checkpoint(final: true)
                } catch { self.correctionStatus = error.localizedDescription }
                try? FileManager.default.removeItem(at: job.audio)
            }
            self.correctionTask = nil
        }
    }
    private func refine(_ transcript: Transcript, audioURL: URL, deleteAudio: Bool) {
        refiningID = transcript.id; refinementStatus = "Improving saved transcript…"
        let model = sessionRefinementModel
        refinementTask = Task { [weak self] in
            defer { if deleteAudio { try? FileManager.default.removeItem(at: audioURL) } }
            guard let self else { return }
            defer { if self.refiningID == transcript.id { self.refiningID = nil } }
            do {
                let improved = try await self.refiner.refine(audio: audioURL, model: model)
                guard !Task.isCancelled, self.refiningID == transcript.id,
                      let index = self.recordings.firstIndex(where: { $0.id == transcript.id }),
                      self.recordings[index].text == transcript.text else { return }
                self.recordings[index].originalText = self.recordings[index].originalText ?? transcript.text
                self.recordings[index].text = improved
                self.recordings[index].cues = nil
                if !self.recording && self.text == transcript.text { self.text = improved }
                self.persist(); self.refinementStatus = "Saved transcript improved · original preserved"
                self.generateNotes(transcript.id)
            } catch is CancellationError {
                // Starting another recording keeps the live transcript and discards temp audio.
            } catch { self.refinementStatus = error.localizedDescription; self.generateNotes(transcript.id) }
        }
    }
    func isSelected(_ model: CaptionModel) -> Bool {
        guard ModelCatalog.installed(model) else { return false }
        if model.isNotesAI { return notesAISettings.selectedModel == model }
        if model == .speakers { return selectedModel.spec?.family == "moonshine" && UserDefaults.standard.bool(forKey: "betaSpeakers") && ModelCatalog.installed(model) }
        if model.isLive { return selectedModel == model }
        if model.spec?.family == "whisper" { return refinement.liveModel == model }
        return refinement.selectedModel == model
    }
    func modelInUse(_ model: CaptionModel) -> Bool {
        (activeRecordingID != nil && (model == sessionCaptionModel || (liveCorrectionActive && model == sessionCorrectionModel))) ||
        (refiningID != nil && model == sessionRefinementModel) || (generatingNotesID != nil && model == activeNotesModel)
    }
    func selectModel(_ model: CaptionModel) {
        guard ModelCatalog.installed(model) else { models.report("Download this model before selecting it."); return }
        guard model.isSupported else { models.report("This model requires iOS 17 or later."); return }
        if model.isNotesAI { notesAISettings.selectedModel = model }
        else if model == .speakers {
            guard selectedModel.spec?.family == "moonshine" else { models.report("Choose a Moonshine live voice model before enabling speaker detection."); return }
            UserDefaults.standard.set(true, forKey: "betaSpeakers")
        }
        else if model.isLive { selectedModel = model }
        else if model.spec?.family == "whisper" { refinement.liveModel = model }
        else { refinement.selectedModel = model }
        models.notice(recording || busy ? "Model selected. Your current recording continues; this choice applies to the next recording." : "Model is selected.")
    }
    func refineRecording(_ id: UUID, model: CaptionModel) {
        guard !recording, !busy, refiningID == nil, generatingNotesID == nil else { error = "Wait for the current recording or processing to finish."; return }
        guard let item = recordings.first(where: { $0.id == id }), let audio = audioURL(for: item) else { error = "This recording has no saved audio to transcribe again."; return }
        guard ModelCatalog.installed(model), model.isSupported else { error = "Download \(model.title) in Models before running this pass."; return }
        sessionRefinementModel = model
        refine(item, audioURL: audio, deleteAudio: false)
    }
    func generateNotes(_ id: UUID, force: Bool = false, title: Bool? = nil, summary: Bool? = nil) {
        let wantsTitle = title ?? (force || notesAISettings.automaticTitles)
        let wantsSummary = summary ?? (force || notesAISettings.automaticSummaries)
        guard wantsTitle || wantsSummary else { return }
        guard notesAISettings.installed else { if force { error = "Download a local language model in Models → Titles & summaries first." }; return }
        guard !recording, !busy, (!force || refiningID == nil), force || !attemptedNotes.contains(id),
              let transcript = recordings.first(where: { $0.id == id }), !transcript.text.isEmpty else { return }
        let model = notesAISettings.selectedModel; activeNotesModel = model
        notesAITask?.cancel()
        let previous = notesAITask
        attemptedNotes.insert(id)
        generatingNotesID = id; notesAIMessage = wantsTitle && wantsSummary ? "Creating title and summary…" : wantsTitle ? "Creating title…" : "Creating summary…"
        notesAITask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if Task.isCancelled { if self.generatingNotesID == id { self.generatingNotesID = nil }; self.attemptedNotes.remove(id); return }
            defer {
                if self.generatingNotesID == id { self.generatingNotesID = nil }
                if !Task.isCancelled { self.resumePendingNotes() }
            }
            do {
                let result = try await self.notesAI.generate(text: transcript.text, model: model)
                guard !Task.isCancelled, let index = self.recordings.firstIndex(where: { $0.id == id }), self.recordings[index].text == transcript.text else { return }
                if wantsTitle && self.recordings[index].generatedTitle == transcript.generatedTitle { self.recordings[index].generatedTitle = result.title }
                if wantsSummary { self.recordings[index].summary = result.summary }
                self.persist(); self.notesAIMessage = ""
            } catch is CancellationError { self.notesAIMessage = ""; self.attemptedNotes.remove(id) }
            catch { self.notesAIMessage = error.localizedDescription }
        }
    }
    func cancelNotesAI() {
        notesAITask?.cancel(); generatingNotesID = nil; notesAIMessage = ""
    }
    func resumePendingNotes() {
        guard !recording, !busy, refiningID == nil, generatingNotesID == nil,
              let next = recordings.first(where: { ((notesAISettings.automaticSummaries && $0.summary == nil) || (notesAISettings.automaticTitles && $0.generatedTitle == nil)) && !$0.text.isEmpty && !attemptedNotes.contains($0.id) }) else { return }
        generateNotes(next.id)
    }
    func rename(_ id: UUID, title: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].generatedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)); persist()
    }
    func update(_ id: UUID, text: String) {
        if generatingNotesID == id { notesAITask?.cancel(); generatingNotesID = nil }
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let old = recordings[index].text
        if recordings[index].originalText == nil { recordings[index].originalText = old }
        recordings[index].text = text
        recordings[index].cues = nil
        recordings[index].summary = nil
        if !recording && self.text == old { self.text = text }
        persist()
    }
    private func syncAudioControls() { audio.setControls(paused: paused, muted: muted, ambient: ambientListening) }
    func togglePause() {
        guard recording else { return }
        paused.toggle(); syncAudioControls(); status = paused ? "Paused" : muted ? "Muted" : "Listening"
        liveActivity.update(paused: paused, muted: muted, elapsed: elapsed)
    }
    func toggleMute() {
        guard recording else { return }
        muted.toggle(); syncAudioControls(); status = paused ? "Paused" : muted ? "Muted" : "Listening"
        liveActivity.update(paused: paused, muted: muted, elapsed: elapsed)
    }
    func stop(reason: String = "Stop button") {
        guard recording else { return }
        Logger(subsystem: "com.mcvs.voice-app", category: "capture").notice("Stopping capture: \(reason, privacy: .public)")
        elapsed = Double(audio.microphoneSnapshot().convertedFrames) / 16000
        recording = false; busy = true; audio.stop(); meter?.cancel(); level = 0
        status = "Finishing…"
        liveActivity.update(paused: paused, muted: muted, elapsed: elapsed, phase: "Finishing")
        if finishBackgroundTask == .invalid {
            finishBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save recording") { [weak self] in
                Task { @MainActor in self?.endFinishingBackgroundTask() }
            }
        }
    }
    private func endFinishingBackgroundTask() {
        guard finishBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishBackgroundTask); finishBackgroundTask = .invalid
    }
    func audioURL(for transcript: Transcript) -> URL? {
        guard let name = transcript.audioFile, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        return Self.directory.appendingPathComponent("Recordings").appendingPathComponent(name)
    }
    func delete(_ id: UUID) {
        guard activeRecordingID != id else { error = "Stop this recording before deleting it."; return }
        let item = recordings.first { $0.id == id }
        if refiningID == id { refinementTask?.cancel(); refiningID = nil }
        if generatingNotesID == id { notesAITask?.cancel(); generatingNotesID = nil }
        recordings.removeAll { $0.id == id }; persist()
        if let item { deletedRecordings.insert(item, at: 0); persistTrash() }
    }
    func undoDelete() {
        guard !deletedRecordings.isEmpty else { return }
        let item = deletedRecordings.removeFirst()
        recordings.append(item); recordings.sort { $0.date > $1.date }; persist(); persistTrash()
    }
    private func persistTrash() {
        do { try JSONEncoder().encode(deletedRecordings).write(to: trashURL, options: .atomic) }
        catch { self.error = "Couldn't save deleted recording recovery: " + error.localizedDescription }
    }
    func removeModel(_ model: CaptionModel) {
        guard model != .apple else { models.report("Apple manages its speech files in iOS Settings."); return }
        guard !modelInUse(model), models.downloading != model else { models.report("This model is in use. Wait for processing to finish before removing it."); return }
        let alternatives = CaptionModel.allCases.filter { $0 != model && $0 != .apple && $0.isLive && $0.isSupported && ModelCatalog.installed($0) }
        if model.isLive && alternatives.isEmpty { models.report("You can't remove this model because it's your only downloaded live voice model. Download another live model first."); return }
        if selectedModel == model { selectedModel = alternatives.contains(.fastConformer) ? .fastConformer : alternatives[0] }
        if refinement.selectedModel == model { refinement.enabled = false }
        if refinement.liveModel == model { refinement.liveEnabled = false }
        if model.isNotesAI && notesAISettings.selectedModel == model { notesAISettings.enabled = false }
        if model == .speakers { UserDefaults.standard.set(false, forKey: "betaSpeakers") }
        models.remove(model)
    }
    func resetApp() async -> Bool {
        guard !recording, !busy else { error = "Stop recording and wait for Whisper to finish before resetting."; return false }
        notesAITask?.cancel(); refinementTask?.cancel(); correctionTask?.cancel()
        await notesAITask?.value; await refinementTask?.value; await correctionTask?.value
        guard models.downloading == nil else { error = "Cancel the model download before resetting."; return false }
        do {
            await liveActivity.clearOrphans()
            if FileManager.default.fileExists(atPath: Self.directory.path) { try FileManager.default.removeItem(at: Self.directory) }
            if FileManager.default.fileExists(atPath: RefinementAudio.directory.path) { try FileManager.default.removeItem(at: RefinementAudio.directory) }
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ModelCatalog.root, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("VoiceAppExport-") { try FileManager.default.removeItem(at: url) }
            if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
            UserDefaults.standard.set(false, forKey: "setupComplete")
            UserDefaults.standard.set(false, forKey: "recordTourPending")
            UserDefaults.standard.set(36.0, forKey: "captionSize")
            UserDefaults.standard.set("system", forKey: "appearanceMode")
            UserDefaults.standard.set(true, forKey: "bottomNavigation")
            selectedModel = .fastConformer; ambientListening = false
            refinement.enabled = false; refinement.liveEnabled = false; refinement.liveModel = .whisperBase; refinement.selectedModel = .whisperBase
            notesAISettings.enabled = false; notesAISettings.selectedModel = .notesAI; recordings = []; deletedRecordings = []; attemptedNotes = []
            text = ""; captionBlocks = []; elapsed = 0; lastSavedID = nil; error = nil
            generatingNotesID = nil; refiningID = nil; refinementStatus = ""; correctionStatus = ""; notesAIMessage = ""; status = "Ready"
            models.didReset(); persist(); persistTrash()
            return true
        } catch { self.error = "Reset couldn't finish: " + error.localizedDescription; return false }
    }
    private func persist() {
        do { try JSONEncoder().encode(recordings).write(to: historyURL, options: .atomic) }
        catch { self.error = "Couldn't save: \(error.localizedDescription). Copy the text before closing." }
    }
}

#if DEBUG
extension VoiceStore {
    // Exercises the actual production consume/apply/correction queue with paced
    // fixture audio, without requesting microphone access or changing history.
    func runLiveCorrectionSmokeTestIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--live-correction-test") else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        busy = true; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            if !ModelCatalog.installed(.whisperBase), args.contains("--download-models") { await models.install(.whisperBase) }
            guard ModelCatalog.installed(.whisperBase) else { throw CaptionError.message(models.message) }
            let file = try AVAudioFile(forReading: documents.appendingPathComponent("streaming-fixture.wav"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            selectedModel = .moonshineSmall; sessionCaptionModel = .moonshineSmall; captureWritesAudio = false
            try await recognizer.start(model: selectedModel)
            try await correctionWorker.start(model: .whisperBase)
            try await refinementAudio.start()
            timeline = CaptionTimeline(); captionBlocks = []; correctionJobs = []
            liveCorrectionActive = true; sessionSavesAudio = false; captureForRefinement = false
            let conversation = samples + [Float](repeating: 0, count: 48000) + samples + [Float](repeating: 0, count: 16000)
            let start = Date()
            var correctedBeforeStop = false
            for offset in stride(from: 0, to: conversation.count, by: 1600) {
                let end = min(offset + 1600, conversation.count)
                if args.contains("--paced") {
                    let wait = Double(end) / 16000 - Date().timeIntervalSince(start)
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                }
                try await consume(Array(conversation[offset..<end]))
                correctedBeforeStop = correctedBeforeStop || captionBlocks.contains(where: \.corrected)
            }
            let idsBefore = captionBlocks.map(\.id)
            await apply(try await recognizer.accept([], final: true))
            await recognizer.cancel()
            await correctionTask?.value
            report["corrected_before_stop"] = correctedBeforeStop
            report["text"] = text; report["original"] = timeline.original
            report["corrected_blocks"] = captionBlocks.filter(\.corrected).count
            report["stable_block_ids"] = captionBlocks.map(\.id).prefix(idsBefore.count).elementsEqual(idsBefore)
            report["audio_seconds"] = Double(conversation.count) / 16000
            report["elapsed_seconds"] = Date().timeIntervalSince(start)
            report["status"] = correctionStatus
            report["passed"] = captionBlocks.filter(\.corrected).count == 2 && correctedBeforeStop && report["stable_block_ids"] as? Bool == true
            refinement.liveEnabled = false; refinement.liveModel = .whisperBase
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        await recognizer.cancel(); await correctionTask?.value; await correctionWorker.stop()
        if let url = await refinementAudio.close() { try? FileManager.default.removeItem(at: url) }
        liveCorrectionActive = false
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: documents.appendingPathComponent("correction-result.json"), options: .atomic) }
        status = "Correction test complete"
    }
}
#endif

#if DEBUG
extension VoiceStore {
    func runRecordFixesTestIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--record-fixes-test") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        let previous = selectedModel, previousWhisper = refinement.liveModel
        defer { selectedModel = previous; refinement.liveModel = previousWhisper; recording = false; busy = false; activeRecordingID = nil; captureWritesAudio = false }
        do {
            report["continuous_audio_latest_buffer"] = try await AudioCapture.backlogRecordingSmokeTest()
            report["ambient_pause_mute"] = try await AudioCapture.controlSmokeTest()
            sessionCaptionModel = .moonshineSmall; recording = true; generatingNotesID = UUID()
            selectModel(.moonshineTiny)
            report["selection_works_while_busy"] = selectedModel == .moonshineTiny && sessionCaptionModel == .moonshineSmall && models.message.contains("next recording")
            recording = false; generatingNotesID = nil
            if !ModelCatalog.installed(.whisperTiny) { await models.install(.whisperTiny) }
            guard ModelCatalog.installed(.whisperTiny) else { throw CaptionError.message(models.message) }
            selectModel(.whisperTiny)
            report["real_download_and_selection"] = refinement.liveModel == .whisperTiny && isSelected(.whisperTiny)
            let file = try AVAudioFile(forReading: docs.appendingPathComponent("streaming-fixture.wav"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let turn = samples + [Float](repeating: 0, count: 48000)
            let whole = turn + turn + turn
            try await refinementAudio.start()
            try await refinementAudio.append(whole)
            captureWritesAudio = true; liveCorrectionActive = true; timeline = CaptionTimeline(); correctionJobs = []
            try await correctionWorker.start(model: .whisperBase)
            try await recognizer.start(model: .moonshineSmall)
            for offset in stride(from: 0, to: turn.count, by: 1600) { try await consume(Array(turn[offset..<min(offset + 1600, turn.count)])) }
            await apply(try await recognizer.skip(to: Double(turn.count * 2) / 16000))
            for offset in stride(from: 0, to: turn.count, by: 1600) { try await consume(Array(turn[offset..<min(offset + 1600, turn.count)])) }
            await apply(try await recognizer.accept([], final: true))
            await correctionTask?.value
            report["skipped_audio_recovered_by_whisper"] = timeline.blocks.contains { $0.id.hasPrefix("catchup-") && $0.corrected && $0.text.lowercased().contains("good morning") }
            report["latest_caption_after_gap"] = timeline.blocks.contains { $0.start >= Double(turn.count * 2) / 16000 && $0.text.lowercased().contains("good morning") }
            report["speaker_beta_default_off"] = !UserDefaults.standard.bool(forKey: "betaSpeakers")
            report["summaries_beta_default_off"] = !notesAISettings.enabled
            report["passed"] = ["continuous_audio_latest_buffer", "ambient_pause_mute", "selection_works_while_busy", "real_download_and_selection", "skipped_audio_recovered_by_whisper", "latest_caption_after_gap", "speaker_beta_default_off", "summaries_beta_default_off"].allSatisfy { report[$0] as? Bool == true }
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        await recognizer.cancel(); await correctionTask?.value; await correctionWorker.stop()
        if let url = await refinementAudio.close() { try? FileManager.default.removeItem(at: url) }
        liveCorrectionActive = false
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: docs.appendingPathComponent("record-fixes-result.json"), options: .atomic) }
    }
}
#endif

#if DEBUG
extension VoiceStore {
    func runPreferencesTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--preferences-test"), Bundle.main.bundleIdentifier == "com.voiceapp.setupqa" else { return }
        var report: [String: Any] = [:]
        report["correction_default_off"] = !refinement.liveEnabled
        report["second_pass_default_off"] = !refinement.enabled
        report["automatic_titles_default_off"] = !notesAISettings.automaticTitles
        report["automatic_summaries_default_off"] = !notesAISettings.automaticSummaries
        report["retired_model_removed"] = CaptionModel(rawValue: "parakeetUnified") == nil && ModelCatalog.specs["parakeetUnified"] == nil
        if ModelCatalog.installed(.whisperBase) {
            selectModel(.whisperBase)
            report["selecting_whisper_does_not_enable_it"] = !refinement.liveEnabled
        }
        let id = UUID()
        recordings.insert(Transcript(id: id, text: "The community garden meeting is on Saturday at 10 AM. Alice will bring seeds. Ben will bring tools. The budget is $200.", duration: 12), at: 0)
        notesAISettings.selectedModel = .notesQwenSmall
        let started = Date()
        generateNotes(id, force: true, title: true, summary: false)
        for _ in 0..<900 where generatingNotesID != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        report["title_only_keeps_summary_empty"] = recordings.first(where: { $0.id == id })?.generatedTitle?.isEmpty == false && recordings.first(where: { $0.id == id })?.summary == nil
        rename(id, title: "Garden plan")
        generateNotes(id, force: true, title: false, summary: true)
        for _ in 0..<900 where generatingNotesID != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        let item = recordings.first(where: { $0.id == id })
        report["summary_only_preserves_title"] = item?.generatedTitle == "Garden plan" && item?.summary?.isEmpty == false
        report["summary"] = item?.summary ?? ""
        report["qwen_generation_seconds"] = Date().timeIntervalSince(started)
        report["automatic_options_stay_off"] = !notesAISettings.enabled
        report["passed"] = report.values.compactMap { $0 as? Bool }.allSatisfy { $0 }
        report["message"] = notesAIMessage
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: docs.appendingPathComponent("preferences-result.json")) }
    }
}
#endif
