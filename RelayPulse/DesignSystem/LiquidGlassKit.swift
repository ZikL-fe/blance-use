import SwiftUI

// MARK: - Color Hex Helper

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 56, 189, 248)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Ambient Liquid Glass Canvas

/// Soft multi-stop MeshGradient backdrop that gives iOS 26 / iOS 27 Liquid Glass
/// surfaces vivid optical refraction and specular rim depth in both Light & Dark Mode.
struct LiquidAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color = Color(hex: "#38BDF8")

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.52, 0.45], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        Color(hex: "#050816"), Color(hex: "#0C1838"), Color(hex: "#151238"),
                        Color(hex: "#08142B"), accent.opacity(0.28), Color(hex: "#1E113A"),
                        Color(hex: "#050712"), Color(hex: "#0B1226"), Color(hex: "#0E0D24")
                    ]
                )
            } else {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.48, 0.42], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        Color(hex: "#EEF5FF"), Color(hex: "#E1EEFF"), Color(hex: "#EFE8FF"),
                        Color(hex: "#F4F8FF"), accent.opacity(0.18), Color(hex: "#F3E8FF"),
                        Color(hex: "#F8FAFC"), Color(hex: "#EFF4FF"), Color(hex: "#F5F3FF")
                    ]
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass Surface Modifiers (iOS 26 / iOS 27 Native)

struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color? = nil
    var interactive: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(resolvedGlass, in: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.24 : 0.65),
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.5), lineWidth: 0.8)
                        .allowsHitTesting(false)
                )
        }
    }

    @available(iOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

struct LiquidGlassPillModifier: ViewModifier {
    var tint: Color? = nil
    var interactive: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
        }
    }

    @available(iOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

extension View {
    func liquidGlassCard(
        cornerRadius: CGFloat = 24,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func liquidGlassPill(
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(LiquidGlassPillModifier(tint: tint, interactive: interactive))
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func adaptiveGlassEffectID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Container that batches nearby Liquid Glass shapes for native fluid morphing on iOS 26 / iOS 27.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Reusable Section Header

struct GlassSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailingText: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
    }
}
