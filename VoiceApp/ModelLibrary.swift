import Foundation
import CryptoKit
import SwiftUI

// Weights are optional, versioned downloads. Inference never makes network requests.
enum CaptionModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case zipformer, apple
    case moonshineSmall, moonshineMedium, moonshineTiny, parakeetEOU
    case zipformerKroko, fastConformer, fastConformerCTC, nemotron
    case parakeet110, parakeetV2, parakeetV3, parakeetRedux, senseVoice, qwen
    case notesAI, notesQwenSmall, notesQwenLarge, speakers
    case whisperTiny, whisperBase, whisperBaseFull, whisperSmall, whisperMedium, whisperTurbo, distilSmall
    var id: String { rawValue }
    var spec: ModelSpec? { ModelCatalog.specs[rawValue] }
    var title: String { self == .zipformer ? "Zipformer · original" : self == .apple ? "Apple Speech · offline" : spec?.title ?? rawValue }
    var details: String { self == .apple ? "On-device only. Requires Apple's installed English language resources." : spec?.detail ?? "" }
    var isLive: Bool { self == .zipformer || self == .apple || spec?.live == true }
    var isSupported: Bool { if self == .parakeetEOU { if #available(iOS 17, *) { return true }; return false }; return true }
    var usesSentenceCase: Bool { self == .zipformer || [.fastConformer, .fastConformerCTC, .nemotron, .parakeetEOU].contains(self) }
    var isNotesAI: Bool { self == .notesAI || self == .notesQwenSmall || self == .notesQwenLarge }
    var purpose: String {
        if isNotesAI { return "Titles & summaries · Beta" }
        if self == .speakers { return "Speaker colors · Beta" }
        if spec?.family == "whisper" { return "Live Whisper correction" }
        return isLive ? "Live transcription" : "Extra saved-text pass · Beta"
    }
    var sizeLabel: String { self == .apple ? "System managed" : ByteCountFormatter.string(fromByteCount: spec?.bytes ?? 0, countStyle: .decimal) }
}

struct ModelAsset: Codable, Sendable {
    let role: String
    let path: String
    let url: URL
    let size: Int64
    let checksum: String
    let checksumType: String
}
struct ModelSpec: Codable, Sendable {
    let id: String
    let title: String
    let family: String
    let live: Bool
    let detail: String
    let featureDim: Int32
    let arch: UInt32?
    let source: URL
    let license: String
    let files: [ModelAsset]
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var receipt: String { files.map { $0.path + $0.checksum }.joined(separator: "\n") }
}
enum ModelCatalog {
    static let specs: [String: ModelSpec] = {
        guard let url = Bundle.main.url(forResource: "ModelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let specs = try? JSONDecoder().decode([ModelSpec].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
    }()
    static var root: URL { VoiceStore.directory.appendingPathComponent("Models", isDirectory: true) }
    static func directory(_ model: CaptionModel) -> URL { root.appendingPathComponent(model.rawValue, isDirectory: true) }
    static func installed(_ model: CaptionModel) -> Bool {
        if model == .apple { return true }
        guard let spec = model.spec,
              (try? String(contentsOf: directory(model).appendingPathComponent("installed.txt"), encoding: .utf8)) == spec.receipt else { return false }
        return spec.files.allSatisfy { asset in
            let url = directory(model).appendingPathComponent(asset.path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size == Int(asset.size)
        }
    }
    static func file(_ model: CaptionModel, role: String) throws -> URL {
        guard installed(model), let asset = model.spec?.files.first(where: { $0.role == role }) else {
            throw CaptionError.message("Download \(model.title) in Settings → Models before using it.")
        }
        return directory(model).appendingPathComponent(asset.path)
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var downloading: CaptionModel?
    @Published private(set) var progress = 0.0
    @Published private(set) var message = ""
    @Published private(set) var revision = 0
    @Published var issue: String?
    func notice(_ text: String) { message = text }
    func report(_ reason: String) { message = reason; issue = reason }
    private var task: Task<Void, Never>?
    init() {
        try? FileManager.default.createDirectory(at: ModelCatalog.root, withIntermediateDirectories: true)
        var root = ModelCatalog.root; var exclusion = URLResourceValues(); exclusion.isExcludedFromBackup = true
        try? root.setResourceValues(exclusion)
        // Retired unsupported model; do not leave its large weights on disk.
        let retired = ModelCatalog.root.appendingPathComponent("parakeetUnified")
        if FileManager.default.fileExists(atPath: retired.path) { try? FileManager.default.removeItem(at: retired) }
        // Move the previous optional Base model without duplicating its storage.
        let legacy = VoiceStore.directory.appendingPathComponent("ggml-base.en.bin")
        if FileManager.default.fileExists(atPath: legacy.path), let spec = CaptionModel.whisperBaseFull.spec, let asset = spec.files.first {
            do {
                try Self.verify(legacy, asset: asset)
                let folder = ModelCatalog.directory(.whisperBaseFull)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(asset.path)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: legacy, to: target) }
                else { try FileManager.default.removeItem(at: legacy) }
                try spec.receipt.write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
            } catch { message = "Previous Whisper download couldn't be migrated: " + error.localizedDescription }
        }
        // Staging directories never count as installed. Clear interrupted downloads.
        if let urls = try? FileManager.default.contentsOfDirectory(at: ModelCatalog.root, includingPropertiesForKeys: nil) {
            for url in urls where url.lastPathComponent.hasPrefix(".download-") { try? FileManager.default.removeItem(at: url) }
        }
    }
    func download(_ model: CaptionModel, completion: @escaping @MainActor () -> Void = {}) {
        if ModelCatalog.installed(model) { completion(); return }
        guard model.isSupported else { report("This model requires iOS 17 or later."); return }
        guard downloading == nil else { report("\(downloading!.title) is already downloading. Cancel it or wait for it to finish."); return }
        downloading = model; progress = 0; message = "Starting download…"
        task = Task { await performInstall(model); if !Task.isCancelled, ModelCatalog.installed(model) { completion() } }
    }
    func cancelDownload() { task?.cancel(); message = "Cancelling download…" }
    func install(_ model: CaptionModel) async {
        guard downloading == nil else { report("Another model is already downloading."); return }
        downloading = model; await performInstall(model)
    }
    private func performInstall(_ model: CaptionModel) async {
        guard let spec = model.spec, model.isSupported else { downloading = nil; report("No compatible download is available for this model."); return }
        progress = 0; issue = nil; message = "Downloading \(model.title)…"
        let staging = ModelCatalog.root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        defer { downloading = nil; revision += 1; try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var excluded = staging; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
            let space = try staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard space > spec.bytes + 50_000_000 else { throw CaptionError.message("Not enough free storage for this model. Remove an unused model first.") }
            var completed: Int64 = 0
            for asset in spec.files {
                try Task.checkCancellation()
                guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains(".."), asset.url.scheme == "https" else { throw CaptionError.message("Invalid model manifest.") }
                let base = completed
                let delegate = ModelDownloadProgress { [weak self] bytes in
                    Task { @MainActor in
                        guard self?.downloading == model else { return }
                        self?.progress = min(0.99, Double(base + bytes) / Double(max(1, spec.bytes)))
                    }
                }
                var components = URLComponents(url: asset.url, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "download", value: "true"), URLQueryItem(name: "voiceapp", value: UUID().uuidString)]
                var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
                request.setValue("voice-app/0.3", forHTTPHeaderField: "User-Agent")
                let (temp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptionError.message("\(asset.url.host ?? "Model server") returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(asset.path). Tap Download to retry.") }
                message = "Verifying \(model.title)…"
                try await Task.detached { try Self.verify(temp, asset: asset) }.value
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(asset.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temp, to: destination)
                completed += asset.size; progress = Double(completed) / Double(max(1, spec.bytes))
                message = "Downloading \(model.title)…"
            }
            try spec.receipt.write(to: staging.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
            let destination = ModelCatalog.directory(model)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
            message = "\(model.title) ready · offline"; progress = 1
        } catch is CancellationError { message = "Download cancelled" }
        catch { report(error.localizedDescription) }
    }
    func remove(_ model: CaptionModel) {
        guard model.spec != nil, downloading != model else { return }
        do { try FileManager.default.removeItem(at: ModelCatalog.directory(model)); message = "Removed \(model.title)"; revision += 1 }
        catch { message = error.localizedDescription }
    }
    func didReset() { message = ""; issue = nil; revision += 1 }
    var downloadedBytes: Int64 { CaptionModel.allCases.filter { $0.spec != nil && ModelCatalog.installed($0) }.reduce(0) { $0 + ($1.spec?.bytes ?? 0) } }

    nonisolated static func verify(_ url: URL, asset: ModelAsset) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var sha = SHA256(); var crc: UInt32 = 0xffffffff; var size: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            size += Int64(data.count)
            if asset.checksumType == "sha256" { sha.update(data: data) }
            else if asset.checksumType == "crc32c" { for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) } }
            else { throw CaptionError.message("Unsupported model checksum.") }
        }
        let checksum: String
        if asset.checksumType == "sha256" { checksum = sha.finalize().map { String(format: "%02x", $0) }.joined() }
        else { var value = (~crc).bigEndian; checksum = withUnsafeBytes(of: &value) { Data($0).base64EncodedString() } }
        guard size == asset.size, checksum == asset.checksum else { throw CaptionError.message("Model verification failed for \(asset.path). Please retry.") }
    }
    private nonisolated static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0x82f63b78 : value >> 1 }
        return value
    }
}
