import Foundation
import AppKit

enum AppLanguagePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .system:
            let sysLabel = AppLocalization.detectSystemLanguage() == .vietnamese ? "Tiếng Việt" : "English"
            return L("Mặc định theo hệ thống (\(sysLabel))", "System Default (\(sysLabel))")
        case .english:
            return "English"
        case .vietnamese:
            return "Tiếng Việt"
        }
    }
}

enum ResolvedAppLanguage: String, Sendable {
    case english = "en"
    case vietnamese = "vi"
}

enum AppLocalization {
    static let userDefaultsKey = "drivebar.appLanguage"
    static let languageDidChangeNotification = Notification.Name("DriveBar.AppLocalization.languageDidChangeNotification")

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cachedLanguage: ResolvedAppLanguage = computeInitialLanguage()
    nonisolated(unsafe) private static var bundleNameCache: [String: (en: String, vi: String)] = [:]

    private static func computeInitialLanguage() -> ResolvedAppLanguage {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? AppLanguagePreference.system.rawValue
        let pref = AppLanguagePreference(rawValue: raw) ?? .system
        return resolve(preference: pref)
    }

    nonisolated static var current: ResolvedAppLanguage {
        stateLock.lock()
        let lang = cachedLanguage
        stateLock.unlock()
        return lang
    }

    nonisolated static var isVietnamese: Bool {
        current == .vietnamese
    }

    nonisolated static var isEnglish: Bool {
        current == .english
    }

    nonisolated static func detectSystemLanguage() -> ResolvedAppLanguage {
        let preferred = Locale.preferredLanguages
        for rawTag in preferred {
            let tag = rawTag.lowercased()
            if tag.hasPrefix("vi") {
                return .vietnamese
            }
            if tag.hasPrefix("en") {
                return .english
            }
        }
        if let globalLangs = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] {
            for rawTag in globalLangs {
                let tag = rawTag.lowercased()
                if tag.hasPrefix("vi") {
                    return .vietnamese
                }
                if tag.hasPrefix("en") {
                    return .english
                }
            }
        }
        return .english
    }

    nonisolated static func resolve(preference: AppLanguagePreference) -> ResolvedAppLanguage {
        switch preference {
        case .system:
            return detectSystemLanguage()
        case .english:
            return .english
        case .vietnamese:
            return .vietnamese
        }
    }

    @discardableResult
    nonisolated static func refresh(preference: AppLanguagePreference) -> ResolvedAppLanguage {
        let next = resolve(preference: preference)
        stateLock.lock()
        let changed = (cachedLanguage != next)
        cachedLanguage = next
        stateLock.unlock()
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: languageDidChangeNotification, object: next)
            }
        }
        return next
    }

    // MARK: - Bilingual macOS .app Bundle Name & Alias Extraction

    nonisolated static func localizedBundleNames(
        forAppAt fullPath: String,
        plist: [String: Any]? = nil,
        rawFileName: String? = nil
    ) -> (en: String, vi: String, extraKeywords: [String]) {
        let fallbackRaw = rawFileName ?? (((fullPath as NSString).lastPathComponent as NSString).deletingPathExtension)
        let infoPlist = plist ?? (NSDictionary(contentsOfFile: "\(fullPath)/Contents/Info.plist") as? [String: Any])

        let rawBundleDisplay = cleanPlistName(infoPlist?["CFBundleDisplayName"] as? String)
        let rawBundleName = cleanPlistName(infoPlist?["CFBundleName"] as? String)

        var enFromLoc: String?
        var viFromLoc: String?
        var extraKeywords: [String] = []

        let resourcesDir = "\(fullPath)/Contents/Resources"
        if let loctable = NSDictionary(contentsOfFile: "\(resourcesDir)/InfoPlist.loctable") as? [String: Any] {
            let enDict = (loctable["en"] as? [String: Any])
                ?? (loctable["en_US"] as? [String: Any])
                ?? (loctable["en_GB"] as? [String: Any])
                ?? (loctable["en_AU"] as? [String: Any])
                ?? (loctable["Base"] as? [String: Any])
            let viDict = (loctable["vi"] as? [String: Any]) ?? (loctable["vi_VN"] as? [String: Any])

            if let enDict {
                enFromLoc = cleanPlistName(enDict["CFBundleDisplayName"] as? String)
                    ?? cleanPlistName(enDict["CFBundleName"] as? String)
                appendKeywordField(enDict["CFBundleAlternateNames"], into: &extraKeywords)
                appendKeywordField(enDict["MDItemKeywords"], into: &extraKeywords)
            }
            if let viDict {
                viFromLoc = cleanPlistName(viDict["CFBundleDisplayName"] as? String)
                    ?? cleanPlistName(viDict["CFBundleName"] as? String)
                appendKeywordField(viDict["CFBundleAlternateNames"], into: &extraKeywords)
                appendKeywordField(viDict["MDItemKeywords"], into: &extraKeywords)
            }
        }

        if enFromLoc == nil {
            enFromLoc = readStringsDisplayName(at: "\(resourcesDir)/en.lproj/InfoPlist.strings")
                ?? readStringsDisplayName(at: "\(resourcesDir)/English.lproj/InfoPlist.strings")
                ?? readStringsDisplayName(at: "\(resourcesDir)/Base.lproj/InfoPlist.strings")
        }
        if viFromLoc == nil {
            viFromLoc = readStringsDisplayName(at: "\(resourcesDir)/vi.lproj/InfoPlist.strings")
        }

        let resolvedEN = enFromLoc ?? rawBundleDisplay ?? (!fallbackRaw.isEmpty ? fallbackRaw : (rawBundleName ?? "App"))
        let resolvedVI = viFromLoc ?? resolvedEN

        stateLock.lock()
        bundleNameCache[fullPath] = (en: resolvedEN, vi: resolvedVI)
        stateLock.unlock()

        return (en: resolvedEN, vi: resolvedVI, extraKeywords: extraKeywords)
    }

    nonisolated static func localizedRunningAppName(_ app: NSRunningApplication) -> String {
        if let bundlePath = app.bundleURL?.path, !bundlePath.isEmpty {
            stateLock.lock()
            let cached = bundleNameCache[bundlePath]
            stateLock.unlock()

            let pair: (en: String, vi: String)
            if let cached {
                pair = cached
            } else {
                let loaded = localizedBundleNames(forAppAt: bundlePath)
                pair = (en: loaded.en, vi: loaded.vi)
            }
            return current == .vietnamese ? pair.vi : pair.en
        }
        return app.localizedName ?? L("Ứng dụng", "Application")
    }

    private nonisolated static func cleanPlistName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(") else {
            return nil
        }
        return trimmed.replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored, .backwards])
    }

    private nonisolated static func readStringsDisplayName(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return cleanPlistName(dict["CFBundleDisplayName"] as? String)
            ?? cleanPlistName(dict["CFBundleName"] as? String)
    }

    private nonisolated static func appendKeywordField(_ value: Any?, into out: inout [String]) {
        if let str = value as? String {
            for part in str.components(separatedBy: CharacterSet(charactersIn: ",;|")) {
                let clean = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { out.append(clean) }
            }
        } else if let arr = value as? [String] {
            for item in arr {
                let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { out.append(clean) }
            }
        }
    }
}

@inline(__always)
nonisolated func L(_ vi: String, _ en: String) -> String {
    AppLocalization.current == .vietnamese ? vi : en
}
