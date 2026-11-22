import SwiftUI

struct AuditLogView: View {
    @Environment(AuditLogStore.self) private var auditStore

    @State private var filterLevel: AuditLogLevel? = nil
    @State private var searchText: String = ""
    @State private var expandedEntryIDs: Set<UUID> = []
    @State private var showClearConfirm: Bool = false

    private var filteredEntries: [AuditLogEntry] {
        auditStore.entries.filter { entry in
            if let level = filterLevel, entry.level != level {
                return false
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !q.isEmpty {
                let hay = [
                    entry.message,
                    entry.detail ?? "",
                    entry.stationName ?? "",
                    entry.category.rawValue,
                    entry.level.title
                ].joined(separator: " ").lowercased()
                return hay.contains(q)
            }
            return true
        }
    }

    private var warningOrErrorCount: Int {
        auditStore.entries.filter { $0.level >= .warning }.count
    }

    var body: some View {
        ZStack {
            LiquidAmbientBackground(accent: Color(hex: "#38BDF8"))

            ScrollView {
                LazyVStack(spacing: 14) {
                    configCard
                    filterBar
                    logListSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("日志审计")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索站点、错误原因、事件...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    ShareLink(
                        item: auditStore.exportPlainText(),
                        preview: SharePreview("RelayPulse 审计日志.log")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(auditStore.entries.isEmpty)

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(auditStore.entries.isEmpty)
                }
            }
        }
        .alert("清空全部审计日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                auditStore.clearAll()
            }
        } message: {
            Text("将删除当前本地保存的 \(auditStore.entries.count) 条审计日志记录。")
        }
    }

    // MARK: - Config Card

    private var configCard: some View {
        @Bindable var bindableStore = auditStore

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("审计日志策略", systemImage: "doc.text.magnifyingglass")
                    .font(.headline.weight(.semibold))
                Spacer()
                Toggle("", isOn: $bindableStore.config.isEnabled)
                    .labelsHidden()
                    .tint(Color(hex: "#38BDF8"))
            }

            if auditStore.config.isEnabled {
                Divider().opacity(0.22)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("保留日志级别（记录此级别及以上）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(auditStore.config.minimumLevel.chineseTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(auditStore.config.minimumLevel.color)
                    }

                    Picker("日志级别", selection: $bindableStore.config.minimumLevel) {
                        ForEach(AuditLogLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("日志保留时间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("保留时间", selection: $bindableStore.config.retentionDays) {
                            ForEach(AuditLogRetention.allCases) { ret in
                                Text(ret.title).tag(ret)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color(hex: "#38BDF8"))
                    }
                }
            }

            Divider().opacity(0.22)

            HStack(spacing: 12) {
                Label("共 \(auditStore.entries.count) 条", systemImage: "list.bullet")
                if warningOrErrorCount > 0 {
                    Label("\(warningOrErrorCount) 条告警/错误", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(hex: "#F59E0B"))
                }
                Spacer()
                Button("立即清理过期") {
                    auditStore.pruneEntries()
                }
                .font(.caption2.weight(.semibold))
                .glassButtonStyle()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            AdaptiveGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    filterChip(title: "全部 (\(auditStore.entries.count))", level: nil, color: Color(hex: "#38BDF8"))
                    ForEach(AuditLogLevel.allCases.reversed()) { level in
                        let count = auditStore.entries.filter { $0.level == level }.count
                        filterChip(title: "\(level.title) (\(count))", level: level, color: level.color)
                    }
                }
            }
        }
    }

    private func filterChip(title: String, level: AuditLogLevel?, color: Color) -> some View {
        let active = filterLevel == level
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                filterLevel = level
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? color : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassPill(tint: active ? color.opacity(0.28) : nil, interactive: true)
    }

    // MARK: - Log List

    private var logListSection: some View {
        VStack(spacing: 10) {
            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(auditStore.entries.isEmpty ? "暂无审计日志" : "当前筛选条件下无匹配日志")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .liquidGlassCard(cornerRadius: 22)
            } else {
                ForEach(filteredEntries) { entry in
                    logRow(entry)
                }
            }
        }
    }

    private func logRow(_ entry: AuditLogEntry) -> some View {
        let expanded = expandedEntryIDs.contains(entry.id)

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                if expanded {
                    expandedEntryIDs.remove(entry.id)
                } else {
                    expandedEntryIDs.insert(entry.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: entry.level.iconName)
                        .font(.caption)
                        .foregroundStyle(entry.level.color)

                    Text(entry.level.title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(entry.level.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(entry.level.color.opacity(0.16), in: Capsule())

                    Text(entry.category.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                    if let station = entry.stationName, !station.isEmpty {
                        Text(station)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let ms = entry.durationMs {
                        Text(formatDuration(ms))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ms >= 29_000 ? Color(hex: "#F59E0B") : .secondary)
                            .monospacedDigit()
                    }
                }

                Text(entry.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }

                HStack {
                    Text(Self.timestampFormatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Spacer()
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(expanded ? "收起" : "展开详情")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
        return "\(ms)ms"
    }

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
}
