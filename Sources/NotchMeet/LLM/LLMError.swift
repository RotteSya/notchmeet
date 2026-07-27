import Foundation

enum LLMError: Error, LocalizedError {
    case badURL
    case missingKey
    case http(Int)

    /// 面试进行中的错误文案必须可行动。「HTTP 429」对着刘海念不出任何下一步，
    /// 而这几个状态码恰好对应完全不同的处置：等一下、换 Key、还是别等了。
    var errorDescription: String? {
        switch self {
        case .badURL: return "bad URL"
        case .missingKey: return AppStrings.current.llmErrorMissingKey
        case .http(let code):
            switch code {
            case 401, 403: return AppStrings.current.llmErrorAuth(code)
            case 429:      return AppStrings.current.llmErrorRateLimited(code)
            case 500...599: return AppStrings.current.llmErrorServer(code)
            default:       return AppStrings.current.llmErrorGeneric(code)
            }
        }
    }
}

/// Throw on non-2xx so the TurnManager can surface a clean error / fall back.
func httpCheck(_ resp: URLResponse) throws {
    if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
        throw LLMError.http(h.statusCode)
    }
}
