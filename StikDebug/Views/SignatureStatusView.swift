//
//  SignatureStatusView.swift
//  iKiwi
//
//  "App 到期日": iKiwi's own signature, read locally (no device connection), with the
//  device-wide list kept behind a guarded entry.
//

import SwiftUI

struct SignatureStatusView: View {
    private let expiry = SignatureExpiry.expirationDate

    private func color(for expiry: Date) -> Color {
        let days = expiry.timeIntervalSinceNow / 86_400
        if days < 1 { return .red }
        if days < SignatureExpiryChecker.warningDays { return .orange }
        return .green
    }

    var body: some View {
        List {
            Section {
                if let expiry {
                    LabeledContent("到期時間", value: SignatureExpiry.dateText(expiry))
                    LabeledContent("剩餘時間") {
                        Text(SignatureExpiry.remainingText(until: expiry))
                            .foregroundStyle(color(for: expiry))
                    }
                } else {
                    Text("讀不到簽章資訊（可能不是用 SideStore 安裝）。")
                        .foregroundStyle(.secondary)
                }
                Button {
                    SignatureExpiry.openSideStore()
                } label: {
                    Label("前往 SideStore 更新簽章", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                Text("iKiwi")
            } footer: {
                Text("每天第一次打開 iKiwi 時，如果剩不到 3 天，會提醒你更新簽章。")
            }

            Section {
                NavigationLink {
                    ProfileGateView()
                } label: {
                    Label("查看其他 App 的到期日（進階）", systemImage: "list.bullet")
                }
            } footer: {
                Text("這會連到手機讀取所有描述檔，需要 LocalDevVPN 連線。")
            }
        }
        .navigationTitle("App 到期日")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Opens the device-wide list unless the last attempt ended in a crash.
struct ProfileGateView: View {
    @State private var allowed = !ProfileLoadGuard.crashedLastTime

    var body: some View {
        if allowed {
            ProfileView()
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "上次載入時 app 閃退了",
                    systemImage: "exclamationmark.triangle",
                    description: Text("為避免再次閃退，這一頁沒有自動載入。上次停在：\(ProfileLoadGuard.lastStage)")
                )
                Button("仍要嘗試") {
                    ProfileLoadGuard.finish()
                    allowed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
