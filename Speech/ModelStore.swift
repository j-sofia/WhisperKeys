import AppKit
import Foundation

struct ModelStore {
    let modelsDirectory: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        modelsDirectory = applicationSupport
            .appendingPathComponent("WhisperKeys", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([modelsDirectory])
    }

    /// Removes only interrupted Hub downloads, never successfully downloaded model files.
    /// This is used for one retry after the downloader reports a failed file move.
    func removeIncompleteDownloads() {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension == "incomplete" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
