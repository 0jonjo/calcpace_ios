import Foundation

/// A file on its way out to the share sheet, written under the app's
/// temporary folder (`<tmp>/<folder>/<uuid>/<filename>`). The folder of its
/// own keeps the name the receiving app shows (every look of a run has the
/// same file name) while giving each share its own URL, so an app that cached
/// the last one never gets it back for a new file.
///
/// Whatever an earlier share left in `folder` is deleted first, so it only
/// ever holds the last file. Not after this one: the receiving app may read
/// it any time after the sheet closes.
enum ShareFiles {
    static let images = "shared_images"

    /// Blocking file IO: call off the main thread. `filename` must already be
    /// a plain name (no path); the callers only pass names they checked.
    static func write(_ bytes: Data, named filename: String, in folder: String,
                      root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let files = FileManager.default
        let base = root.appendingPathComponent(folder, isDirectory: true)
        if let earlier = try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            earlier.forEach { try? files.removeItem(at: $0) }
        }

        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(filename, isDirectory: false)
        try bytes.write(to: file, options: .atomic)
        return file
    }
}
