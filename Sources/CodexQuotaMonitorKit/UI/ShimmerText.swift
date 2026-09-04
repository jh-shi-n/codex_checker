import SwiftUI

/// Low-contrast activity text animation. Only working activity shimmers; all
/// other states, including Reduce Motion, remain ordinary static text.
public struct ShimmerText: View {
    public static let animationDuration: TimeInterval = 1.5

    public let text: String
    public let status: SessionActivityStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    public init(_ text: String, status: SessionActivityStatus = .unknown) {
        self.text = text
        self.status = status
    }

    public static func shouldAnimate(
        status: SessionActivityStatus,
        reduceMotion: Bool
    ) -> Bool {
        status == .working && !reduceMotion
    }

    public var body: some View {
        let animate = Self.shouldAnimate(status: status, reduceMotion: reduceMotion)

        Group {
            if animate {
                Text(text)
                    .overlay {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.42),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: phase * proxy.size.width)
                            .mask(Text(text))
                        }
                    }
                    .onAppear(perform: startAnimation)
                    .onChange(of: reduceMotion) { _, isReduced in
                        if isReduced {
                            phase = -1
                        } else {
                            startAnimation()
                        }
                    }
            } else {
                Text(text)
            }
        }
    }

    private func startAnimation() {
        phase = -1
        withAnimation(
            .linear(duration: Self.animationDuration)
                .repeatForever(autoreverses: false)
        ) {
            phase = 1
        }
    }
}
