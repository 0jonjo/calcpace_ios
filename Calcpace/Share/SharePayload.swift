import Foundation

/// The data of a "share" message, `{ filename, data }`: the run's share card
/// as PNG bytes in standard base64 (no `data:` prefix), and the name the file
/// goes out under. The Android app's rules (SharePayload.kt), and anything
/// that doesn't hold up is refused as a whole:
///
/// - filename: only `[A-Za-z0-9._-]`, 1 to 80 characters, ending in ".png",
///   not starting with "." (no path, nothing hidden);
/// - data: decodes as strict base64 to at most `maxBytes` bytes that start
///   with the PNG signature. The length is checked before decoding, so an
///   oversized payload is never decoded.
enum SharePayload {
    /// A 1080×1920 card is a few MB at most; this leaves room for a photo.
    /// The page refuses anything bigger too (share_image_controller.js).
    static let maxBytes = 8 * 1024 * 1024

    struct Image: Equatable {
        let filename: String
        let bytes: Data
    }

    private struct Fields: Decodable {
        let filename: String
        let data: String
    }

    private static let filenamePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,75}\\.png$")
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// The image in a "share" message's data, or nil when anything about it is invalid.
    static func parse(_ jsonData: String, maxBytes: Int = maxBytes) -> Image? {
        guard let json = jsonData.data(using: .utf8),
              let fields = try? JSONDecoder().decode(Fields.self, from: json),
              isFilename(fields.filename),
              let bytes = decodePNG(fields.data, maxBytes: maxBytes)
        else { return nil }

        return Image(filename: fields.filename, bytes: bytes)
    }

    static func isFilename(_ name: String) -> Bool {
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        return filenamePattern.firstMatch(in: name, range: range) != nil
    }

    /// The PNG bytes `data` encodes, or nil if it isn't base64, is too big or isn't a PNG.
    static func decodePNG(_ data: String, maxBytes: Int = maxBytes) -> Data? {
        guard data.utf8.count <= (maxBytes + 2) / 3 * 4,
              let bytes = Data(base64Encoded: data),
              bytes.count <= maxBytes,
              bytes.starts(with: pngSignature)
        else { return nil }

        return bytes
    }
}
