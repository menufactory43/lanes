import Foundation

/// Recherche de dépôts sur GitHub, sans compte (10 requêtes par minute).
public struct GitHubRepo: Sendable, Identifiable, Hashable {
    public var id: String { fullName }
    public let fullName: String
    public let description: String
    public let stars: Int
    public let language: String?
    public let cloneURL: String
    public let pushedAt: String?
}

public enum GitHubSearch {
    public static func search(_ query: String) async throws -> [GitHubRepo] {
        var c = URLComponents(string: "https://api.github.com/search/repositories")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "per_page", value: "8"), .init(name: "sort", value: "stars")]
        var req = URLRequest(url: c.url!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        req.setValue("Lanes/\(version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
            throw NSError(domain: "GitHubSearch", code: 403, userInfo: [NSLocalizedDescriptionKey: String(localized: "GitHub rate limit reached, try again in a minute")])
        }
        struct Response: Decodable { let items: [Item] }
        struct Item: Decodable {
            let full_name: String; let description: String?; let stargazers_count: Int
            let language: String?; let clone_url: String; let pushed_at: String?
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        return r.items.map { GitHubRepo(fullName: $0.full_name, description: $0.description ?? "", stars: $0.stargazers_count,
                                        language: $0.language, cloneURL: $0.clone_url, pushedAt: $0.pushed_at) }
    }
}
