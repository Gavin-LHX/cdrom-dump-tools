import SwiftUI
import AppKit

struct CdromGlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.09),
                        Color.clear,
                        Color.accentColor.opacity(colorScheme == .dark ? 0.06 : 0.035),
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

extension View {
    func cdromGlassSurface(cornerRadius: CGFloat = 18) -> some View {
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
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            nativeGlass(content)
        } else {
            materialFallback(content)
        }
#else
        materialFallback(content)
#endif
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        content.glassEffect(
            .regular.tint(Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.08)),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
#endif

    @ViewBuilder
    private func materialFallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.primary.opacity(colorSchemeContrast == .increased ? 0.42 : 0.22),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                    )
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.13 : 0.48),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.75
                    )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10),
                    radius: 14,
                    y: 5
                )
        }
    }
}

private struct CdromGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(GlassProminentButtonStyle())
            } else {
                content.buttonStyle(GlassButtonStyle())
            }
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
