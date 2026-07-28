import AppKit
import Foundation

protocol ModelStoring {
    var modelsDirectory: URL { get }
    func openInFinder()
    func removeIncompleteDownloads()
    func removeAllLocalData() throws
}

/// Owns the directories where WhisperKeys keeps data on the local Mac.
/// Keeping the root in one place makes it possible to remove every app-owned file
/// without touching anything outside WhisperKeys' Application Support directory.
struct LocalDataStore {
    let dataDirectory: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = applicationSupportDirectory ?? (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        dataDirectory = applicationSupport.appendingPathComponent("WhisperKeys", isDirectory: true)
    }

    var modelsDirectory: URL {
        dataDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    var recordingsDirectory: URL {
        dataDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes models, temporary recordings, and any future app-owned files together.
    func removeAll() throws {
        guard fileManager.fileExists(atPath: dataDirectory.path) else { return }
        try fileManager.removeItem(at: dataDirectory)
    }
}

struct ModelStore: ModelStoring {
    private let localDataStore: LocalDataStore

    var modelsDirectory: URL { localDataStore.modelsDirectory }

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        localDataStore = LocalDataStore(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
        try? localDataStore.createDirectory(at: modelsDirectory)
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

    func removeAllLocalData() throws {
        try localDataStore.removeAll()
    }
}
