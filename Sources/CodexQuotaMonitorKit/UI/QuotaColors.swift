import Foundation
import SwiftUI

/// The semantic state of a remaining quota percentage.
public enum QuotaLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case normal
    case attention
    case low
    case critical
}

/// A platform-independent RGB token. Keeping the token separate from SwiftUI's
/// `Color` makes quota presentation rules deterministic and easy to test.
public struct QuotaRGB: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

public enum QuotaAppearance: String, CaseIterable, Sendable {
    case dark
    case light
}

/// Centralized design tokens and pure classification helpers for the donut UI.
public enum QuotaColors {
    public static let normal = QuotaRGB(red: 0x30, green: 0xD1, blue: 0x58)
    public static let attention = QuotaRGB(red: 0xFF, green: 0xB8, blue: 0x00)
    public static let low = QuotaRGB(red: 0xFF, green: 0x5E, blue: 0x57)
    public static let critical = QuotaRGB(red: 0xFF, green: 0x3B, blue: 0x30)
    public static let darkTrack = QuotaRGB(red: 0x2C, green: 0x2C, blue: 0x2E)
    public static let lightTrack = QuotaRGB(red: 0xE5, green: 0xE5, blue: 0xEA)

    public static func clampedPercent(_ remainingPercent: Double) -> Double {
        guard remainingPercent.isFinite else { return 0 }
        return min(100, max(0, remainingPercent))
    }

    public static func level(for remainingPercent: Double) -> QuotaLevel {
        let remaining = clampedPercent(remainingPercent)
        switch remaining {
        case 60...:
            return .normal
        case 30..<60:
            return .attention
        case 10..<30:
            return .low
        default:
            return .critical
        }
    }

    public static func color(for remainingPercent: Double) -> QuotaRGB {
        switch level(for: remainingPercent) {
        case .normal:
            return normal
        case .attention:
            return attention
        case .low:
            return low
        case .critical:
            return critical
        }
    }

    public static func swiftUIColor(for remainingPercent: Double) -> Color {
        color(for: remainingPercent).swiftUIColor
    }

    public static func trackColor(for appearance: QuotaAppearance) -> QuotaRGB {
        switch appearance {
        case .dark:
            return darkTrack
        case .light:
            return lightTrack
        }
    }

    public static func swiftUITrackColor(for appearance: QuotaAppearance) -> Color {
        trackColor(for: appearance).swiftUIColor
    }
}
