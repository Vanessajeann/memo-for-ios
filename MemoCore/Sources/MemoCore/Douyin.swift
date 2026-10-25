import Foundation

public enum Douyin {
    public static func page(_ data: Data, expected: String) throws -> WorkPage {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? JObject else { throw PlatformError("作品数据格式已变化") }
        guard raw.n("status_code") == 0 else { throw PlatformError("请在官方网页完成登录或验证后重试") }
        let root = raw["aweme_list"] == nil ? raw.o("data") : raw
        guard let list = root["aweme_list"] as? [JObject] else { throw PlatformError("未收到主页作品列表，请打开官方网页重试") }
        var p = WorkPage(); p.known = root["has_more"] != nil; p.hasMore = root.flag("has_more"); p.cursor = root.s("max_cursor")
        var seen = Set<String>()
        for node in list {
            guard let w = work(node), w.secID.isEmpty || w.secID == expected, seen.insert(w.id).inserted else { continue }
            p.works.append(w)
        }
        if !list.isEmpty && p.works.isEmpty { throw PlatformError("列表不属于当前博主，已忽略") }
        return p
    }
    public static func embedded(_ data: Data, expected: String) throws -> WorkPage {
        let root = try JSONSerialization.jsonObject(with: data)
        var page = WorkPage(), seen = Set<String>(), visited = 0
        func visit(_ node: Any, _ depth: Int) {
            visited += 1; guard depth <= 16, visited <= 40_000 else { return }
            if let o = node as? JObject {
                if let w = work(o) {
                    if w.secID == expected, seen.insert(w.id).inserted { page.works.append(w) }
                    return
                }
                for v in o.values { visit(v, depth + 1) }
            } else if let a = node as? [Any] { for v in a { visit(v, depth + 1) } }
        }
        visit(root, 0); return page
    }
    private static func candidate(_ node: JObject, rate: JObject? = nil, video: JObject = [:]) -> Media? {
        guard !node.encrypted else { return nil }
        var m = Media()
        m.urls = (node["url_list"] as? [String] ?? []).filter { MediaURL.original($0, platform: .douyin) }
        m.width = node.n("width"); m.height = node.n("height")
        if rate == nil { if m.width == 0 { m.width = video.n("width") }; if m.height == 0 { m.height = video.n("height") } }
        if m.width < 0 || m.width > 16384 { m.width = 0 }; if m.height < 0 || m.height > 16384 { m.height = 0 }
        m.bitrate = rate?.i("bit_rate") ?? node.i("bit_rate")
        if m.bitrate < 0 || m.bitrate > 2_000_000_000 { m.bitrate = 0 }
        m.codec = rate?.n("is_bytevc1") == 1 ? "HEVC" : ""
        return m.urls.isEmpty ? nil : m
    }
    public static func work(_ o: [String: Any]) -> Work? {
        let id = o.s("aweme_id")
        guard !MediaURL.match(#"^([0-9]{10,24})$"#, id).isEmpty else { return nil }
        var w = Work(); w.id = id; w.title = String(o.s("desc").prefix(2000)); w.created = o.i("create_time")
        let author = o.o("author"); w.author = author.s("nickname"); w.secID = author.s("sec_uid")
        let video = o.o("video"), images = o.a("images"); w.album = !images.isEmpty
        for key in ["origin_cover", "cover", "dynamic_cover"] {
            if let url = (video.o(key)["url_list"] as? [String])?.first, MediaURL.allowed(url, platform: .douyin) { w.cover = url; break }
        }
        if !video.encrypted && !w.album {
            w.media = candidate(video.o("play_addr"), video: video)
            for rate in video.a("bit_rate") where !rate.encrypted {
                if let m = candidate(rate.o("play_addr"), rate: rate, video: video), m.better(than: w.media) { w.media = m }
            }
        }
        for image in images {
            if image.encrypted { w.images.append(Media()); continue }
            var m = candidate(image, video: image)
            for key in ["origin_image", "origin_image_url", "original_image"] {
                if let original = candidate(image.o(key)), m == nil || original.width * original.height >= m!.width * m!.height { m = original }
            }
            w.images.append(m ?? Media())
        }
        if w.cover.isEmpty { w.cover = w.images.first?.urls.first ?? "" }
        return w
    }
    public static func roomID(_ text: String) -> String {
        let path = MediaURL.match(#"(?:reflow/|room/|[?&]room_id=)([0-9]{15,22})"#, text)
        if !path.isEmpty { return path }
        return MediaURL.match(#""(?:roomId|room_id|room_id_str)"\s*:\s*"?([0-9]{15,22})"#, text.replacingOccurrences(of: #"\""#, with: "\""))
    }
    public static func live(_ data: Data, roomID: String) throws -> LiveResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? JObject, root.n("status_code") == 0 else { throw PlatformError("抖音要求验证，请打开官方网页后重试") }
        let room = root.o("data").o("room")
        guard room.n("status") == 2 else { throw PlatformError(room.n("status") == 4 ? "这场直播已经结束" : "当前未开播或平台未开放此直播") }
        let stream = room.o("stream_url")
        var candidates: [LiveStream] = []
        func add(_ raw: String, _ proto: String, _ tier: String, _ params: JObject = [:]) {
            guard tier != "ao", let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil, url.host != nil else { return }
            let canonical = ["origion":"origin", "full_hd1":"uhd", "hd1":"hd", "sd2":"sd", "sd1":"ld"][tier] ?? tier
            let ranks = ["origin":600, "uhd":500, "hd":400, "sd":300, "ld":200, "md":100]
            var value = LiveStream(url: raw, protocolName: proto, qualityID: ranks[canonical] ?? 0, label: ["origin":"原画", "uhd":"超清", "hd":"高清", "sd":"标清", "ld":"流畅", "md":"极速"][canonical] ?? "未标注")
            let dimensions = params.s("resolution").lowercased().split(separator: "x").compactMap { Int($0) }
            if dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 && $0 <= 16384 }) { value.width = dimensions[0]; value.height = dimensions[1] }
            value.bitrate = max(0, min(1_000_000_000, params.i("vbitrate") > 0 ? params.i("vbitrate") : params.i("v_bit_rate")))
            value.fps = max(0, min(240, Double(params.s("fps")) ?? 0)); candidates.append(value)
        }
        for (key, value) in stream.o("hls_pull_url_map") { add(value as? String ?? "", "HLS", key) }
        for (key, value) in stream.o("flv_pull_url") { add(value as? String ?? "", "FLV", key) }
        add(stream.s("hls_pull_url"), "HLS", ""); add(stream.s("rtmp_pull_url"), "FLV", "")
        let pull = stream.o("live_core_sdk_data").o("pull_data")
        func object(_ value: Any?) -> JObject {
            if let o = value as? JObject { return o }
            if let s = value as? String, let d = s.data(using: .utf8) { return (try? JSONSerialization.jsonObject(with: d)) as? JObject ?? [:] }
            return [:]
        }
        let sdk = object(pull["stream_data"]).o("data")
        for (key, value) in sdk {
            let main = (value as? JObject ?? [:]).o("main")
            let q = pull.o("options").a("qualities").first { $0.s("sdk_key") == key } ?? [:]
            guard !main.encrypted, !q.flag("disable") else { continue }
            let params = q.merging(object(main["sdk_params"])) { _, new in new }
            add(main.s("hls"), "HLS", key, params); add(main.s("flv"), "FLV", key, params)
        }
        candidates.sort { $0.better(than: $1) }
        guard !candidates.isEmpty else { throw PlatformError("平台未返回公开直播流") }
        return LiveResult(name: room.o("owner").s("nickname"), title: room.s("title"), streams: candidates)
    }
}
public struct LiveStream: Equatable, Sendable, Identifiable {
    public var url: String, protocolName: String
    public var qualityID: Int, label: String
    public var width = 0, height = 0
    public var bitrate: Int64 = 0
    public var fps: Double = 0
    public var id: String { url }
    public init(url: String, protocolName: String, qualityID: Int, label: String) { self.url = url; self.protocolName = protocolName; self.qualityID = qualityID; self.label = label }
    public func better(than b: LiveStream) -> Bool {
        if qualityID != b.qualityID { return qualityID > b.qualityID }
        if width * height != b.width * b.height { return width * height > b.width * b.height }
        if bitrate != b.bitrate { return bitrate > b.bitrate }; if fps != b.fps { return fps > b.fps }
        if protocolName != b.protocolName { return protocolName == "HLS" }; return url < b.url
    }
}
public struct LiveResult: Sendable {
    public var name: String, title: String, streams: [LiveStream]
    public init(name: String, title: String, streams: [LiveStream]) { self.name = name; self.title = title; self.streams = streams }
    public var best: LiveStream? { streams.first }
    public var preview: LiveStream? { streams.filter { $0.protocolName == "HLS" }.last }
}
