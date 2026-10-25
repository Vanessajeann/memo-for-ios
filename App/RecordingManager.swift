import Foundation
import UIKit
import AVFoundation
import MemoCore

/// Owns a native handle until its blocking call has returned. Only cancellation and
/// progress snapshots may run concurrently; the C implementation uses C11 atomics.
final class NativeCapture: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let p = memo_capture_create() else { throw CocoaError(.fileWriteOutOfSpace) }
        pointer = p
    }
    deinit { memo_capture_destroy(pointer) }
    func cancel() { memo_capture_cancel(pointer) }
    func progress() -> MemoProgress { memo_capture_progress(pointer) }
    func capture(source: Source, file: URL) -> Int32 {
        memo_capture_run(pointer, source.url, source.agent, source.referer, source.cookie, file.path)
    }
    func mp4(input: URL, output: URL) -> Int32 { memo_capture_mp4(pointer, input.path, output.path) }
    func join(video: URL, audio: URL, output: URL) -> Int32 { memo_capture_join(pointer, video.path, audio.path, output.path) }
    func probeAudio(_ source: Source) -> Int32 { memo_capture_probe_audio(pointer, source.url, source.agent, source.referer, source.cookie) }
    static func error(_ code: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: 256)
        memo_capture_error(code, &bytes, 256)
        return String(cString: bytes)
    }
}

struct RecordingState {
    var text = "正在连接…"
    var diagnostic = ""
    var busy = true
    var bytes: Int64 = 0
    var mediaSeconds: Double = 0
}

@MainActor
final class RecordingManager: ObservableObject {
    @MainActor private final class Work {
        let source: Source
        let prefix: String
        var wanted = true
        var worker: Task<Void,Never>?
        var handle: NativeCapture?
        var locked = Set<URL>()
        var totalBytes: Int64 = 0
        var totalMedia: Double = 0
        var reason = ""
        init(_ source: Source) {
            self.source = source
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let name = String(source.name.filter { !$0.isNewline && !"/\\:".contains($0) }.prefix(32))
            prefix = name + "-" + f.string(from: Date()) + "-" + UUID().uuidString
        }
    }
    @Published private(set) var states: [String: RecordingState] = [:]
    @Published private(set) var listeningID: String?
    @Published private(set) var listeningText = "当前未开启后台收听"
    @Published private(set) var filesVersion = 0
    @Published private(set) var conversions = Set<URL>()
    @Published var message: String?
    private var works: [String: Work] = [:]
    private var listenerRelay: HLSRelay?
    private var listener: AVPlayer?
    private var listenerObservation: NSKeyValueObservation?
    private var listenerItemObservation: NSKeyValueObservation?
    private var listenerEndObserver: NSObjectProtocol?
    private var listenTask: Task<Void,Never>?
    private var listenTimeout: Task<Void,Never>?
    private var listenProbe: NativeCapture?
    private var listenGeneration = UUID()
    private var manualHandles: [URL: NativeCapture] = [:]
    private var timer: Timer?
    private var inBackground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var playbackObserver: NSObjectProtocol?
    let directory: URL
    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch { message = "录像目录无法创建：\(error.localizedDescription)" }
        playbackObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.message = "直播收听被系统中断。录制仍取决于系统后台时限，已有片段会尽量保留。"
                }
            }
        }
    }
    var activeCount: Int { works.count }
    func busy(_ id: String) -> Bool { works[id] != nil }
    func isLocked(_ url: URL) -> Bool { conversions.contains(url) || works.values.contains { $0.locked.contains(url) } }
    func monitor() {
        guard timer == nil, !works.isEmpty, !inBackground else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        for (id, work) in works {
            guard let p = work.handle?.progress() else { continue }
            var state = states[id] ?? RecordingState()
            state.bytes = work.totalBytes + p.bytes
            state.mediaSeconds = work.totalMedia + Double(p.media_microseconds) / 1_000_000
            if p.phase == 3 && work.wanted { state.text = "录制中" }
            states[id] = state
        }
    }
    func start(_ original: Source) {
        guard !busy(original.id) else { return }
        do {
            let source = try original.validated()
                        guard works.count < 9 else { message = "最多同时录制 9 路"; return }
            let work = Work(source)
            works[source.id] = work; states[source.id] = RecordingState()
            monitor(); updateBackgroundBudget()
            work.worker = Task { await run(work) }
        } catch { message = error.localizedDescription }
    }
    func stop(_ id: String, reason: String = "已停止") {
        guard let work = works[id] else { return }
        work.wanted = false; work.reason = reason; work.worker?.cancel(); work.handle?.cancel()
        var state = states[id] ?? RecordingState(); state.text = "停止并保存…"; states[id] = state
    }
    func stopAll(reason: String = "已停止") { for id in Array(works.keys) { stop(id, reason: reason) } }
    private func run(_ work: Work) async {
        let id = work.source.id
        var attempt = 0, segment = 0, finalText = "已完成"
        while work.wanted {
            segment += 1
            let input = directory.appendingPathComponent("\(work.prefix)-\(segment).mkv")
            do {
                states[id]?.text = attempt == 0 ? "解析直播源…" : "重新取源 · 第 \(attempt) 次"
                let resolved = try await PlatformClient.shared.live(work.source)
                guard work.wanted else { break }
                let source = resolved.recording
                let handle = try NativeCapture()
                work.handle = handle; work.locked.insert(input)
                states[id]?.diagnostic += "平台：\(Link.platform(work.source.url)) · 画质：\(resolved.result?.best?.label ?? "直链")\n"
                let result = await Task.detached(priority: .utility) { handle.capture(source: source, file: input) }.value
                let progress = handle.progress()
                work.handle = nil
                work.totalBytes += progress.bytes
                work.totalMedia += Double(progress.media_microseconds) / 1_000_000
                let summary = "片段 \(segment) · 媒体包 \(progress.packets) · 返回码 \(result)" + (result < 0 ? " · " + NativeCapture.error(result) : "")
                states[id]?.diagnostic += summary + "\n"
                if progress.packets > 0 {
                    if !inBackground {
                        states[id]?.text = "正在整理 MP4…"
                        do { _ = try await convert(input, work: work) }
                        catch { states[id]?.diagnostic += "MP4 整理未完成；MKV 已保留。\n" }
                    } else {
                        states[id]?.diagnostic += "后台已保留 MKV，返回后可在录像页整理。\n"
                    }
                } else { try? FileManager.default.removeItem(at: input) }
                work.locked.remove(input); filesVersion += 1
                finalText = work.reason.isEmpty ? (result < 0 ? "录制中断 · 片段已保留" : "已完成") : work.reason
                guard work.wanted, result < 0, memo_capture_retryable(result) != 0,
                      attempt < RecordingPolicy.maxRetries else { break }
                attempt += 1
                states[id]?.text = "等待重连 · \(attempt) / \(RecordingPolicy.maxRetries)"
                // C I/O and watchdog run independently of this UI/retry scheduler.
                let delay = Int(RecordingPolicy.delay(attempt: attempt))
                for _ in 0..<delay {
                    if !work.wanted { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                if work.wanted, attempt < RecordingPolicy.maxRetries, let network = error as? URLError, [.timedOut,.networkConnectionLost,.notConnectedToInternet,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed].contains(network.code) {
                    attempt += 1; states[id]?.text = "等待网络并重新取源 · \(attempt)"
                    try? await Task.sleep(nanoseconds:UInt64(RecordingPolicy.delay(attempt:attempt)) * 1_000_000_000)
                    continue
                }
                finalText = work.reason.isEmpty ? "录制无法启动" : work.reason
                states[id]?.diagnostic += DownloadManager.safeError(error) + "\n"; break
            }
        }
        work.worker = nil
        works.removeValue(forKey: id)
        var state = states[id] ?? RecordingState()
        state.text = work.reason.isEmpty ? finalText : work.reason
        state.busy = false; state.bytes = work.totalBytes; state.mediaSeconds = work.totalMedia
        if work.totalBytes == 0 { state.text = "未收到可保存的媒体" }
        states[id] = state
        if listeningID == id { stopListening() }
        filesVersion += 1
        if works.isEmpty { timer?.invalidate(); timer = nil; endBackgroundTask() }
    }
    private func convert(_ input: URL, work: Work? = nil) async throws -> URL {
        let output = input.deletingPathExtension().appendingPathExtension("mp4")
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".mp4.part")
        let handle = try NativeCapture()
        if let work { work.handle = handle }
        else { manualHandles[input] = handle }
        defer {
            if let work { work.handle = nil } else { manualHandles.removeValue(forKey: input) }
            try? FileManager.default.removeItem(at: temporary)
        }
        let result = await Task.detached(priority: .utility) { handle.mp4(input: input, output: temporary) }.value
        guard result >= 0, handle.progress().packets > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.moveItem(at: temporary, to: output)
        // Publish a complete MP4 before removing the original MKV.
        try? FileManager.default.removeItem(at: input)
        return output
    }
    func convertFile(_ file: URL) {
        guard !isLocked(file), file.pathExtension == "mkv" else { return }
        conversions.insert(file)
        Task {
            do { _ = try await convert(file); message = "MP4 已保存" }
            catch { message = "整理失败，原 MKV 已保留。" }
            conversions.remove(file); filesVersion += 1; updateBackgroundBudget()
        }
    }
    func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { ["mp4", "mkv"].contains($0.pathExtension) && !isLocked($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func delete(_ file: URL) {
        guard file.deletingLastPathComponent() == directory, !isLocked(file) else { return }
        do { try FileManager.default.removeItem(at: file); filesVersion += 1 }
        catch { message = "删除失败：\(error.localizedDescription)" }
    }
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard ["mp4", "mkv"].contains(url.pathExtension.lowercased()) else { throw CocoaError(.fileReadCorruptFile) }
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            let bytes = Array(try h.read(upToCount: 12) ?? Data())
            let mkv = bytes.count >= 4 && Array(bytes.prefix(4)) == [0x1a, 0x45, 0xdf, 0xa3]
            let mp4 = bytes.count >= 8 && String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp"
            guard (url.pathExtension.lowercased() == "mkv" ? mkv : mp4) else { throw CocoaError(.fileReadCorruptFile) }
            let target = directory.appendingPathComponent("导入-" + UUID().uuidString + "." + url.pathExtension.lowercased())
            try FileManager.default.copyItem(at: url, to: target); filesVersion += 1
        } catch { message = "无法导入此录像：\(error.localizedDescription)" }
    }
    func listen(_ original: Source) {
        guard let source = try? original.validated(),
              let url = URL(string: source.url), ["http","https"].contains(url.scheme ?? ""),
              url.pathExtension.lowercased() == "m3u8" else {
            message = "后台收听需要包含真实音轨的 HLS 媒体。"; return
        }
        stopListening()
        let generation = listenGeneration
        listeningID = source.id; listeningText = "正在检测直播音轨…"
        listenTask = Task {
            do {
                // HLS static AVAsset tracks can be empty before playback. Inspect
                // actual demuxed packets with the capture engine's scoped headers.
                let probe = try NativeCapture(); listenProbe = probe
                let result = await withTaskCancellationHandler {
                    await Task.detached(priority:.utility) { probe.probeAudio(source) }.value
                } onCancel: { probe.cancel() }
                guard listenGeneration == generation, !Task.isCancelled else { return }
                listenProbe = nil
                guard result >= 0 else {
                    stopListening(); message = "音轨检测未完成（\(result)），请检查网络或刷新直播源后重试；前台录制不受此提示影响。"; return
                }
                guard result == 1 else {
                    stopListening(); message = "已检测到画面，但当前直播流未提供音轨，无法开启后台收听。前台录制仍可继续。"; return
                }
                let bridge = HLSRelay(source: source)
                defer { if listenerRelay !== bridge { bridge.stop() } }
                let local = try await bridge.start()
                guard listenGeneration == generation, !Task.isCancelled else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                listenerRelay = bridge
                let item = AVPlayerItem(url:local), player = AVPlayer()
                player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                listener = player; listeningText = "已检测到音轨，正在缓冲…"
                listenerItemObservation = item.observe(\.status, options:[.initial,.new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    Task { @MainActor in
                        guard let self, self.listenGeneration == generation, failed else { return }
                        self.stopListening(); self.message = "已检测到音轨，但系统播放器无法播放此直播，请刷新直播源或更换 HLS 画质后重试。"
                    }
                }
                listenerObservation = player.observe(\.timeControlStatus, options: [.initial,.new]) { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self, self.listenGeneration == generation, let player = self.listener else { return }
                        if player.timeControlStatus == .playing {
                            self.listeningText = "正在收听直播音频"
                            self.listenTimeout?.cancel(); self.listenTimeout = nil
                        } else { self.listeningText = "收听已暂停或正在缓冲…" }
                        self.updateBackgroundBudget()
                    }
                }
                listenerEndObserver = NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.listenGeneration == generation else { return }
                        self.stopListening(); self.message = "直播收听已结束。"
                    }
                }
                listenTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds:30_000_000_000) } catch { return }
                    guard let self, self.listenGeneration == generation else { return }
                    self.stopListening(); self.message = "收听启动超时，请检查网络或刷新直播源后重试。"
                }
                player.replaceCurrentItem(with:item)
                player.play()
                listenTask = nil
            } catch {
                if listenGeneration == generation { stopListening(); message = "收听未能启动：\(DownloadManager.safeError(error))" }
            }
        }
    }
    func stopListening() {
        let wasListening = listeningID != nil
        listenGeneration = UUID(); listenTask?.cancel(); listenTask = nil
        listenProbe?.cancel(); listenProbe = nil; listenTimeout?.cancel(); listenTimeout = nil
        listenerObservation = nil; listenerItemObservation = nil
        if let listenerEndObserver { NotificationCenter.default.removeObserver(listenerEndObserver) }; listenerEndObserver = nil
        listener?.pause(); listener = nil; listenerRelay?.stop(); listenerRelay = nil; listeningID = nil
        listeningText = "当前未开启后台收听"
        if wasListening { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        updateBackgroundBudget()
    }
    func background(_ value: Bool) {
        inBackground = value
        if value { timer?.invalidate(); timer = nil } else { monitor(); tick() }
        updateBackgroundBudget()
    }
    private func updateBackgroundBudget() {
        guard inBackground, !works.isEmpty || !conversions.isEmpty else { endBackgroundTask(); return }
        // Genuine, user-requested audio playback is its own background mode.
        // A temporary task is only the fallback for buffering/interruption/silent capture.
        if listener?.timeControlStatus == .playing { endBackgroundTask(); return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Memo recording save") { [weak self] in
                Task { @MainActor in
                    self?.stopAll(reason: "后台时限已到 · 已保留片段")
                    self?.manualHandles.values.forEach { $0.cancel() }
                    self?.endBackgroundTask()
                }
            }
        }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
