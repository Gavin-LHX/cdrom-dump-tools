import SwiftUI
import UIKit

struct CdromGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12),
                        .clear,
                        Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct CdromGlassEffectGroup<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

extension View {
    func cdromGlassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(CdromGlassSurfaceModifier(cornerRadius: cornerRadius))
    }

    func cdromGlassButton(prominent: Bool = false) -> some View {
        modifier(CdromGlassButtonModifier(prominent: prominent))
    }
}

private struct CdromGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.primary.opacity(colorSchemeContrast == .increased ? 0.42 : 0.20),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                    )
                }
        } else {
            content.glassEffect(
                .regular.tint(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10)),
                in: shape
            )
        }
    }
}

private struct CdromGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        } else if prominent {
            content.buttonStyle(GlassProminentButtonStyle())
        } else {
            content.buttonStyle(GlassButtonStyle())
        }
    }
}
