//
//  SignatureExpiry.swift
//  iKiwi
//
//  When this copy of iKiwi stops opening (the SideStore signature expires), read from
//  the provisioning profile inside the app, plus a once-a-day reminder.
//

import SwiftUI
import UIKit

enum SignatureExpiry {
    /// The "ExpirationDate" of the profile SideStore embedded in this app.
    static var expirationDate: Date? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8)) else {
            return nil
        }
        let plistData = raw.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    /// "2 天 5 小時", "7 小時", "不到 1 小時", "已經到期"
    static func remainingText(until expiry: Date, now: Date = Date()) -> String {
        let seconds = expiry.timeIntervalSince(now)
        if seconds <= 0 { return "已經到期" }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days > 0 { return "\(days) 天 \(hours) 小時" }
        if hours > 0 { return "\(hours) 小時" }
        return "不到 1 小時"
    }

    /// "11/25 14:30" (24-hour).
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    static func openSideStore() {
        guard let url = URL(string: "sidestore://") else { return }
        UIApplication.shared.open(url)
    }
}

struct SignatureExpiryInfo: Identifiable {
    let expiry: Date
    var id: Date { expiry }
}

@MainActor
final class SignatureExpiryChecker: ObservableObject {
    static let shared = SignatureExpiryChecker()

    static let warningDays = 3.0
    private static let lastCheckKey = "wayfarer.lastSignatureCheckDay"

    /// Set when the reminder should be shown.
    @Published var prompt: SignatureExpiryInfo?

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The first time iKiwi is opened on a given day: remind if fewer than 3 days
    /// are left. The day is marked as checked once the check has been made (or the
    /// user chose to update), so there is at most one reminder per day.
    ///
    /// A new version comes first: installing it refreshes the signature too, so the
    /// reminder only follows if that prompt was answered with "later" or "skip".
    func checkIfNeeded() {
        let today = Self.dayString(Date())
        guard UserDefaults.standard.string(forKey: Self.lastCheckKey) != today else { return }

        let updater = UpdateChecker.shared
        guard updater.launchCheckFinished, updater.available == nil else { return }

        guard let expiry = SignatureExpiry.expirationDate else { return }
        UserDefaults.standard.set(today, forKey: Self.lastCheckKey)
        if expiry.timeIntervalSinceNow < Self.warningDays * 86_400 {
            prompt = SignatureExpiryInfo(expiry: expiry)
        }
    }

    /// Updating was chosen: the signature will be renewed, so no reminder today.
    func markCheckedToday() {
        UserDefaults.standard.set(Self.dayString(Date()), forKey: Self.lastCheckKey)
    }

    /// Used right after the update prompt closes; a short wait lets that alert finish
    /// going away before the next one appears.
    func checkAfterUpdatePrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.checkIfNeeded()
        }
    }
}

/// Runs the daily check when the app opens or returns to the foreground, and shows
/// the reminder.
struct SignatureExpiryPromptModifier: ViewModifier {
    @ObservedObject private var checker = SignatureExpiryChecker.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                checker.checkIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    checker.checkIfNeeded()
                }
            }
            .alert(
                "簽章快到期了",
                isPresented: Binding(
                    get: { checker.prompt != nil },
                    set: { isPresented in
                        if !isPresented {
                            checker.prompt = nil
                        }
                    }
                ),
                presenting: checker.prompt
            ) { _ in
                Button("確認，前往 SideStore") {
                    checker.prompt = nil
                    SignatureExpiry.openSideStore()
                }
                Button("取消", role: .cancel) {
                    checker.prompt = nil
                }
            } message: { info in
                Text("iKiwi 的簽章還剩 \(SignatureExpiry.remainingText(until: info.expiry))（\(SignatureExpiry.dateText(info.expiry)) 到期）。到期後 app 會打不開，請到 SideStore 更新簽章。今天不會再提醒。")
            }
    }
}

extension View {
    func signatureExpiryPrompt() -> some View {
        modifier(SignatureExpiryPromptModifier())
    }
}

/// Marks the risky device query on the "other apps" page, so a crash there is noticed
/// the next time and the page does not crash again by itself.
enum ProfileLoadGuard {
    private static let flagKey = "wayfarer.profileLoadInProgress"
    private static let stageKey = "wayfarer.profileLoadStage"

    static var crashedLastTime: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    static var lastStage: String {
        UserDefaults.standard.string(forKey: stageKey) ?? "未知"
    }

    static func mark(_ stage: String) {
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(stage, forKey: stageKey)
    }

    static func finish() {
        UserDefaults.standard.set(false, forKey: flagKey)
    }
}
