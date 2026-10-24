import Foundation

public enum MemoError: LocalizedError, Equatable {
    case invalidURL, invalidHeader, duplicate, capacity, invalidBackup
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP(S)、RTMP(S) 或 RTSP 地址"
        case .invalidHeader: return "请求头不能包含换行"
        case .duplicate: return "这个直播源已经在列表里了"
        case .capacity: return "最多保留 9 个直播源"
        case .invalidBackup: return "无法读取 Memo 直播源备份"
        }
    }
}

public struct Source: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var url: String = ""
    public var referer: String = ""
    public var cookie: String = ""
    public var agent: String = "Mozilla/5.0"
    public var qualityId: Int = 0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decode(String.self, forKey: .url)
        referer = try c.decodeIfPresent(String.self, forKey: .referer) ?? ""
        cookie = try c.decodeIfPresent(String.self, forKey: .cookie) ?? ""
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "Mozilla/5.0"
        qualityId = try c.decodeIfPresent(Int.self, forKey: .qualityId) ?? 0
    }
    public func validated() throws -> Source {
        var s = self
        s.url = try Link.extract(url)
        for h in [referer, cookie, agent] {
            if h.contains("\n") || h.contains("\r") { throw MemoError.invalidHeader }
        }
        s.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.name.isEmpty { s.name = "未命名直播" }
        return s
    }
    public var headers: [String: String] {
        var h: [String: String] = [:]
        if !referer.isEmpty { h["Referer"] = referer }
        if !cookie.isEmpty { h["Cookie"] = cookie }
        if !agent.isEmpty { h["User-Agent"] = agent }
        return h
    }
}

public enum Link {
    public static func extract(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try NSRegularExpression(pattern: #"(?i)(?:https?|rtmps?|rtsp)://[^\s<>\"“”]+"#)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { throw MemoError.invalidURL }
        let raw = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "，。；！）】》"))
        guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              ["http", "https", "rtmp", "rtmps", "rtsp"].contains(scheme),
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { throw MemoError.invalidURL }
        c.scheme = scheme
        guard let normalized = c.url?.absoluteString else { throw MemoError.invalidURL }
        return normalized
    }
    /// Classification does not resolve a platform URL or prove that it is playable.
    public static func platform(_ link: String) -> String {
        let h = URLComponents(string: link)?.host?.lowercased() ?? ""
        if h == "douyin.com" || h.hasSuffix(".douyin.com") { return "抖音分享（解析待移植）" }
        if h == "b23.tv" || h == "bilibili.com" || h.hasSuffix(".bilibili.com") { return "Bilibili 分享（解析待移植）" }
        return "媒体直链"
    }
}

public struct SourceBackup: Codable, Sendable {
    public var format = "MemoSources"
    public var version = 1
    public var sources: [Source]
    public init(sources: [Source]) { self.sources = sources }
    public static func decode(_ data: Data) throws -> SourceBackup {
        guard data.count <= 1_000_000,
              let backup = try? JSONDecoder().decode(SourceBackup.self, from: data),
              backup.format == "MemoSources", backup.version == 1,
              backup.sources.count <= 9 else { throw MemoError.invalidBackup }
        return backup
    }
}

public enum SourceList {
    public static func upsert(_ source: Source, into list: [Source]) throws -> [Source] {
        let source = try source.validated()
        if list.contains(where: { $0.id != source.id && $0.url == source.url }) { throw MemoError.duplicate }
        var list = list
        if let i = list.firstIndex(where: { $0.id == source.id }) { list[i] = source }
        else {
            guard list.count < 9 else { throw MemoError.capacity }
            list.append(source)
        }
        return list
    }
}
