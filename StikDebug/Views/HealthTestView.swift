//
//  HealthTestView.swift
//  iKiwi
//
//  A small test page: can this build ask for Apple Health access, write steps and
//  delete what it wrote? (Writing is limited to a few test steps.)
//

import SwiftUI
import HealthKit

@MainActor
final class HealthTestModel: ObservableObject {
    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var authorization = "尚未查詢"

    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let distanceType = HKQuantityType(.distanceWalkingRunning)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private func add(_ text: String) {
        log.append(text)
    }

    func refreshStatus() {
        switch store.authorizationStatus(for: stepType) {
        case .notDetermined: authorization = "尚未授權"
        case .sharingDenied: authorization = "已拒絕寫入"
        case .sharingAuthorized: authorization = "已允許寫入步數"
        @unknown default: authorization = "未知"
        }
    }

    func requestAccess() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let types: Set<HKSampleType> = [stepType, distanceType]
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.requestAuthorization(toShare: types, read: []) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            add("授權畫面已處理完成。")
        } catch {
            add("授權失敗：\(Self.describe(error))")
        }
        refreshStatus()
    }

    /// Writes 10 steps and 7.5 m for the last minute.
    func writeTestSteps() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let end = Date()
        let start = end.addingTimeInterval(-60)
        let samples: [HKSample] = [
            HKQuantitySample(type: stepType, quantity: HKQuantity(unit: .count(), doubleValue: 10), start: start, end: end),
            HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: 7.5), start: start, end: end)
        ]
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.save(samples) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HealthTestError.notSaved)
                    }
                }
            }
            add("已寫入 10 步與 7.5 公尺（過去一分鐘）。到「健康」app 的步數可以看到。")
        } catch {
            add("寫入失敗：\(Self.describe(error))")
        }
        refreshStatus()
    }

    /// Deletes everything this app wrote; data from the iPhone itself is not touched.
    func deleteOwnData() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        var total = 0
        do {
            for type in [stepType, distanceType] as [HKSampleType] {
                let count: Int = try await withCheckedThrowingContinuation { continuation in
                    store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: count)
                        }
                    }
                }
                total += count
            }
            add("已刪除 iKiwi 寫入的 \(total) 筆資料。")
        } catch {
            add("刪除失敗：\(Self.describe(error))")
        }
    }

    func clearLog() {
        log = []
    }

    private enum HealthTestError: Error {
        case notSaved
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("entitlement") {
            return "這個版本沒有「健康」權限（\(text)）。請安裝測試版 iKiwi-health.ipa。"
        }
        return text
    }
}

struct HealthTestView: View {
    @StateObject private var model = HealthTestModel()

    var body: some View {
        List {
            Section {
                LabeledContent("這支手機支援健康", value: model.isAvailable ? "是" : "否")
                LabeledContent("寫入權限", value: model.authorization)
            } footer: {
                Text("這是小測試：確認 iKiwi 能不能取得「健康」的寫入權限。只會寫入 10 步的測試資料，而且可以一鍵刪除。")
            }

            Section("測試") {
                Button {
                    Task { await model.requestAccess() }
                } label: {
                    Label("請求健康授權", systemImage: "heart.text.square")
                }
                Button {
                    Task { await model.writeTestSteps() }
                } label: {
                    Label("寫入測試步數（10 步）", systemImage: "figure.walk")
                }
                Button(role: .destructive) {
                    Task { await model.deleteOwnData() }
                } label: {
                    Label("刪除 iKiwi 寫入的資料", systemImage: "trash")
                }
            }
            .disabled(model.isBusy || !model.isAvailable)

            if !model.log.isEmpty {
                Section("結果") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    Button("清除結果") { model.clearLog() }
                }
            }
        }
        .navigationTitle("健康")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshStatus() }
    }
}
