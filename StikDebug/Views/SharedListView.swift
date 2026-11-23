//
//  SharedListView.swift
//  iKiwi
//
//  A coordinate list shared with friends. Everyone in the same "room" can add,
//  edit and delete entries; the data lives in a small Supabase project that is
//  reached through two SQL functions (see docs/shared-list.sql).
//

import SwiftUI
import CoreLocation

// MARK: - Configuration

enum SharedListConfig {
    static let baseURL = "https://owezhjncoqxmkrzioghr.supabase.co"
    /// Publishable key: safe to ship in the app. What it can do is limited by the
    /// database (no direct table access, only the room functions).
    static let apiKey = "sb_publishable_nH23b26IfCiypr_jcHGizw_JfEqGy_9"
    static let inviteBase = "https://mimi860821.github.io/iKiwi/join.html"
}

// MARK: - Models

struct SharedItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var category: String = ""
    var note: String = ""
    var deleted = false
    /// Bumped on every local change; `syncedVersion` is the version the server has.
    var version = 1
    var syncedVersion = 0
    /// When the entry was added (from the server; the local time until it is known).
    var createdAt: Date?
    /// Looked up on this phone from the coordinates; not shared.
    var countryCode: String?
    var timeZoneID: String?
    /// The emoji of whoever added the entry ("" for entries from before members).
    var createdBy: String = ""
    /// When it was moved to the trash; it is deleted for good 30 days later.
    var deletedAt: Date?
    /// Asked to be deleted for good; removed from this phone once the server did it.
    var purge = false

    var isPending: Bool { version != syncedVersion }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RemoteSharedItem: Decodable {
    let id: UUID
    let name: String
    let lat: Double
    let lng: Double
    let category: String
    let note: String
    let deleted: Bool
    let updated_at: String
    /// Added to the table later; older servers do not send these.
    let created_at: String?
    let created_by: String?
    let deleted_at: String?
}

private struct SharedSnapshot: Codable {
    var room: String?
    var items: [SharedItem]
    var cursor: String?
    var memberID: UUID?
    var emoji: String?
}

enum SharedListError: Error {
    case message(String)
}

enum SharedCoordinateText {
    /// "25.033,121.565" (also accepts spaces, ";" and full-width commas).
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let numbers = text
            .split(whereSeparator: { ",， \t\n;".contains($0) })
            .compactMap { Double($0) }
        guard numbers.count == 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1])
    }
}

enum SharedDateText {
    /// "2026-11-21T03:04:05.123456+00:00" from the server.
    static func parseServerDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withoutFraction = text.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: withoutFraction)
    }

    /// "11/21 14:35" in the phone's time zone, 24-hour (with the year if not this year).
    static func addedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        formatter.dateFormat = sameYear ? "M/d HH:mm" : "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Store

@MainActor
final class SharedListStore: ObservableObject {
    static let shared = SharedListStore()

    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var room: String?
    @Published private(set) var items: [SharedItem] = []
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastSynced: Date?
    /// Set when an invite link is opened; the app asks before joining.
    @Published var pendingJoinCode: String?
    /// This person's emoji in the room (nil until the server has given one).
    @Published private(set) var myEmoji: String?

    /// Days an entry stays in the trash.
    static let trashDays = 30
    private static let lastEmojiKey = "wayfarer.sharedLastEmoji"

    private var memberID: UUID?
    /// True once the server answered the member functions (an older database does not).
    private var serverHasMembers = false
    private var cursor: String?
    private var isSyncing = false
    private var needsAnotherSync = false
    private let fileURL: URL

    private static let epoch = "1970-01-01T00:00:00Z"

    private init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wayfarer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("shared.json")

        if let raw = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(SharedSnapshot.self, from: raw) {
            room = snapshot.room
            items = snapshot.items
            cursor = snapshot.cursor
            memberID = snapshot.memberID
            myEmoji = snapshot.emoji
        }
    }

    var visibleItems: [SharedItem] {
        items.filter { !$0.deleted && !$0.purge }
    }

    /// Entries in the trash, most recently deleted first.
    var trashedItems: [SharedItem] {
        items
            .filter { $0.deleted && !$0.purge && trashDaysLeft($0) > 0 }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func trashDaysLeft(_ item: SharedItem, now: Date = Date()) -> Int {
        guard let deletedAt = item.deletedAt else { return Self.trashDays }
        let elapsed = now.timeIntervalSince(deletedAt) / 86_400
        return max(0, Int((Double(Self.trashDays) - elapsed).rounded(.up)))
    }

    var pendingCount: Int {
        items.filter { $0.isPending }.count
    }

    var categories: [String] {
        let names = visibleItems
            .map { $0.category.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var inviteText: String {
        guard let room else { return "" }
        return "來加入我的 iKiwi 共享清單吧！\n"
            + "\(SharedListConfig.inviteBase)#\(room)\n\n"
            + "如果連結打不開，請在 iKiwi 的「共享清單」選「加入朋友的房間」，貼上這組房間碼：\n"
            + room
    }

    private func save() {
        let snapshot = SharedSnapshot(room: room, items: items, cursor: cursor, memberID: memberID, emoji: myEmoji)
        if let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Rooms

    static func extractRoomCode(from text: String) -> String? {
        let lowered = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-f]{32}"),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let range = Range(match.range, in: lowered) else {
            return nil
        }
        return String(lowered[range])
    }

    private static func randomRoomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    /// Gives up this person's place (and emoji) in the room they are in. The emoji is
    /// remembered so that the next time a different one is drawn.
    private func releaseMembership() {
        let oldRoom = room
        let oldMember = memberID
        let supported = serverHasMembers
        if let myEmoji {
            UserDefaults.standard.set(myEmoji, forKey: Self.lastEmojiKey)
        }
        memberID = nil
        myEmoji = nil
        serverHasMembers = false
        if supported, let oldRoom, let oldMember {
            Task {
                _ = try? await Self.rpc("ikiwi_leave", [
                    "p_room": oldRoom,
                    "p_member": oldMember.uuidString.lowercased()
                ])
            }
        }
    }

    func createRoom() {
        releaseMembership()
        room = Self.randomRoomCode()
        items = []
        cursor = nil
        syncState = .idle
        save()
    }

    @discardableResult
    func joinRoom(from text: String) -> Bool {
        guard let code = Self.extractRoomCode(from: text) else { return false }
        if code == room { return true }
        releaseMembership()
        room = code
        items = []
        cursor = nil
        lastSynced = nil
        syncState = .idle
        save()
        Task { await sync(full: true) }
        return true
    }

    func leaveRoom() {
        releaseMembership()
        room = nil
        items = []
        cursor = nil
        lastSynced = nil
        syncState = .idle
        save()
    }

    // MARK: Editing

    func addItem(name: String, coordinate: CLLocationCoordinate2D, category: String, note: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
            : trimmed
        items.append(SharedItem(
            name: finalName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            createdBy: myEmoji ?? ""
        ))
        changed()
    }

    func updateItem(_ id: UUID, name: String, coordinate: CLLocationCoordinate2D, category: String, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].name = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
            : trimmed
        if items[index].latitude != coordinate.latitude || items[index].longitude != coordinate.longitude {
            items[index].countryCode = nil
            items[index].timeZoneID = nil
        }
        items[index].latitude = coordinate.latitude
        items[index].longitude = coordinate.longitude
        items[index].category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].version += 1
        changed()
    }

    /// Moves an entry to the trash (kept for 30 days).
    func deleteItem(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deleted = true
        items[index].deletedAt = Date()
        items[index].version += 1
        changed()
    }

    func restoreItem(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deleted = false
        items[index].deletedAt = nil
        items[index].version += 1
        changed()
    }

    /// Deletes an entry from the trash for good, for everyone in the room.
    func purgeItem(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].deleted else { return }
        items[index].purge = true
        items[index].version += 1
        changed()
    }

    func emptyTrash() {
        for id in trashedItems.map({ $0.id }) {
            purgeItem(id)
        }
    }

    /// Draws a new emoji: leaves the room's member list and joins again.
    func rerollEmoji() async -> String {
        guard let currentRoom = room else { return "" }
        guard serverHasMembers, let oldMember = memberID else {
            return "伺服器還沒有升級成員功能，請先在 Supabase 執行新的 SQL。"
        }
        let old = myEmoji
        do {
            _ = try await Self.rpc("ikiwi_leave", [
                "p_room": currentRoom,
                "p_member": oldMember.uuidString.lowercased()
            ])
        } catch {
            return Self.describe(error)
        }

        let newMember = UUID()
        do {
            let data = try await Self.rpc("ikiwi_join", [
                "p_room": currentRoom,
                "p_member": newMember.uuidString.lowercased(),
                "p_avoid": old ?? ""
            ])
            guard let emoji = try? JSONDecoder().decode(String.self, from: data) else {
                throw SharedListError.message("伺服器回應異常。")
            }
            memberID = newMember
            myEmoji = emoji
            serverHasMembers = true
            save()
            return "你的新表情是 \(emoji)"
        } catch {
            // The old place is gone; the next sync joins again.
            memberID = nil
            myEmoji = nil
            serverHasMembers = false
            save()
            return Self.describe(error)
        }
    }

    private func changed() {
        save()
        Task { await sync() }
    }

    // MARK: Sync

    /// Sends local changes, then fetches what others changed. `full` re-reads the
    /// whole room instead of only what is new.
    func sync(full: Bool = false) async {
        guard room != nil else { return }
        if isSyncing {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        var fullPull = full

        repeat {
            needsAnotherSync = false
            guard let currentRoom = room else { break }
            syncState = .syncing
            do {
                await ensureMember(room: currentRoom)
                try await push(room: currentRoom)
                try await pull(room: currentRoom, full: fullPull)
                if room == currentRoom {
                    lastSynced = Date()
                    syncState = .idle
                }
            } catch {
                syncState = .failed(Self.describe(error))
            }
            fullPull = false
        } while needsAnotherSync

        isSyncing = false
    }

    /// Joins the room's member list the first time (and after an app restart, where it
    /// just gets the same emoji back). An older database without the member functions
    /// is simply skipped.
    private func ensureMember(room currentRoom: String) async {
        if memberID == nil {
            memberID = UUID()
        }
        guard !serverHasMembers, let member = memberID else { return }
        let avoid = UserDefaults.standard.string(forKey: Self.lastEmojiKey) ?? ""
        do {
            let data = try await Self.rpc("ikiwi_join", [
                "p_room": currentRoom,
                "p_member": member.uuidString.lowercased(),
                "p_avoid": avoid
            ])
            if room == currentRoom, let emoji = try? JSONDecoder().decode(String.self, from: data) {
                myEmoji = emoji
                serverHasMembers = true
                save()
            }
        } catch {
            // No member functions on the server yet: entries just carry no emoji.
        }
    }

    private func push(room currentRoom: String) async throws {
        let pending = items.filter { $0.isPending }
        guard !pending.isEmpty else { return }

        var start = 0
        while start < pending.count {
            let chunk = Array(pending[start..<min(start + 200, pending.count)])
            start += 200

            let payload: [[String: Any]] = chunk.map { item in
                [
                    "id": item.id.uuidString.lowercased(),
                    "name": item.name,
                    "lat": item.latitude,
                    "lng": item.longitude,
                    "category": item.category,
                    "note": item.note,
                    "deleted": item.deleted,
                    "created_by": item.createdBy,
                    "purge": item.purge
                ]
            }
            _ = try await Self.rpc("ikiwi_push", ["p_room": currentRoom, "p_items": payload])

            guard room == currentRoom else { return }
            for sent in chunk {
                if let index = items.firstIndex(where: { $0.id == sent.id }),
                   items[index].version == sent.version {
                    items[index].syncedVersion = sent.version
                }
            }
            // Entries deleted for good on the server go from this phone too.
            items.removeAll { $0.purge && !$0.isPending }
            save()
        }
    }

    private func pull(room currentRoom: String, full: Bool) async throws {
        let since = full ? Self.epoch : (cursor ?? Self.epoch)
        var arguments: [String: Any] = ["p_room": currentRoom, "p_since": since]
        if serverHasMembers, let member = memberID {
            arguments["p_member"] = member.uuidString.lowercased()
        }
        let data = try await Self.rpc("ikiwi_pull", arguments)
        let remote = try JSONDecoder().decode([RemoteSharedItem].self, from: data)
        guard room == currentRoom else { return }

        for entry in remote {
            if let index = items.firstIndex(where: { $0.id == entry.id }) {
                // Our own unsent change wins until it has been uploaded.
                if items[index].isPending { continue }
                if items[index].latitude != entry.lat || items[index].longitude != entry.lng {
                    items[index].countryCode = nil
                    items[index].timeZoneID = nil
                }
                if let created = SharedDateText.parseServerDate(entry.created_at) {
                    items[index].createdAt = created
                }
                if let by = entry.created_by, !by.isEmpty {
                    items[index].createdBy = by
                }
                items[index].deletedAt = entry.deleted ? SharedDateText.parseServerDate(entry.deleted_at) ?? items[index].deletedAt : nil
                items[index].name = entry.name
                items[index].latitude = entry.lat
                items[index].longitude = entry.lng
                items[index].category = entry.category
                items[index].note = entry.note
                items[index].deleted = entry.deleted
            } else {
                items.append(SharedItem(
                    id: entry.id,
                    name: entry.name,
                    latitude: entry.lat,
                    longitude: entry.lng,
                    category: entry.category,
                    note: entry.note,
                    deleted: entry.deleted,
                    version: 0,
                    syncedVersion: 0,
                    createdAt: SharedDateText.parseServerDate(entry.created_at),
                    createdBy: entry.created_by ?? "",
                    deletedAt: entry.deleted ? SharedDateText.parseServerDate(entry.deleted_at) : nil
                ))
            }
        }
        if let newest = remote.last?.updated_at {
            cursor = newest
        }

        // A full read lists everything in the room: what is missing was deleted for
        // good by someone. (Not applied to a very long list, which the server may cut.)
        if full && remote.count < 900 {
            let present = Set(remote.map { $0.id })
            items.removeAll { !present.contains($0.id) && !$0.isPending }
        }
        // Trash older than 30 days is gone (the server deletes it as well).
        items.removeAll { $0.deleted && !$0.isPending && $0.deletedAt != nil && trashDaysLeft($0) == 0 }
        save()
        Task { await fillMissingPlaceInfo() }
    }

    private var isFillingPlaceInfo = false

    /// Looks up country and time zone for entries that lack them (names saved or
    /// looked up before are reused). One request at a time to respect rate limits.
    func fillMissingPlaceInfo() async {
        guard !isFillingPlaceInfo else { return }
        isFillingPlaceInfo = true
        defer { isFillingPlaceInfo = false }

        let pendingIDs = items.filter { !$0.deleted && $0.timeZoneID == nil }.map { $0.id }
        for id in pendingIDs {
            guard let item = items.first(where: { $0.id == id }) else { continue }

            if let known = PlaceCache.lookup(item.coordinate) ?? FavoritesStore.shared.knownPlace(near: item.coordinate),
               known.timeZoneID != nil {
                setPlaceInfo(id: id, countryCode: known.countryCode, timeZoneID: known.timeZoneID)
                continue
            }

            // nil means the lookup itself failed (offline, throttled): try again later.
            guard let info = await PlaceInfoResolver.resolve(item.coordinate) else { return }
            PlaceCache.store(item.coordinate, title: info.title, timeZoneID: info.timeZoneID, countryCode: info.countryCode)
            setPlaceInfo(id: id, countryCode: info.countryCode, timeZoneID: info.timeZoneID)
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }

    private func setPlaceInfo(id: UUID, countryCode: String?, timeZoneID: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].countryCode = countryCode
        items[index].timeZoneID = timeZoneID
        save()
    }

    /// Checks that the server answers, using a throw-away room that stays empty.
    func testConnection() async -> String {
        let probe = Self.randomRoomCode()
        do {
            let data = try await Self.rpc("ikiwi_pull", ["p_room": probe, "p_since": Self.epoch])
            _ = try JSONDecoder().decode([RemoteSharedItem].self, from: data)
            return "連線成功，伺服器正常。"
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: Network

    private static func rpc(_ name: String, _ body: [String: Any]) async throws -> Data {
        guard let url = URL(string: SharedListConfig.baseURL + "/rest/v1/rpc/" + name) else {
            throw SharedListError.message("伺服器網址格式錯誤。")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(SharedListConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SharedListError.message("伺服器回應異常。")
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw SharedListError.message("伺服器拒絕了請求（金鑰或權限不正確）。")
            case 404:
                throw SharedListError.message("伺服器上找不到共享清單的函式，請確認 SQL 已在 Supabase 執行。")
            case 503, 540:
                throw SharedListError.message("Supabase 專案可能已暫停，請到 Supabase 網站按「Restore」喚醒。")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw SharedListError.message("伺服器回應錯誤（\(http.statusCode)）：\(body.prefix(120))")
            }
        }
        return data
    }

    private static func describe(_ error: Error) -> String {
        if let shared = error as? SharedListError, case .message(let text) = shared {
            return text
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "目前沒有網路，連上網路後會自動同步。"
            case .timedOut:
                return "連線逾時，請稍後再試。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "連不上伺服器。若專案閒置超過 7 天，需要到 Supabase 網站喚醒。"
            default:
                return "網路錯誤（\(urlError.code.rawValue)）。"
            }
        }
        return "同步失敗：\(error.localizedDescription)"
    }
}

// MARK: - Views

/// The standard iOS share sheet. (SwiftUI's ShareLink does not open reliably from
/// inside a menu in a sheet.)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SharedEditorTarget: Identifiable {
    let id = UUID()
    var item: SharedItem?
}

struct SharedListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SharedListStore.shared

    /// The pin currently on the map, offered as the default when adding.
    let currentPin: CLLocationCoordinate2D?
    let onPick: (SharedItem) -> Void
    let onTeleport: (SharedItem) -> Void

    @State private var joinText = ""
    @State private var editorTarget: SharedEditorTarget?
    @State private var infoMessage: String?
    @State private var showLeaveConfirm = false
    @State private var isTesting = false
    @State private var showShareSheet = false
    @State private var showTrash = false

    private var groups: [(title: String, items: [SharedItem])] {
        let grouped = Dictionary(grouping: store.visibleItems) {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keys = grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return keys.map { key in
            let sorted = (grouped[key] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (title: key.isEmpty ? "未分類" : key, items: sorted)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.room == nil {
                    startView
                } else {
                    listView
                }
            }
            .navigationTitle("共享清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
                if store.room != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            editorTarget = SharedEditorTarget(item: nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("新增座標")

                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("邀請朋友")

                        Menu {
                            Button {
                                UIPasteboard.general.string = store.inviteText
                                infoMessage = "已複製邀請文字，可以直接貼到 LINE 或訊息。"
                            } label: {
                                Label("複製邀請文字", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = store.room
                                infoMessage = "已複製房間碼。"
                            } label: {
                                Label("複製房間碼", systemImage: "key")
                            }
                            Button {
                                showTrash = true
                            } label: {
                                Label(store.trashedItems.isEmpty ? "垃圾桶" : "垃圾桶（\(store.trashedItems.count)）",
                                      systemImage: "trash")
                            }
                            if let emoji = store.myEmoji {
                                Button {
                                    Task { infoMessage = await store.rerollEmoji() }
                                } label: {
                                    Label("我的表情 \(emoji)，換一個", systemImage: "face.smiling")
                                }
                            }
                            Button {
                                Task { await store.sync(full: true) }
                            } label: {
                                Label("重新整理", systemImage: "arrow.clockwise")
                            }
                            Button {
                                runConnectionTest()
                            } label: {
                                Label("測試連線", systemImage: "wifi")
                            }
                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label("離開這個房間", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .task(id: store.room) {
                await store.fillMissingPlaceInfo()
                await store.sync(full: true)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if Task.isCancelled { break }
                    await store.sync()
                }
            }
            .navigationDestination(isPresented: $showTrash) {
                SharedTrashView()
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityView(items: [store.inviteText])
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editorTarget) { target in
                SharedItemEditor(
                    item: target.item,
                    defaultCoordinate: currentPin,
                    categories: store.categories
                ) { name, coordinate, category, note in
                    if let existing = target.item {
                        store.updateItem(existing.id, name: name, coordinate: coordinate, category: category, note: note)
                    } else {
                        store.addItem(name: name, coordinate: coordinate, category: category, note: note)
                    }
                }
            }
            .alert("共享清單", isPresented: Binding(
                get: { infoMessage != nil },
                set: { if !$0 { infoMessage = nil } }
            )) {
                Button("好", role: .cancel) { }
            } message: {
                Text(infoMessage ?? "")
            }
            .alert("離開這個房間？", isPresented: $showLeaveConfirm) {
                Button("離開", role: .destructive) { store.leaveRoom() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("離開後這支手機不再顯示房間內容，但房間裡的資料還在，之後用房間碼可以再加入。你的表情會釋放出來，再加入時會抽一個新的。尚未上傳的修改會遺失。")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: No room yet

    private var startView: some View {
        List {
            Section {
                Text("和朋友共用一份座標清單：房間裡的每個人都可以新增、編輯、刪除，大家看到的內容會自動同步。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    store.createRoom()
                } label: {
                    Label("建立共享房間", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("建立後可以用「邀請朋友」把連結傳給朋友。")
            }

            Section {
                TextField("貼上邀請連結或房間碼", text: $joinText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("貼上剪貼簿") {
                    joinText = UIPasteboard.general.string ?? ""
                }
                Button("加入") {
                    if store.joinRoom(from: joinText) {
                        joinText = ""
                    } else {
                        infoMessage = "找不到有效的房間碼。房間碼是 32 個英數字。"
                    }
                }
                .disabled(SharedListStore.extractRoomCode(from: joinText) == nil)
            } header: {
                Text("加入朋友的房間")
            }

            Section {
                Button {
                    runConnectionTest()
                } label: {
                    Label(isTesting ? "測試中…" : "測試連線", systemImage: "wifi")
                }
                .disabled(isTesting)
            }
        }
    }

    // MARK: In a room

    private var listView: some View {
        VStack(spacing: 0) {
            if store.visibleItems.isEmpty {
                ContentUnavailableView(
                    "清單還是空的",
                    systemImage: "mappin.slash",
                    description: Text("按右上角的「＋」新增第一個座標，或請朋友加入後一起新增。")
                )
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await store.sync(full: true)
                }
            }

            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            switch store.syncState {
            case .syncing:
                ProgressView().controlSize(.small)
                Text("同步中…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
            case .idle:
                Image(systemName: "checkmark.icloud")
                if let last = store.lastSynced {
                    Text("已同步 \(Self.timeText(last))")
                } else {
                    Text("尚未同步")
                }
            }
            if store.pendingCount > 0 {
                Text("· 待上傳 \(store.pendingCount) 筆")
            }
            Spacer(minLength: 0)
            if let emoji = store.myEmoji {
                Text("我是 \(emoji)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "，🦊新增 11/21 14:35" (or " · 新增 …" for entries without an emoji).
    private static func addedSuffix(for item: SharedItem) -> String {
        guard let created = item.createdAt else { return "" }
        let time = SharedDateText.addedText(created)
        if item.createdBy.isEmpty {
            return " · 新增 \(time)"
        }
        return "，\(item.createdBy)新增 \(time)"
    }

    private func row(_ item: SharedItem) -> some View {
        Button {
            onTeleport(item)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.primary)
                TimelineView(.everyMinute) { context in
                    Text(TimeZoneFormat.describe(
                        countryCode: item.countryCode,
                        timeZoneID: item.timeZoneID,
                        at: context.date
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(String(format: "%.5f, %.5f", item.latitude, item.longitude)
                     + Self.addedSuffix(for: item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                onPick(item)
                dismiss()
            } label: {
                Label("放置圖釘", systemImage: "mappin")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteItem(item.id)
            } label: {
                Label("垃圾桶", systemImage: "trash")
            }
            Button {
                editorTarget = SharedEditorTarget(item: item)
            } label: {
                Label("編輯", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                onPick(item)
                dismiss()
            } label: {
                Label("只放置圖釘（不瞬移）", systemImage: "mappin")
            }
            Button {
                CoordinateClipboard.copy(CoordinateClipboard.text(for: item.coordinate))
            } label: {
                Label("複製座標", systemImage: "doc.on.doc")
            }
            Button {
                FavoritesStore.shared.addCoordinate(name: item.name, coordinate: item.coordinate, categoryID: nil)
                Task { await FavoritesStore.shared.fillMissingPlaceInfo() }
                infoMessage = "已加入我的收藏。"
            } label: {
                Label("加入我的收藏", systemImage: "star")
            }
            Button {
                editorTarget = SharedEditorTarget(item: item)
            } label: {
                Label("編輯", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteItem(item.id)
            } label: {
                Label("移到垃圾桶", systemImage: "trash")
            }
        }
    }

    private func runConnectionTest() {
        guard !isTesting else { return }
        isTesting = true
        Task {
            let result = await store.testConnection()
            isTesting = false
            infoMessage = result
        }
    }
}

/// Entries deleted from the list; kept for 30 days, then removed automatically.
struct SharedTrashView: View {
    @ObservedObject private var store = SharedListStore.shared
    @State private var showEmptyConfirm = false

    var body: some View {
        Group {
            if store.trashedItems.isEmpty {
                ContentUnavailableView(
                    "垃圾桶是空的",
                    systemImage: "trash",
                    description: Text("刪除的座標會先放在這裡 \(SharedListStore.trashDays) 天，之後自動永久刪除。")
                )
            } else {
                List {
                    Section {
                        ForEach(store.trashedItems) { item in
                            row(item)
                        }
                    } footer: {
                        Text("向右滑還原，向左滑永久刪除。房間裡的每個人都能還原或永久刪除。超過 \(SharedListStore.trashDays) 天會自動永久刪除。")
                    }
                }
            }
        }
        .navigationTitle("垃圾桶")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { showEmptyConfirm = true }
                    .disabled(store.trashedItems.isEmpty)
            }
        }
        .alert("永久刪除垃圾桶裡的全部座標？", isPresented: $showEmptyConfirm) {
            Button("永久刪除", role: .destructive) { store.emptyTrash() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("房間裡的每個人都會看不到這些座標，無法復原。")
        }
    }

    private func row(_ item: SharedItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
            Text(String(format: "%.5f, %.5f", item.latitude, item.longitude))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(detail(item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .leading) {
            Button {
                store.restoreItem(item.id)
            } label: {
                Label("還原", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.purgeItem(item.id)
            } label: {
                Label("永久刪除", systemImage: "trash.slash")
            }
        }
    }

    private func detail(_ item: SharedItem) -> String {
        let left = "剩 \(store.trashDaysLeft(item)) 天"
        guard let deletedAt = item.deletedAt else { return left }
        return "刪除於 \(SharedDateText.addedText(deletedAt)) · \(left)"
    }
}

struct SharedItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    let item: SharedItem?
    let defaultCoordinate: CLLocationCoordinate2D?
    let categories: [String]
    let onSave: (String, CLLocationCoordinate2D, String, String) -> Void

    @State private var name = ""
    @State private var coordinateText = ""
    @State private var category = ""
    @State private var note = ""
    @State private var didLoad = false

    private var parsedCoordinate: CLLocationCoordinate2D? {
        SharedCoordinateText.parse(coordinateText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("例如：公園入口", text: $name)
                }

                Section {
                    TextField("緯度,經度", text: $coordinateText)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("貼上剪貼簿的座標") {
                        coordinateText = UIPasteboard.general.string ?? ""
                    }
                } header: {
                    Text("座標")
                } footer: {
                    if parsedCoordinate == nil && !coordinateText.isEmpty {
                        Text("格式不正確，請輸入像 25.033000,121.565400 這樣的緯度與經度。")
                    } else {
                        Text("例如 25.033000,121.565400。新增時預設為地圖上目前的圖釘。")
                    }
                }

                Section("分類") {
                    TextField("選填", text: $category)
                    if !categories.isEmpty {
                        Menu("選擇現有分類") {
                            ForEach(categories, id: \.self) { name in
                                Button(name) { category = name }
                            }
                        }
                    }
                }

                Section("備註") {
                    TextField("選填", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(item == nil ? "新增座標" : "編輯座標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("儲存") {
                        if let coordinate = parsedCoordinate {
                            onSave(name, coordinate, category, note)
                            dismiss()
                        }
                    }
                    .disabled(parsedCoordinate == nil)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if let item {
                    name = item.name
                    coordinateText = String(format: "%.6f,%.6f", item.latitude, item.longitude)
                    category = item.category
                    note = item.note
                } else if let defaultCoordinate {
                    coordinateText = CoordinateClipboard.text(for: defaultCoordinate)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Save to the shared list" for the pin on the map, without opening the list.
struct SharedSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SharedListStore.shared

    let coordinate: CLLocationCoordinate2D

    var body: some View {
        if store.room == nil {
            NavigationStack {
                ContentUnavailableView(
                    "還沒有共享房間",
                    systemImage: "person.2.slash",
                    description: Text("請先到左上角的「共享清單」建立或加入房間，之後就能直接從這裡收藏。")
                )
                .navigationTitle("收藏到共享")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("關閉") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium])
        } else {
            SharedItemEditor(
                item: nil,
                defaultCoordinate: coordinate,
                categories: store.categories
            ) { name, point, category, note in
                store.addItem(name: name, coordinate: point, category: category, note: note)
            }
        }
    }
}
