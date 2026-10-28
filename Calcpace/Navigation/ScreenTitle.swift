import Foundation

/// The navigation bar's title for a page: its <title> without the site's name
/// after it ("Settings — Calcpace", "Race Time Predictor | Calcpace"). The
/// bar is narrow, and the app's name says nothing on a screen of the app.
/// A title that is only the name stays as it is.
enum ScreenTitle {
    private static let suffixes = [" — Calcpace", " – Calcpace", " | Calcpace", " - Calcpace"]

    static func short(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }

        for suffix in suffixes where title.hasSuffix(suffix) {
            let rest = title.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? title : rest
        }
        return title
    }
}
