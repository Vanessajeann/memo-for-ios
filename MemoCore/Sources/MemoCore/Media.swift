import Foundation

public struct PlatformError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Platform: String, Codable, CaseIterable, Sendable {
    case douyin, bilibili
    public var label: String { self == .douyin ? "抖音" : "Bilibili" }
    public var home: String { self == .douyin ? "https://www.douyin.com/" : "https://www.bilibili.com/" }
    public func official(_ host: String) -> Bool {
        self == .douyin ? ["douyin.com", "iesdouyin.com", "amemv.com"].contains { MediaURL.domain(host, $0) } : (MediaURL.domain(host, "bilibili.com") || host.lowercased() == "b23.tv")
    }
}
public enum MediaURL {
    public static func domain(_ host: String, _ root: String) -> Bool { host.lowercased() == root || host.lowercased().hasSuffix("." + root) }
    public static func https(_ text: String) -> String {
        if text.hasPrefix("//") { return "https:" + text }
        if text.hasPrefix("http://") { return "https://" + text.dropFirst(7) }
        return text
    }
    public static func allowed(_ text: String, platform: Platform) -> Bool {
        guard let c = URLComponents(string: text), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let h = c.host else { return false }
        let roots = platform == .bilibili ? ["bilivideo.com", "bilivideo.cn", "hdslb.com"] : ["douyin.com", "iesdouyin.com", "amemv.com", "douyinvod.com", "douyinpic.com", "byteimg.com", "bytecdn.cn", "ibytedtos.com", "byteoversea.com", "snssdk.com"]
        return roots.contains { domain(h, $0) }
    }
    public static func original(_ text: String, platform: Platform) -> Bool {
        guard allowed(text, platform: platform) else { return false }
        let s = text.lowercased()
        if ["playwm", "tplv-dy-watermark", "owner_watermark"].contains(where: s.contains) { return false }
        return !(URLComponents(string: text)?.queryItems ?? []).contains { ["watermark", "is_watermark", "watermark_type"].contains($0.name) && $0.value == "1" }
    }
    public static func match(_ expression: String, _ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: expression), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return "" }
        return String(text[r])
    }
    public static func query(_ text: String, _ key: String) -> String { URLComponents(string: text)?.queryItems?.first { $0.name == key }?.value ?? "" }
    public static func secID(_ text: String) -> String {
        guard let u = URL(string: text), Platform.douyin.official(u.host ?? "") else { return "" }
        let path = match(#"/(?:share/)?user/(MS4[A-Za-z0-9_-]{9,253})(?:/|$)"#, u.path)
        let value = path.isEmpty ? query(text, "sec_uid") : path
        return match(#"^(MS4[A-Za-z0-9_-]{9,253})$"#, value)
    }
}
public struct Media: Codable, Equatable, Sendable {
    public var urls: [String] = []
    public var width = 0, height = 0
    public var bitrate: Int64 = 0
    public var codec = ""
    public init() {}
    public var quality: String {
        (width > 0 && height > 0 ? "\(width)×\(height)" : "原文件") + (bitrate > 0 ? String(format: " · %.2f Mbps", Double(bitrate) / 1_000_000) : "")
    }
    public func better(than other: Media?) -> Bool {
        guard let o = other else { return true }
        if width * height != o.width * o.height { return width * height > o.width * o.height }
        if bitrate != o.bitrate { return bitrate > o.bitrate }
        return (urls.first ?? "") < (o.urls.first ?? "")
    }
}
public struct Work: Codable, Equatable, Identifiable, Sendable {
    public var id = "", title = "", author = "", secID = "", cover = "", bvid = ""
    public var platform: Platform = .douyin
    public var cid: Int64 = 0, created: Int64 = 0
    public var qualityID = 0
    public var qualityLabel = ""
    public var media: Media?, audio: Media?
    public var images: [Media] = []
    public var album = false
    public init() {}
    public var downloadable: Bool { album ? !images.isEmpty && images.allSatisfy { !$0.urls.isEmpty } : media?.urls.isEmpty == false }
    public var key: String { id + (qualityID > 0 ? "_q\(qualityID)" : "") }
    public var filename: String {
        let clean = (author + "_" + title).unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "\\/:*?\"<>|".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        return "作品_" + String(clean.prefix(55)) + "_" + key + ".mp4"
    }
}
public struct WorkPage: Sendable {
    public var works: [Work] = []
    public var hasMore = false, known = false
    public var cursor = ""
    public init() {}
}
// JSON helpers intentionally accept numeric strings used by both platforms.
typealias JObject = [String: Any]
extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { if let s = self[k] as? String { return s }; return (self[k] as? NSNumber)?.stringValue ?? "" }
    func n(_ k: String) -> Int { Int(s(k)) ?? 0 }
    func i(_ k: String) -> Int64 { Int64(s(k)) ?? 0 }
    func flag(_ k: String) -> Bool { (self[k] as? Bool) == true || n(k) == 1 || s(k) == "true" }
    func o(_ k: String) -> JObject { self[k] as? JObject ?? [:] }
    func a(_ k: String) -> [JObject] { self[k] as? [JObject] ?? [] }
    var encrypted: Bool { ["is_drm", "is_encrypt", "enableEncryption"].contains { flag($0) } }
}
