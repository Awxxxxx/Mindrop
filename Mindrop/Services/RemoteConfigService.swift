import Foundation

struct RemoteAppConfig: Decodable {
    private let appReviewURL: String?
    private let features: RemoteFeatureFlags?

    var reviewURL: URL? {
        guard let appReviewURL,
              let url = URL.mindropReviewURL(from: appReviewURL) else {
            return nil
        }
        return url
    }

    var aiThinkingModeToggleEnabled: Bool? {
        features?.aiThinkingModeToggle
    }
}

private struct RemoteFeatureFlags: Decodable {
    let aiThinkingModeToggle: Bool?
}

enum RemoteConfigServiceError: Error {
    case endpointNotConfigured
    case invalidResponse
    case serverError(Int)
}

final class RemoteConfigService {
    static let shared = RemoteConfigService()

    private static let productionEndpoint = URL(string: "https://www.mindrop.chat/api/app-config")
    private static let stagingEndpoint = URL(string: "https://staging.mindrop.chat/api/app-config")

    private let endpoint: URL?
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        endpoint: URL? = RemoteConfigService.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func fetchAppConfig() async throws -> RemoteAppConfig {
        guard let endpoint else { throw RemoteConfigServiceError.endpointNotConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteConfigServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteConfigServiceError.serverError(httpResponse.statusCode)
        }

        return try decoder.decode(RemoteAppConfig.self, from: data)
    }

    private static var defaultEndpoint: URL? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MindropRemoteConfigEndpoint") as? String,
           let url = URL.mindropHTTPSURL(from: value) {
            return url
        }
        if let value = ProcessInfo.processInfo.environment["MINDROP_REMOTE_CONFIG_ENDPOINT"],
           let url = URL.mindropHTTPSURL(from: value) {
            return url
        }
#if DEBUG
        return stagingEndpoint
#else
        return productionEndpoint
#endif
    }
}

private extension URL {
    static func mindropHTTPSURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    static func mindropReviewURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https", "itms-apps"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }
}
