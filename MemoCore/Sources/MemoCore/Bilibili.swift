import Foundation

public struct BiliQuality: Identifiable, Sendable {
    public var id: Int
    public var label: String, reason: String
    public var video: Media?, audio: Media?
    public var available: Bool { video?.urls.isEmpty == false }
}
public enum Bilibili {
    public static func link(_ input: String) throws -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !MediaURL.match(#"^(BV[0-9A-Za-z]{10}|av[0-9]{1,20})$"#, s).isEmpty { return Platform.bilibili.home + "video/" + s }
        let value = MediaURL.https(try Link.extract(s))
        guard let c = URLComponents(string: value), c.scheme == "https", Platform.bilibili.official(c.host ?? ""), c.port == nil || c.port == 443 else { throw PlatformError("请输入 Bilibili 视频、UP 主页或直播间分享链接") }
        return value
    }
    public static func videoID(_ url: String) -> String { MediaURL.match(#"/(?:video/)?(BV[0-9A-Za-z]{10}|av[0-9]{1,20})(?:/|$)"#, URL(string: url)?.path ?? "") }
    public static func userID(_ url: String) -> String { URL(string: url)?.host == "space.bilibili.com" ? MediaURL.match(#"^/([0-9]{1,20})(?:/|$)"#, URL(string: url)?.path ?? "") : "" }
    public static func liveID(_ url: String) -> String { URL(string: url)?.host == "live.bilibili.com" ? MediaURL.match(#"^/(?:blanc/)?([0-9]{1,20})(?:/|$)"#, URL(string: url)?.path ?? "") : "" }
    public static func data(_ bytes: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? JObject else { throw PlatformError("Bilibili 数据格式已变化") }
        guard root.n("code") == 0 else {
            let code = root.n("code")
            throw PlatformError(code == -101 ? "请先登录 Bilibili 账号" : [-352,-412].contains(code) ? "平台要求验证或限制请求，请打开官方网页后重试" : "平台未开放此内容（代码 \(code)）")
        }
        guard let data = root["data"] as? JObject else { throw PlatformError("平台未返回内容数据") }; return data
    }
    public static func parts(_ data: [String: Any]) -> [Work] {
        let bv = data.s("bvid")
        guard !MediaURL.match(#"^(BV[0-9A-Za-z]{10})$"#, bv).isEmpty else { return [] }
        let pages = data.a("pages")
        return pages.compactMap { page in
            guard page.i("cid") > 0 else { return nil }
            var w = Work(); w.platform = .bilibili; w.bvid = bv; w.cid = page.i("cid"); w.id = "bili_\(bv)_\(w.cid)"
            w.title = data.s("title") + (pages.count > 1 ? " · P\(page.n("page")) \(page.s("part"))" : "")
            w.author = data.o("owner").s("name"); w.created = data.i("pubdate"); w.cover = MediaURL.https(data.s("pic")); return w
        }
    }
    private static func track(_ node: JObject) -> Media? {
        guard !node.encrypted else { return nil }
        var m = Media()
        for k in ["baseUrl", "base_url", "url"] { let u = MediaURL.https(node.s(k)); if MediaURL.allowed(u, platform: .bilibili), !m.urls.contains(u) { m.urls.append(u) } }
        for k in ["backupUrl", "backup_url"] { for raw in node[k] as? [String] ?? [] { let u = MediaURL.https(raw); if MediaURL.allowed(u, platform: .bilibili), !m.urls.contains(u) { m.urls.append(u) } } }
        m.width = max(0, min(16384, node.n("width"))); m.height = max(0, min(16384, node.n("height"))); m.bitrate = max(0, node.i("bandwidth")); m.codec = node.s("codecs")
        return m.urls.isEmpty ? nil : m
    }
    private static func codecScore(_ m: Media) -> Int { m.codec.hasPrefix("avc") ? 3 : (m.codec.hasPrefix("hev") || m.codec.hasPrefix("hvc") ? 2 : 1) }
    public static func playback(_ data: [String: Any]) -> [BiliQuality] {
        var map: [Int: BiliQuality] = [:]
        for f in data.a("support_formats") {
            let id = f.n("quality")
            map[id] = BiliQuality(id: id, label: f.s("new_description").isEmpty ? "档位 \(id)" : f.s("new_description"), reason: f.flag("need_vip") ? "需要大会员或内容权限" : f.flag("need_login") ? "需要登录" : "当前会话未开放／需要其他权限")
        }
        let ids = data["accept_quality"] as? [Int] ?? [], names = data["accept_description"] as? [String] ?? []
        for (index,id) in ids.enumerated() where map[id] == nil { map[id] = BiliQuality(id: id, label: index < names.count ? names[index] : "档位 \(id)", reason: "当前会话未开放／需要其他权限") }
        let dash = data.o("dash")
        let audio = dash.a("audio").compactMap { track($0) }.max { $0.bitrate < $1.bitrate }
        for v in dash.a("video") {
            let id = v.n("id")
            var q = map[id] ?? BiliQuality(id: id, label: "档位 \(id)", reason: "当前会话未开放")
            if let m = track(v), q.video == nil || codecScore(m) > codecScore(q.video!) || (codecScore(m) == codecScore(q.video!) && m.bitrate > q.video!.bitrate) { q.video = m; q.audio = audio }
            map[id] = q
        }
        let durl = data.a("durl")
        if dash.isEmpty, durl.count == 1 {
            let id = data.n("quality"); var q = map[id] ?? BiliQuality(id: id, label: "档位 \(id)", reason: "当前会话未开放")
            q.video = track(durl[0]); map[id] = q
        }
        let preview = data.flag("is_preview") || data.flag("is_drm") || data.flag("is_drm_video") || data.n("drm_tech_type") > 0
        return map.values.map { original in
            var q = original
            if preview { q.video = nil; q.reason = "试看或加密内容，未提供完整可保存媒体" }
            else if !dash.isEmpty, q.video != nil, q.audio == nil { q.video = nil; q.reason = "未返回兼容音轨，暂不可保存" }
            else if dash.isEmpty, durl.count > 1 || data.s("format").contains("flv") { q.video = nil; q.reason = "此媒体分段／格式暂不支持" }
            return q
        }.sorted { $0.id > $1.id }
    }
    public static func select(_ work: Work, quality: BiliQuality) throws -> Work {
        guard quality.available else { throw PlatformError(quality.reason) }
        var w = work; w.qualityID = quality.id; w.qualityLabel = quality.label; w.media = quality.video; w.audio = quality.audio; return w
    }
    public static func live(_ data: [String: Any]) throws -> LiveResult {
        guard data.n("live_status") == 1 else { throw PlatformError("直播间尚未开播") }
        let play = data.o("playurl_info").o("playurl")
        var labels: [Int: String] = [:], values: [LiveStream] = []
        for q in play.a("g_qn_desc") { labels[q.n("qn")] = q.s("desc") }
        for s in play.a("stream") { for f in s.a("format") { for c in f.a("codec") {
            guard !c.encrypted else { continue }
            for u in c.a("url_info") {
                let url = MediaURL.https(u.s("host") + c.s("base_url") + u.s("extra"))
                guard MediaURL.allowed(url, platform: .bilibili) else { continue }
                let q = c.n("current_qn")
                let proto = s.s("protocol_name") == "http_hls" ? "HLS" : "FLV"
                values.append(LiveStream(url: url, protocolName: proto, qualityID: q, label: labels[q] ?? "档位 \(q)"))
            }
        } } }
        guard !values.isEmpty else { throw PlatformError("当前会话未返回可用直播地址") }
        values.sort { $0.better(than: $1) }
        return LiveResult(name: "Bilibili 直播", title: data.s("room_id"), streams: values)
    }
}
