/// Presence of the app's saved API key. Checking never needs the key's value.
/// A failed lookup must remain distinct from a confirmed missing item.
public enum APIKeyStatus: Equatable, Sendable {
    case checking
    case available
    case missing
    case unavailable

    public static func checkPresence(using lookup: () throws -> Bool) -> Self {
        do { return try lookup() ? .available : .missing }
        catch { return .unavailable }
    }

    public var hasSavedKey: Bool { self == .available }

    public var statusText: String {
        switch self {
        case .checking: "Проверка API key в Keychain…"
        case .available: "API key сохранён в Keychain"
        case .missing: "API key не добавлен"
        case .unavailable: "Не удалось проверить API key в Keychain"
        }
    }

    public var authorizationRequiredMessage: String? {
        switch self {
        case .available: nil
        case .missing: "Добавьте OpenAI API key"
        case .checking, .unavailable: statusText
        }
    }
}
