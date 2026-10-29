import Foundation
import AppKit
import Contacts
import Carbon

struct ContactDetailField: Identifiable, Equatable, Sendable {
    let id: String
    let categoryLabel: String
    let displayValue: String
    let copyValue: String
    let actionURL: URL?
    let actionHint: String?
    let sfSymbol: String
}

struct ContactRecord: Identifiable, Sendable {
    let id: String
    let displayName: String
    let initials: String
    let roleAndOrgLine: String
    let listSubtitle: String
    let badgeText: String?
    let avatarData: Data?
    let primaryQuickCopyValue: String
    let primaryQuickCopyLabel: String
    let fields: [ContactDetailField]

    // Precomputed Vietnamese unaccented search signatures
    let unaccentedFull: String
    let nameWords: [String]
    let givenClean: String
    let acronymVN: String
    let acronymWest: String
    let orgUnaccented: String
    let emailsLower: [String]
    let normalizedPhones: [String]
}

@MainActor
final class ContactsSearchService: ObservableObject {
    static let shared = ContactsSearchService()

    @Published private(set) var authorizationStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var contacts: [ContactRecord] = []
    @Published private(set) var isLoading: Bool = false
    @Published var lastCopiedFieldID: String?

    private var contactsByID: [String: ContactRecord] = [:]
    private var hasLoadedOnce: Bool = false
    private var isRequestingAccess: Bool = false
    private var avatarImageCache: [String: NSImage] = [:]
    private var recentTimestamps: [String: Double] = [:]

    private let loaderQueue = DispatchQueue(label: "com.hunglx.DriveBar.contactsLoader", qos: .userInitiated)
    private static let recentsDefaultsKey = "drivebar.recentContactsTimestamps"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.recentsDefaultsKey) as? [String: Double] {
            recentTimestamps = saved
        }
        NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadContacts(force: true)
            }
        }
    }

    func preloadIfAuthorized() {
        refreshAuthorizationStatus()
        if isAuthorized {
            reloadContacts(force: false)
        }
    }

    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus == .authorized
        } else {
            return authorizationStatus == .authorized
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    func contact(withID id: String) -> ContactRecord? {
        contactsByID[id]
    }

    func cachedAvatarImage(for contactID: String) -> NSImage? {
        if let cached = avatarImageCache[contactID] {
            return cached
        }
        guard let data = contactsByID[contactID]?.avatarData,
              let img = NSImage(data: data) else {
            return nil
        }
        avatarImageCache[contactID] = img
        return img
    }

    func recordContactOpened(_ contactID: String) {
        recentTimestamps[contactID] = Date().timeIntervalSince1970
        if recentTimestamps.count > 120 {
            let sorted = recentTimestamps.sorted { $0.value > $1.value }.prefix(100)
            recentTimestamps = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(recentTimestamps, forKey: Self.recentsDefaultsKey)
    }

    // MARK: - Permission Request & Loading

    func requestAccessIfNeeded() {
        refreshAuthorizationStatus()
        if isAuthorized {
            reloadContacts(force: false)
            return
        }
        guard authorizationStatus == .notDetermined, !isRequestingAccess else { return }
        isRequestingAccess = true

        let wasLauncherVisible = LauncherPanelController.shared.isVisible
        if wasLauncherVisible {
            LauncherPanelController.shared.isSuppressingAutoHide = true
        }

        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingAccess = false
                self.refreshAuthorizationStatus()
                if wasLauncherVisible {
                    LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
                } else {
                    LauncherPanelController.shared.isSuppressingAutoHide = false
                }
                if granted {
                    self.reloadContacts(force: true)
                } else {
                    LauncherViewModel.shared.refreshContactsResultsIfNeeded()
                }
            }
        }
    }

    func openContactsPrivacySettings() {
        LauncherPanelController.shared.hide()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    func reloadContacts(force: Bool) {
        refreshAuthorizationStatus()
        guard isAuthorized else { return }
        if isLoading { return }
        if hasLoadedOnce && !force { return }

        isLoading = true
        loaderQueue.async { [weak self] in
            let fetched = Self.fetchAllContactsFromStore()
            Task { @MainActor in
                guard let self else { return }
                self.contacts = fetched
                var byID: [String: ContactRecord] = [:]
                byID.reserveCapacity(fetched.count)
                for rec in fetched {
                    byID[rec.id] = rec
                }
                self.contactsByID = byID
                self.avatarImageCache.removeAll(keepingCapacity: true)
                self.hasLoadedOnce = true
                self.isLoading = false
                LauncherViewModel.shared.refreshContactsResultsIfNeeded()
            }
        }
    }

    // MARK: - Search (`c` / `c <từ khóa>` — Vietnamese Unaccented, Acronym, Phone & Email)

    func searchResultItems(query: String, limit: Int = 50) -> [SearchResultItem] {
        refreshAuthorizationStatus()

        switch authorizationStatus {
        case .notDetermined:
            requestAccessIfNeeded()
            return [
                SearchResultItem(
                    id: "contact:permission:prompt",
                    title: "Cấp quyền truy cập Danh bạ (Contacts) cho DriveBar",
                    subtitle: "Đang hiển thị hộp thoại xin quyền của macOS • Nhấn Enter (↩) nếu bạn cần mở lại yêu cầu cấp quyền",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "contact.request_access"),
                    badge: "Danh bạ",
                    sfSymbolFallback: "person.crop.circle.badge.questionmark"
                )
            ]

        case .denied, .restricted:
            return [
                SearchResultItem(
                    id: "contact:permission:denied",
                    title: "Chưa cấp quyền Danh bạ — Nhấn Enter để mở Cài đặt Quyền riêng tư",
                    subtitle: "Mở System Settings → Privacy & Security → Contacts rồi bật công tắc cho DriveBar",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "contact.open_settings"),
                    badge: "Cần cấp quyền",
                    sfSymbolFallback: "lock.shield"
                )
            ]

        default:
            break
        }

        if !hasLoadedOnce {
            reloadContacts(force: false)
            if contacts.isEmpty {
                return [
                    SearchResultItem(
                        id: "contact:loading",
                        title: "Đang tải danh sách Danh bạ macOS...",
                        subtitle: "Hỗ trợ gõ tiếng Việt không dấu, tên viết tắt, số điện thoại hoặc email",
                        path: nil,
                        isDirectory: false,
                        kind: .infoBanner,
                        badge: "Danh bạ",
                        sfSymbolFallback: "person.crop.circle"
                    )
                ]
            }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if contacts.isEmpty {
            return [
                SearchResultItem(
                    id: "contact:empty_store",
                    title: "Danh bạ macOS hiện chưa có liên hệ nào",
                    subtitle: "Nhấn Enter (↩) để mở ứng dụng Danh bạ (Contacts.app) trên máy Mac",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "contact.open_app"),
                    badge: "Danh bạ",
                    sfSymbolFallback: "person.crop.circle"
                )
            ]
        }

        if trimmed.isEmpty {
            let sortedDefault = contacts.sorted { a, b in
                let ta = recentTimestamps[a.id] ?? 0
                let tb = recentTimestamps[b.id] ?? 0
                if ta != tb { return ta > tb }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            return sortedDefault.prefix(limit).map(makeSearchResultItem)
        }

        let unaccentedQuery = GoogleDriveIndexService.removeAccents(trimmed)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = unaccentedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let queryDigits = Self.extractDigits(from: trimmed)
        let normalizedQueryPhone = Self.normalizePhoneForComparison(queryDigits)

        var scored: [(score: Int, record: ContactRecord)] = []
        scored.reserveCapacity(min(contacts.count, 64))

        for rec in contacts {
            guard let matchScore = Self.scoreContact(
                rec,
                unaccentedQuery: unaccentedQuery,
                tokens: tokens,
                rawDigits: queryDigits,
                normalizedPhoneQuery: normalizedQueryPhone,
                recentTimestamp: recentTimestamps[rec.id]
            ) else {
                continue
            }
            scored.append((matchScore, rec))
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.record.displayName.localizedStandardCompare(b.record.displayName) == .orderedAscending
        }

        if scored.isEmpty {
            return [
                SearchResultItem(
                    id: "contact:nomatch:\(trimmed)",
                    title: "Không tìm thấy liên hệ nào khớp '\(trimmed)'",
                    subtitle: "Hỗ trợ tiếng Việt không dấu (vd: 'nguyen hung'), viết tắt ('nxh'), số điện thoại hoặc email",
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: "Danh bạ",
                    sfSymbolFallback: "person.crop.circle.badge.exclamationmark"
                )
            ]
        }

        return scored.prefix(limit).map { makeSearchResultItem($0.record) }
    }

    private func makeSearchResultItem(_ rec: ContactRecord) -> SearchResultItem {
        SearchResultItem(
            id: "contact:\(rec.id)",
            title: rec.displayName,
            subtitle: rec.listSubtitle,
            path: nil,
            isDirectory: false,
            kind: .contactItem(id: rec.id),
            badge: rec.badgeText,
            sfSymbolFallback: "person.crop.circle"
        )
    }

    // MARK: - Actions on Contact & Fields

    func copyField(
        _ field: ContactDetailField,
        contactName: String,
        closeLauncher: Bool,
        autoPaste: Bool,
        previousApp: NSRunningApplication?
    ) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(field.copyValue, forType: .string)

        lastCopiedFieldID = field.id

        if !closeLauncher && !autoPaste {
            FloatingToastController.shared.showSuccess(
                title: "Đã sao chép \(field.categoryLabel)",
                subtitle: field.displayValue,
                symbol: "doc.on.clipboard"
            )
            return
        }

        LauncherPanelController.shared.hide()

        if autoPaste {
            if let prev = previousApp, !prev.isTerminated {
                NSApp.yieldActivation(to: prev)
                prev.activate()
            }
            if AXIsProcessTrusted() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    let src = CGEventSource(stateID: .hidSystemState)
                    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                    down?.flags = .maskCommand
                    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                    up?.flags = .maskCommand
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                }
                return
            }
        }

        FloatingToastController.shared.showSuccess(
            title: "Đã sao chép \(field.categoryLabel) — \(contactName)",
            subtitle: field.displayValue,
            symbol: "doc.on.clipboard"
        )
    }

    func openInContactsApp(contactID: String) {
        LauncherPanelController.shared.hide()
        let encoded = contactID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contactID
        if let url = URL(string: "addressbook://\(encoded)") {
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app"))
    }

    // MARK: - Background Store Enumeration & Scoring (Non-isolated)

    private nonisolated static func fetchAllContactsFromStore() -> [ContactRecord] {
        // IMPORTANT: Never include CNContactNoteKey here — macOS 13+ requires a restricted Apple entitlement
        // for notes and throws CNErrorCodeUnauthorizedKeys under ad-hoc signing.
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        let store = CNContactStore()
        var results: [ContactRecord] = []

        do {
            try store.enumerateContacts(with: request) { cn, _ in
                if let built = buildContactRecord(from: cn) {
                    results.append(built)
                }
            }
        } catch {
            return []
        }

        return results
    }

    private nonisolated static func buildContactRecord(from cn: CNContact) -> ContactRecord? {
        let formattedName = CNContactFormatter.string(from: cn, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vnParts = [cn.familyName, cn.middleName, cn.givenName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let westParts = [cn.givenName, cn.middleName, cn.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let vnName = vnParts.joined(separator: " ")
        let westName = westParts.joined(separator: " ")
        let org = cn.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dept = cn.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = cn.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let nick = cn.nickname.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstPhone = cn.phoneNumbers.first?.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstEmail = (cn.emailAddresses.first?.value as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let displayName: String = {
            if !formattedName.isEmpty { return formattedName }
            if !vnName.isEmpty { return vnName }
            if !nick.isEmpty { return nick }
            if !org.isEmpty { return org }
            if !firstEmail.isEmpty { return firstEmail }
            if !firstPhone.isEmpty { return firstPhone }
            return ""
        }()

        guard !displayName.isEmpty else { return nil }

        let roleOrgParts = [job, dept, org].filter { !$0.isEmpty && $0 != displayName }
        let roleAndOrgLine = roleOrgParts.joined(separator: " • ")

        var fields: [ContactDetailField] = []
        var normalizedPhones: [String] = []
        var emailsLower: [String] = []

        // 1. Phone Numbers (Top priority for quick copy!)
        for (idx, labeledPhone) in cn.phoneNumbers.enumerated() {
            let rawPhone = labeledPhone.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPhone.isEmpty else { continue }
            let digits = extractDigits(from: rawPhone)
            let normPhone = normalizePhoneForComparison(digits)
            if !digits.isEmpty { normalizedPhones.append(digits) }
            if !normPhone.isEmpty && normPhone != digits { normalizedPhones.append(normPhone) }

            let label = localizedVietnameseLabel(labeledPhone.label, defaultLabel: "Điện thoại")
            let telDigits = rawPhone.filter { $0.isNumber || $0 == "+" }
            let telURL = telDigits.isEmpty ? nil : URL(string: "tel://\(telDigits)")
            fields.append(ContactDetailField(
                id: "phone:\(idx):\(rawPhone)",
                categoryLabel: label,
                displayValue: rawPhone,
                copyValue: rawPhone,
                actionURL: telURL,
                actionHint: telURL != nil ? "⌘↩ Gọi" : nil,
                sfSymbol: "phone"
            ))
        }

        // 2. Email Addresses
        for (idx, labeledEmail) in cn.emailAddresses.enumerated() {
            let email = (labeledEmail.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { continue }
            emailsLower.append(email.lowercased())
            let label = localizedVietnameseLabel(labeledEmail.label, defaultLabel: "Email", isEmail: true)
            let mailURL = URL(string: "mailto:\(email)")
            fields.append(ContactDetailField(
                id: "email:\(idx):\(email)",
                categoryLabel: label,
                displayValue: email,
                copyValue: email,
                actionURL: mailURL,
                actionHint: mailURL != nil ? "⌘↩ Gửi Mail" : nil,
                sfSymbol: "envelope"
            ))
        }

        // 3. Full Name & Nickname
        fields.append(ContactDetailField(
            id: "name:full",
            categoryLabel: "Họ và tên",
            displayValue: displayName,
            copyValue: displayName,
            actionURL: nil,
            actionHint: nil,
            sfSymbol: "person.text.rectangle"
        ))

        if !nick.isEmpty && nick != displayName {
            fields.append(ContactDetailField(
                id: "name:nick",
                categoryLabel: "Biệt danh",
                displayValue: nick,
                copyValue: nick,
                actionURL: nil,
                actionHint: nil,
                sfSymbol: "person"
            ))
        }

        // 4. Organization / Job Title
        if !roleAndOrgLine.isEmpty {
            fields.append(ContactDetailField(
                id: "org:combined",
                categoryLabel: "Chức vụ & Cơ quan",
                displayValue: roleAndOrgLine,
                copyValue: roleAndOrgLine,
                actionURL: nil,
                actionHint: nil,
                sfSymbol: "building.2"
            ))
        }

        // 5. Postal Addresses
        for (idx, labeledAddr) in cn.postalAddresses.enumerated() {
            let addr = labeledAddr.value
            let formattedAddr = CNPostalAddressFormatter.string(from: addr, style: .mailingAddress)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            guard !formattedAddr.isEmpty else { continue }
            let label = localizedVietnameseLabel(labeledAddr.label, defaultLabel: "Địa chỉ")
            let encodedQ = formattedAddr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let mapsURL = encodedQ.isEmpty ? nil : URL(string: "http://maps.apple.com/?q=\(encodedQ)")
            fields.append(ContactDetailField(
                id: "addr:\(idx)",
                categoryLabel: label,
                displayValue: formattedAddr,
                copyValue: formattedAddr,
                actionURL: mapsURL,
                actionHint: mapsURL != nil ? "⌘↩ Bản đồ" : nil,
                sfSymbol: "mappin.and.ellipse"
            ))
        }

        // 6. Birthday
        if let bday = cn.birthday, let day = bday.day, let month = bday.month {
            let bdayStr: String
            if let year = bday.year, year > 1900 && year < 3000 {
                bdayStr = String(format: "%02d/%02d/%04d", day, month, year)
            } else {
                bdayStr = String(format: "%02d/%02d", day, month)
            }
            fields.append(ContactDetailField(
                id: "birthday",
                categoryLabel: "Ngày sinh",
                displayValue: bdayStr,
                copyValue: bdayStr,
                actionURL: nil,
                actionHint: nil,
                sfSymbol: "gift"
            ))
        }

        // 7. Websites / URLs
        for (idx, labeledURL) in cn.urlAddresses.enumerated() {
            let rawURL = (labeledURL.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else { continue }
            let normalizedURLStr = (rawURL.lowercased().hasPrefix("http://") || rawURL.lowercased().hasPrefix("https://"))
                ? rawURL
                : "https://\(rawURL)"
            let webURL = URL(string: normalizedURLStr)
            let label = localizedVietnameseLabel(labeledURL.label, defaultLabel: "Website")
            fields.append(ContactDetailField(
                id: "url:\(idx):\(rawURL)",
                categoryLabel: label,
                displayValue: rawURL,
                copyValue: rawURL,
                actionURL: webURL,
                actionHint: webURL != nil ? "⌘↩ Mở Web" : nil,
                sfSymbol: "globe"
            ))
        }

        // 8. Social Profiles & Instant Messaging
        for (idx, social) in cn.socialProfiles.enumerated() {
            let service = social.value.service.isEmpty ? "Mạng xã hội" : social.value.service
            let username = social.value.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlStr = social.value.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = !username.isEmpty ? username : urlStr
            guard !val.isEmpty else { continue }
            fields.append(ContactDetailField(
                id: "social:\(idx)",
                categoryLabel: service,
                displayValue: val,
                copyValue: val,
                actionURL: URL(string: urlStr),
                actionHint: nil,
                sfSymbol: "at"
            ))
        }

        for (idx, im) in cn.instantMessageAddresses.enumerated() {
            let service = im.value.service.isEmpty ? "Tin nhắn" : im.value.service
            let username = im.value.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { continue }
            fields.append(ContactDetailField(
                id: "im:\(idx)",
                categoryLabel: service,
                displayValue: username,
                copyValue: username,
                actionURL: nil,
                actionHint: nil,
                sfSymbol: "message"
            ))
        }

        // 9. Complete Summary Card ("Sao chép toàn bộ thông tin")
        if fields.count >= 2 {
            var summaryLines: [String] = [displayName]
            if !roleAndOrgLine.isEmpty {
                summaryLines.append(roleAndOrgLine)
            }
            for f in fields where f.id.hasPrefix("phone:") || f.id.hasPrefix("email:") || f.id.hasPrefix("addr:") || f.id == "birthday" || f.id.hasPrefix("url:") {
                summaryLines.append("\(f.categoryLabel): \(f.copyValue)")
            }
            let fullCardText = summaryLines.joined(separator: "\n")
            fields.append(ContactDetailField(
                id: "summary:all",
                categoryLabel: "Toàn bộ thông tin liên hệ",
                displayValue: summaryLines.dropFirst().joined(separator: " • "),
                copyValue: fullCardText,
                actionURL: nil,
                actionHint: nil,
                sfSymbol: "doc.on.doc"
            ))
        }

        // Build list subtitle & badge
        var subParts: [String] = []
        if !roleAndOrgLine.isEmpty { subParts.append(roleAndOrgLine) }
        if !firstPhone.isEmpty { subParts.append(firstPhone) }
        if !firstEmail.isEmpty { subParts.append(firstEmail) }
        subParts.append("↩ Xem chi tiết & Copy")
        let listSubtitle = subParts.joined(separator: "  •  ")

        let badgeText: String? = {
            if !org.isEmpty && org != displayName {
                return org.count > 22 ? String(org.prefix(20)) + "…" : org
            }
            let count = cn.phoneNumbers.count + cn.emailAddresses.count
            return count > 0 ? "\(count) mục" : "Danh bạ"
        }()

        let quickField = fields.first
        let quickVal = quickField?.copyValue ?? displayName
        let quickLabel = quickField?.categoryLabel ?? "Họ và tên"

        // Precompute Vietnamese unaccented tokens & acronyms
        let combinedNameSpace = "\(displayName) \(vnName) \(westName) \(nick)"
        let unaccentedFull = GoogleDriveIndexService.removeAccents(combinedNameSpace)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawWords = unaccentedFull
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var uniqueWords: [String] = []
        var seenWord = Set<String>()
        for w in rawWords where seenWord.insert(w).inserted {
            uniqueWords.append(w)
        }

        let givenClean = GoogleDriveIndexService.cleanString(cn.givenName)

        let vnWords = GoogleDriveIndexService.removeAccents(vnName.isEmpty ? displayName : vnName)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let westWords = GoogleDriveIndexService.removeAccents(westName.isEmpty ? displayName : westName)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let acronymVN = String(vnWords.compactMap(\.first))
        let acronymWest = String(westWords.compactMap(\.first))
        let orgUnaccented = GoogleDriveIndexService.removeAccents(roleAndOrgLine).lowercased()
        let initials = buildInitials(from: displayName, givenName: cn.givenName, familyName: cn.familyName)

        return ContactRecord(
            id: cn.identifier,
            displayName: displayName,
            initials: initials,
            roleAndOrgLine: roleAndOrgLine,
            listSubtitle: listSubtitle,
            badgeText: badgeText,
            avatarData: cn.thumbnailImageData,
            primaryQuickCopyValue: quickVal,
            primaryQuickCopyLabel: quickLabel,
            fields: fields,
            unaccentedFull: unaccentedFull,
            nameWords: uniqueWords,
            givenClean: givenClean,
            acronymVN: acronymVN,
            acronymWest: acronymWest,
            orgUnaccented: orgUnaccented,
            emailsLower: emailsLower,
            normalizedPhones: normalizedPhones
        )
    }

    private nonisolated static func scoreContact(
        _ rec: ContactRecord,
        unaccentedQuery: String,
        tokens: [String],
        rawDigits: String,
        normalizedPhoneQuery: String,
        recentTimestamp: Double?
    ) -> Int? {
        var totalScore = 0

        // 1. Direct phone digit search (e.g. `0912 345` or `84912`)
        if tokens.allSatisfy({ $0.allSatisfy(\.isNumber) }), rawDigits.count >= 2 {
            var matchedPhone = false
            for p in rec.normalizedPhones {
                if p == rawDigits || (!normalizedPhoneQuery.isEmpty && p == normalizedPhoneQuery) {
                    totalScore = max(totalScore, 1400)
                    matchedPhone = true
                } else if p.hasPrefix(rawDigits) || (!normalizedPhoneQuery.isEmpty && p.hasPrefix(normalizedPhoneQuery)) {
                    totalScore = max(totalScore, 1050)
                    matchedPhone = true
                } else if p.contains(rawDigits) || (!normalizedPhoneQuery.isEmpty && p.contains(normalizedPhoneQuery)) {
                    totalScore = max(totalScore, 800)
                    matchedPhone = true
                }
            }
            if matchedPhone {
                if let ts = recentTimestamp {
                    let ageHours = max(0, (Date().timeIntervalSince1970 - ts) / 3600.0)
                    totalScore += ageHours < 72 ? 120 : 40
                }
                return totalScore
            }
        }

        guard !tokens.isEmpty else { return nil }

        // 2. Single-token acronym match (`nxh` -> `Nguyễn Xuân Hùng`)
        if tokens.count == 1 {
            let tok = tokens[0]
            if tok.count >= 2 && (rec.acronymVN == tok || rec.acronymWest == tok) {
                totalScore = max(totalScore, 950)
            } else if tok.count >= 2 && (rec.acronymVN.hasPrefix(tok) || rec.acronymWest.hasPrefix(tok)) {
                totalScore = max(totalScore, 680)
            }
        }

        // 3. Multi-token Vietnamese unaccented matching across Name, Org, Email & Phone
        var allTokensMatched = true
        var namePrefixHits = 0
        var tokenAccumScore = 0

        for tok in tokens {
            if !rec.givenClean.isEmpty && rec.givenClean == tok {
                tokenAccumScore += 520
                namePrefixHits += 1
            } else if !rec.givenClean.isEmpty && rec.givenClean.hasPrefix(tok) {
                tokenAccumScore += 390
                namePrefixHits += 1
            } else if rec.nameWords.contains(where: { $0 == tok }) {
                tokenAccumScore += 360
                namePrefixHits += 1
            } else if rec.nameWords.contains(where: { $0.hasPrefix(tok) }) {
                tokenAccumScore += 280
                namePrefixHits += 1
            } else if rec.unaccentedFull.contains(tok) {
                tokenAccumScore += 180
            } else if rec.orgUnaccented.contains(tok) {
                tokenAccumScore += 150
            } else if rec.emailsLower.contains(where: { $0.contains(tok) }) {
                tokenAccumScore += 160
            } else if tok.allSatisfy(\.isNumber) && rec.normalizedPhones.contains(where: { $0.contains(tok) }) {
                tokenAccumScore += 220
            } else {
                allTokensMatched = false
                break
            }
        }

        if allTokensMatched {
            var phraseBonus = 0
            if rec.unaccentedFull.hasPrefix(unaccentedQuery) {
                phraseBonus += 350
            } else if rec.unaccentedFull.contains(unaccentedQuery) {
                phraseBonus += 220
            }
            if namePrefixHits == tokens.count {
                phraseBonus += 180
            }
            totalScore = max(totalScore, tokenAccumScore + phraseBonus)
        }

        guard totalScore > 0 else { return nil }

        if let ts = recentTimestamp {
            let ageHours = max(0, (Date().timeIntervalSince1970 - ts) / 3600.0)
            totalScore += ageHours < 72 ? 120 : 45
        }
        return totalScore
    }

    private nonisolated static func buildInitials(from displayName: String, givenName: String, familyName: String) -> String {
        let g = givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fCh = f.first, let gCh = g.first {
            return "\(fCh)\(gCh)".uppercased()
        }
        let words = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        if let first = words.first?.first ?? displayName.first {
            return String(first).uppercased()
        }
        return "?"
    }

    private nonisolated static func extractDigits(from text: String) -> String {
        String(text.filter(\.isNumber))
    }

    private nonisolated static func normalizePhoneForComparison(_ digits: String) -> String {
        if digits.hasPrefix("84") && digits.count >= 9 {
            return "0" + String(digits.dropFirst(2))
        }
        return digits
    }

    private nonisolated static func localizedVietnameseLabel(_ rawLabel: String?, defaultLabel: String, isEmail: Bool = false) -> String {
        guard let rawLabel, !rawLabel.isEmpty else { return defaultLabel }
        switch rawLabel {
        case CNLabelPhoneNumberMobile: return "Di động"
        case CNLabelPhoneNumberiPhone: return "iPhone"
        case CNLabelPhoneNumberMain: return "Chính"
        case CNLabelWork: return isEmail ? "Email công việc" : "Công việc"
        case CNLabelHome: return isEmail ? "Email cá nhân" : "Nhà riêng"
        case CNLabelSchool: return "Trường học"
        case CNLabelOther: return isEmail ? "Email khác" : "\(defaultLabel) khác"
        case CNLabelURLAddressHomePage: return "Trang chủ"
        default:
            let loc = CNLabeledValue<NSString>.localizedString(forLabel: rawLabel)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if loc.isEmpty { return defaultLabel }
            return loc.prefix(1).uppercased() + loc.dropFirst()
        }
    }
}
