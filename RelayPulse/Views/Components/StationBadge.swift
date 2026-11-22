import SwiftUI

struct ProviderBadge: View {
    let provider: RelayProviderType

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: provider.iconName)
                .font(.caption2.weight(.bold))
            Text(provider.displayName)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(provider.badgeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(provider.badgeColor.opacity(0.14), in: Capsule())
        .overlay(
            Capsule().strokeBorder(provider.badgeColor.opacity(0.32), lineWidth: 0.6)
        )
    }
}

struct ExchangeRatePill: View {
    let rate: Double
    let currency: DisplayCurrency
    var provider: RelayProviderType = .sub2api

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .bold))
            Text("\(provider.unitShortPrefix)=\(currency.symbol)\(ValueFormatter.rate(rate))")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

struct StatusDot: View {
    let isLoading: Bool
    let hasError: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.mini)
        } else {
            Circle()
                .fill(hasError ? Color.red : Color(hex: "#10B981"))
                .frame(width: 8, height: 8)
                .shadow(color: (hasError ? Color.red : Color(hex: "#10B981")).opacity(0.6), radius: 4)
        }
    }
}
