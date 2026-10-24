import SwiftUI
import AVKit
import Network
import MemoCore

/// Loopback HLS relay: uses supported AVPlayer APIs, scoped cookies and platform Referer.
/// The random capability path maps only URLs found in the selected HLS playlist.
@MainActor
final class HLSRelay {
    private var listener: NWListener?
    private var urls: [String:URL] = [:]
    private let secret = UUID().uuidString
    private let source: Source
    private let session: URLSession
    private var pending: [UUID:Task<Void,Never>] = [:]
    private var connections: [UUID:NWConnection] = [:]
    private var port: UInt16 = 0
    init(source: Source) {
        self.source = source
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 20
        session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }
    func start() async throws -> URL {
        guard let initial = URL(string: source.url) else { throw MemoError.invalidURL }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters); listener = server
        server.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
            var resumed = false
            server.stateUpdateHandler = { state in Task { @MainActor in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; server.stateUpdateHandler = nil; self.port = server.port?.rawValue ?? 0; c.resume()
                case .failed(let error): resumed = true; server.stateUpdateHandler = nil; c.resume(throwing: error)
                case .cancelled: resumed = true; server.stateUpdateHandler = nil; c.resume(throwing: CancellationError())
                default: break
                }
            } }
            server.start(queue: .main)
        }
        try Task.checkCancellation()
        return register(initial)
    }
    func stop() { listener?.cancel(); listener = nil; for t in pending.values { t.cancel() }; pending = [:]; for c in connections.values { c.cancel() }; connections = [:]; session.invalidateAndCancel() }
    private func register(_ url: URL) -> URL {
        if let pair = urls.first(where: { $0.value == url }) { return local(pair.key) }
        let id = UUID().uuidString; urls[id] = url; return local(id)
    }
    private func local(_ id: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(secret)/\(id)")! }
    private func receive(_ connection: NWConnection) {
        let id = UUID(); connections[id] = connection; connection.start(queue: .main)
        read(connection, id: id, accumulated: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data,_,complete,error in Task { @MainActor in
            guard let self else { connection.cancel(); return }
            var all = accumulated; if let data { all.append(data) }
            guard all.count <= 16_384, error == nil else { self.finish(connection,id:id); return }
            guard let text = String(data: all, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { self.finish(connection,id:id) } else { self.read(connection,id:id,accumulated:all) }; return
            }
            self.pending[id] = Task {
                defer { self.pending.removeValue(forKey:id) }
                do { try await self.respond(text, connection:connection,id:id) }
                catch { self.send(connection,id:id,status:502,type:"text/plain",body:Data("Media unavailable".utf8),extra:[:]) }
            }
        } }
    }
    private func finish(_ connection:NWConnection,id:UUID) { connection.cancel(); connections.removeValue(forKey:id) }
    private func respond(_ request:String,connection:NWConnection,id:UUID) async throws {
        let lines = request.components(separatedBy:"\r\n"), head = lines[0].split(separator:" ")
        guard head.count >= 2, head[0] == "GET" || head[0] == "HEAD" else { throw MemoError.invalidURL }
        let parts = head[1].split(separator:"/")
        guard parts.count == 2, parts[0] == Substring(secret), let input = urls[String(parts[1])] else { throw MemoError.invalidURL }
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") { range = String(line.dropFirst(6)).trimmingCharacters(in:.whitespaces) }
        var current = input
        for _ in 0..<7 {
            guard ["http","https"].contains(current.scheme ?? ""), current.host != nil, current.user == nil, current.password == nil else { throw MemoError.invalidURL }
            var r = URLRequest(url:current); r.setValue(source.agent,forHTTPHeaderField:"User-Agent"); r.setValue(source.referer,forHTTPHeaderField:"Referer")
            if let range { r.setValue(range,forHTTPHeaderField:"Range") }
            if current.host == URL(string:source.url)?.host, current.scheme == URL(string:source.url)?.scheme, !source.cookie.isEmpty { r.setValue(source.cookie,forHTTPHeaderField:"Cookie") }
            let (data,response) = try await session.data(for:r)
            guard let http = response as? HTTPURLResponse, data.count <= 64_000_000 else { throw PlatformError("预览片段过大") }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField:"Location"), let next = URL(string:location,relativeTo:current)?.absoluteURL { current = next; continue }
            guard http.statusCode == 200 || http.statusCode == 206 else { throw PlatformError("预览请求失败") }
            var body = data, type = http.mimeType ?? "application/octet-stream", extra: [String:String] = [:]
            if let text = String(data:data,encoding:.utf8), text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                let rewritten = text.components(separatedBy:.newlines).map { line -> String in
                    if line.hasPrefix("#") {
                        guard let regex = try? NSRegularExpression(pattern:#"URI="([^"]+)""#) else { return line }
                        var result = line
                        for m in regex.matches(in:line,range:NSRange(line.startIndex...,in:line)).reversed() {
                            if let r = Range(m.range(at:1),in:line), let full = URL(string:String(line[r]),relativeTo:current)?.absoluteURL, let replace = Range(m.range(at:1),in:result) { result.replaceSubrange(replace,with:register(full).absoluteString) }
                        }
                        return result
                    }
                    let raw = line.trimmingCharacters(in:.whitespaces)
                    guard !raw.isEmpty, let full = URL(string:raw,relativeTo:current)?.absoluteURL else { return line }
                    return register(full).absoluteString
                }.joined(separator:"\n")
                body = Data(rewritten.utf8); type = "application/vnd.apple.mpegurl"
            } else {
                for key in ["Content-Range","Accept-Ranges"] { if let value = http.value(forHTTPHeaderField:key) { extra[key] = value } }
            }
            send(connection,id:id,status:http.statusCode,type:type,body:head[0] == "HEAD" ? Data() : body,extra:extra); return
        }
        throw PlatformError("预览跳转过多")
    }
    private func send(_ connection:NWConnection,id:UUID,status:Int,type:String,body:Data,extra:[String:String]) {
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k,v) in extra where !v.contains("\r") && !v.contains("\n") { h += "\(k): \(v)\r\n" }
        h += "\r\n"; var data = Data(h.utf8); data.append(body)
        connection.send(content:data,completion:.contentProcessed { [weak self] _ in Task { @MainActor in self?.finish(connection,id:id) } })
    }
}
@MainActor
final class StreamSession: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error = ""
    @Published var label = "连接中"
    @Published var resolved: Source?
    private var relay: HLSRelay?, token = UUID()
    private var observation: NSKeyValueObservation?
    func open(_ source:Source, muted:Bool = true) async {
        stop(); let generation = token; error = ""; label = "正在取源"
        do {
            let result = try await PlatformClient.shared.live(source)
            try Task.checkCancellation(); guard generation == token else { return }
            guard let preview = result.preview else { throw PlatformError("此协议可录制，当前预览需要 HLS 媒体") }
            resolved = preview
            let bridge = HLSRelay(source:preview); relay = bridge
            let url = try await bridge.start(); try Task.checkCancellation(); guard generation == token else { bridge.stop(); return }
            let p = AVPlayer(url:url); p.isMuted = muted
            observation = p.currentItem?.observe(\.status,options:[.new]) { [weak self] item,_ in
                guard item.status == .failed else { return }
                Task { @MainActor in guard let self, self.token == generation else { return }; self.error = "系统未能播放此 HLS 媒体，仍可尝试原流录制。"; self.player?.pause(); self.player = nil; self.relay?.stop(); self.relay = nil }
            }
            player = p; label = result.result?.preview?.label ?? "HLS"; p.play()
        } catch { if generation == token, !Task.isCancelled { self.error = DownloadManager.safeError(error); label = "预览未连接" } }
    }
    func stop() { token = UUID(); observation = nil; player?.pause(); player = nil; relay?.stop(); relay = nil; resolved = nil }
}
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer?
    final class Surface: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self }; var playerLayer:AVPlayerLayer { layer as! AVPlayerLayer } }
    func makeUIView(context:Context) -> Surface { let v = Surface(); v.playerLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ uiView:Surface,context:Context) { uiView.playerLayer.player = player }
    static func dismantleUIView(_ uiView:Surface,coordinator:()) { uiView.playerLayer.player = nil }
}
