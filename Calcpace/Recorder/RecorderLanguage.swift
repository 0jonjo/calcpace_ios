import Foundation

/// The recorder's settings on this phone: the unit runs count in, and the
/// site's language, which the recorder speaks (Android's RecorderPrefs.kt).
enum RecorderPrefs {
    private static let unitKey = "recorder.unit"
    private static let siteLocaleKey = "recorder.site_locale"
    private static let askedNotificationsKey = "recorder.asked_notifications"

    static var defaults: UserDefaults = .standard

    /// Picked on the screen, or the profile's from the last /record link;
    /// before either, from the site's language, then the phone's region.
    static var unit: RunFormat.Unit {
        get {
            RunFormat.Unit(rawValue: defaults.string(forKey: unitKey) ?? "")
                ?? RunFormat.Unit.defaultFor(siteLocale: siteLocale, region: Locale.current.region?.identifier)
        }
        set { defaults.set(newValue.rawValue, forKey: unitKey) }
    }

    /// The locale of the last /<locale>/record link tapped (a site code: "pt-BR", "no", "zh-TW").
    static var siteLocale: String? {
        get { defaults.string(forKey: siteLocaleKey) }
        set { defaults.set(newValue, forKey: siteLocaleKey) }
    }

    static var askedNotifications: Bool {
        get { defaults.bool(forKey: askedNotificationsKey) }
        set { defaults.set(newValue, forKey: askedNotificationsKey) }
    }
}

/// The recorder speaks the site's language, not the phone's, as the Android
/// app does (RecorderLanguage.kt): an athlete can read the site in Portuguese
/// on a phone set to English, and the recording screen is part of the same
/// app. The language comes from the Record link's path (/pt-BR/record);
/// before any, from the phone, among the 16 the app has.
///
/// The words are in Recorder.strings (and Recorder.stringsdict for the one
/// plural), in each .lproj; the screen reads them from the chosen one.
enum RecorderLanguage {
    /// The .lproj for a site locale: the site's "no" is iOS's "nb", its "zh-TW" iOS's "zh-Hant".
    static func localization(forSite locale: String) -> String {
        switch locale {
        case "no": return "nb"
        case "zh-TW": return "zh-Hant"
        default: return locale
        }
    }

    /// The .lproj the recorder reads its words from.
    static var localization: String {
        if let site = RecorderPrefs.siteLocale {
            let name = localization(forSite: site)
            if Bundle.main.path(forResource: name, ofType: "lproj") != nil { return name }
        }
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var bundle: Bundle {
        Bundle.main.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    /// For numbers and times: "5,21 km" in Portuguese.
    static var locale: Locale { Locale(identifier: localization) }
}

/// The recorder's words, in its language (`RecorderLanguage`), with English
/// when a key is missing there.
enum RecorderStrings {
    private static let table = "Recorder"

    static func text(_ key: String) -> String {
        let value = RecorderLanguage.bundle.localizedString(forKey: key, value: "\u{1}", table: table)
        if value != "\u{1}" { return value }
        let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return english.localizedString(forKey: key, value: key, table: table)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: RecorderLanguage.locale, arguments: arguments)
    }

    /// The one plural ("2 runs saved on your phone…"), by the language's own rules.
    static func count(_ key: String, _ number: Int) -> String {
        // The locale passed picks the plural rule (Polish "2 biegi", "5 biegów").
        String(format: RecorderLanguage.bundle.localizedString(forKey: key, value: nil, table: table),
               locale: RecorderLanguage.locale, number)
    }
}
