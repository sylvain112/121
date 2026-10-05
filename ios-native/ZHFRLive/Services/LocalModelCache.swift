import Foundation

/// A completed download is kept outside temporary caches. Relative paths survive
/// an iOS app-container move when the app is updated or re-signed.
struct LocalModelCache {
    private struct Receipt: Codable {
        let files: [String: Int64]
    }
    let root: URL
    let legacyRoot: URL?
    private let manager = FileManager.default
    private let receiptName = ".zhfr-complete.json"

    init(root: URL? = nil, legacyRoot: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZHFRModels", isDirectory: true)
        self.legacyRoot = legacyRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    func folder(for profile: RecognitionProfile) -> URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(profile.modelName)", isDirectory: true)
    }

    func tokenizerFolder(for profile: RecognitionProfile, in base: URL? = nil) -> URL {
        (base ?? root).appendingPathComponent("models/openai/\(profile.tokenizerName)", isDirectory: true)
    }

    func prepareDirectories() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// A receipt is written only after WhisperKit has loaded the complete models
    /// and tokenizer successfully. An interrupted download never becomes ready.
    func completedFolder(for profile: RecognitionProfile) -> URL? {
        let candidate = folder(for: profile)
        let marker = candidate.appendingPathComponent(receiptName)
        guard let data = try? Data(contentsOf: marker),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              !receipt.files.isEmpty, hasModelComponents(candidate),
              hasTokenizer(candidate) else { return nil }
        for (path, size) in receipt.files {
            guard size > 0, fileSize(candidate.appendingPathComponent(path)) == size else { return nil }
        }
        return candidate
    }

    /// Reuse v2.4's downloaded files instead of downloading the same weights.
    /// Candidates without a receipt still have to pass a real model load.
    func existingCandidate(for profile: RecognitionProfile) throws -> URL? {
        let destination = folder(for: profile)
        // A damaged completed download must be verified by the downloader.
        if manager.fileExists(atPath: destination.appendingPathComponent(receiptName).path) { return nil }
        if hasModelComponents(destination) { return destination }
        guard let legacyRoot else { return nil }
        let source = legacyRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(profile.modelName)")
        guard hasModelComponents(source), !manager.fileExists(atPath: destination.path) else { return nil }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
        let legacyTokenizer = tokenizerFolder(for: profile, in: legacyRoot)
        let localTokenizer = tokenizerFolder(for: profile)
        if hasTokenizer(legacyTokenizer), !manager.fileExists(atPath: localTokenizer.path) {
            try manager.createDirectory(at: localTokenizer.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: legacyTokenizer, to: localTokenizer)
        }
        return destination
    }

    func markCompleted(_ folder: URL, profile: RecognitionProfile) throws {
        let tokenizer = tokenizerFolder(for: profile)
        // Bundle tokenizer assets beside the weights so a cold launch needs no
        // Hub lookup, even if the shared tokenizer directory is unavailable.
        if !hasTokenizer(folder), hasTokenizer(tokenizer) {
            for file in try manager.contentsOfDirectory(at: tokenizer, includingPropertiesForKeys: nil) {
                if file.lastPathComponent.hasPrefix(".") { continue }
                let destination = folder.appendingPathComponent(file.lastPathComponent)
                if !manager.fileExists(atPath: destination.path) { try manager.copyItem(at: file, to: destination) }
            }
        }
        guard hasModelComponents(folder), hasTokenizer(folder) else {
            throw CacheError.incomplete
        }
        var files: [String: Int64] = [:]
        let base = folder.path + "/"
        let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               let size = fileSize(file), size > 0 {
                files[String(file.path.dropFirst(base.count))] = size
            }
        }
        let data = try JSONEncoder().encode(Receipt(files: files))
        try data.write(to: folder.appendingPathComponent(receiptName), options: .atomic)
    }

    /// Remove only files known to be missing or truncated. The Hub downloader
    /// can retain the other weights when repairing an interrupted download.
    func prepareRepair(for profile: RecognitionProfile) throws {
        let candidate = folder(for: profile)
        let marker = candidate.appendingPathComponent(receiptName)
        guard let data = try? Data(contentsOf: marker),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return }
        for (path, size) in receipt.files where fileSize(candidate.appendingPathComponent(path)) != size {
            let file = candidate.appendingPathComponent(path)
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        }
    }

    private func hasModelComponents(_ folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { suffix in
                let component = folder.appendingPathComponent("\(name).\(suffix)")
                return manager.fileExists(atPath: component.path)
            }
        }
    }

    private func hasTokenizer(_ folder: URL) -> Bool {
        ["tokenizer.json", "tokenizer_config.json", "config.json"].allSatisfy {
            (fileSize(folder.appendingPathComponent($0)) ?? 0) > 0
        }
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    enum CacheError: LocalizedError {
        case incomplete
        var errorDescription: String? { "模型或分词器文件未完整保存，请联网重试。" }
    }
}
