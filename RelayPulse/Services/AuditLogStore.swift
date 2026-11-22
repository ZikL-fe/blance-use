import Foundation
import Observation
import SwiftUI

enum AuditLogLevel: Int, Codable, CaseIterable, Identifiable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var id: Int { rawValue }

    static func < (lhs: AuditLogLevel, rhs: AuditLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var chineseTitle: String {
        switch self {
        case .debug: return "调试 (Debug)"
        case .info: return "信息 (Info)"
        case .warning: return "警告 (Warning)"
        case .error: return "错误 (Error)"
        }
    }

    var iconName: String {
        switch self {
        case .debug: return "ladybug.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .debug: return Color.secondary
        case .info: return Color(hex: "#38BDF8")
        case .warning: return Color(hex: "#F59E0B")
        case .error: return Color(hex: "#F43F5E")
        }
    }
}

enum AuditLogCategory: String, Codable, CaseIterable, Identifiable {
    case sync = "网络同步"
    case auth = "站点认证"
    case settlement = "利润结算"
    case scheduler = "定时任务"
    case system = "系统"

    var id: String { rawValue }
}

enum AuditLogRetention: Int, Codable, CaseIterable, Identifiable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var title: String {
        "\(rawValue) 天"
    }
}

struct AuditLogConfig: Codable, Equatable {
    var isEnabled: Bool
    var minimumLevel: AuditLogLevel
    var retentionDays: AuditLogRetention

    init(
        isEnabled: Bool = true,
        minimumLevel: AuditLogLevel = .info,
        retentionDays: AuditLogRetention = .sevenDays
    ) {
        self.isEnabled = isEnabled
        self.minimumLevel = minimumLevel
        self.retentionDays = retentionDays
    }
}

struct AuditLogEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var timestamp: Date
    var level: AuditLogLevel
    var category: AuditLogCategory
    var stationName: String?
    var message: String
    var detail: String?
    var durationMs: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: AuditLogLevel,
        category: AuditLogCategory,
        stationName: String? = nil,
        message: String,
        detail: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.stationName = stationName
        self.message = message
        self.detail = detail
        self.durationMs = durationMs
    }
}

@MainActor
@Observable
final class AuditLogStore {
    static let shared = AuditLogStore()

    var entries: [AuditLogEntry] = []
    var config: AuditLogConfig = AuditLogConfig() {
        didSet {
            saveConfig()
            pruneEntries()
        }
    }

    private let maxStoredEntries = 2000
    private var saveWorkItem: Task<Void, Never>? = nil

    private enum Keys {
        static let config = "relaypulse.auditLog.config.v1"
    }

    private init() {
        loadConfig()
        loadEntriesFromDisk()
        pruneEntries()
    }

    // MARK: - Logging API

    func log(
        _ level: AuditLogLevel,
        category: AuditLogCategory,
        station: String? = nil,
        message: String,
        detail: String? = nil,
        durationMs: Int? = nil
    ) {
        guard config.isEnabled, level >= config.minimumLevel else { return }

        let entry = AuditLogEntry(
            level: level,
            category: category,
            stationName: station,
            message: message,
            detail: detail,
            durationMs: durationMs
        )

        entries.insert(entry, at: 0)
        if entries.count > maxStoredEntries {
            entries.removeLast(entries.count - maxStoredEntries)
        }
        scheduleDiskSave()
    }

    func pruneEntries() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -config.retentionDays.rawValue, to: Date()) ?? .distantPast
        let beforeCount = entries.count
        entries.removeAll { entry in
            entry.timestamp < cutoff || entry.level < config.minimumLevel
        }
        if entries.count > maxStoredEntries {
            entries = Array(entries.prefix(maxStoredEntries))
        }
        if entries.count != beforeCount {
            saveEntriesToDiskNow()
        }
    }

    func clearAll() {
        entries.removeAll()
        saveEntriesToDiskNow()
    }

    func exportPlainText() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = [
            "# RelayPulse 审计日志导出",
            "# 保留级别: >= \(config.minimumLevel.title) | 保留时长: \(config.retentionDays.title) | 共 \(entries.count) 条",
            ""
        ]

        for entry in entries {
            var line = "[\(df.string(from: entry.timestamp))] [\(entry.level.title.uppercased())] [\(entry.category.rawValue)]"
            if let station = entry.stationName, !station.isEmpty {
                line += " [\(station)]"
            }
            line += " \(entry.message)"
            if let ms = entry.durationMs {
                line += " (\(ms)ms)"
            }
            lines.append(line)
            if let detail = entry.detail, !detail.isEmpty {
                lines.append("    详情: \(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private var logFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RelayPulse", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("audit_logs_v1.json")
    }

    private func scheduleDiskSave() {
        saveWorkItem?.cancel()
        saveWorkItem = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveEntriesToDiskNow()
        }
    }

    private func saveEntriesToDiskNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: logFileURL, options: [.atomic])
    }

    private func loadEntriesFromDisk() {
        guard let data = try? Data(contentsOf: logFileURL),
              let decoded = try? JSONDecoder().decode([AuditLogEntry].self, from: data) else {
            return
        }
        entries = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: Keys.config),
           let decoded = try? JSONDecoder().decode(AuditLogConfig.self, from: data) {
            config = decoded
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.config)
        }
    }
}
