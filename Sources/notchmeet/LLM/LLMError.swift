import Foundation

enum LLMError: Error, LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "bad URL"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

/// Throw on non-2xx so the TurnManager can surface a clean error / fall back.
func httpCheck(_ resp: URLResponse) throws {
    if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
        throw LLMError.http(h.statusCode)
    }
}
