import Foundation

public enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: "Компактное"
        case .standard: "Стандартное"
        case .high: "Высокое"
        }
    }

    public var detail: String {
        switch self {
        case .compact: "32 kHz · 32 kbps · около 2.4 MB за 10 минут"
        case .standard: "48 kHz · 64 kbps · около 4.8 MB за 10 минут"
        case .high: "48 kHz · 128 kbps · около 9.6 MB за 10 минут"
        }
    }

    public var sampleRate: Int {
        switch self {
        case .compact: 32_000
        case .standard, .high: 48_000
        }
    }

    public var bitRate: Int {
        switch self {
        case .compact: 32_000
        case .standard: 64_000
        case .high: 128_000
        }
    }
}
