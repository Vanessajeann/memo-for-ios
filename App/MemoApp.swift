import SwiftUI
import MemoCore
import AVKit
import UniformTypeIdentifiers

@main
struct MemoApp: App {
    @StateObject private var store = SourceStore()
    @StateObject private var recorder = RecordingManager()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(recorder)
                .onAppear { recorder.monitor() }
                .onChange(of: scenePhase) { _, phase in recorder.background(phase == .background) }
        }
    }
}

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var sources: [Source] = []
    @Published var message: String?
    private var writable = true
    private let file: URL
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memo", isDirectory: true).appendingPathComponent("sources.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let backup = try SourceBackup.decode(Data(contentsOf: file))
            var checked: [Source] = []
            for s in backup.sources { checked = try SourceList.upsert(s, into: checked) }
            sources = checked
        } catch {
            writable = false
            message = "直播源文件无法读取，已保留原文件并暂停写入。请先备份应用数据。"
        }
    }
    private func persist(_ new: [Source]) throws {
        guard writable else { throw MemoError.invalidBackup }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SourceBackup(sources: new)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sources = new
    }
    func save(_ s: Source) throws { try persist(SourceList.upsert(s, into: sources)) }
    func remove(_ s: Source) {
        do { try persist(sources.filter { $0.id != s.id }) }
        catch { message = error.localizedDescription }
    }
    func importBackup(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let backup = try SourceBackup.decode(handle.read(upToCount: 1_000_001) ?? Data())
            var updated = sources
            var imported = 0
            for var s in backup.sources {
                s.id = UUID().uuidString
                let checked = try s.validated()
                if updated.contains(where: { $0.url == checked.url }) { continue }
                updated = try SourceList.upsert(checked, into: updated); imported += 1
            }
            try persist(updated)
            message = "已导入 \(imported) 个直播源，重复项已跳过。"
        } catch { message = "导入未完成，原列表未修改：\(error.localizedDescription)" }
    }
    func exportData() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(SourceBackup(sources: sources))
    }
}

struct RootView: View {
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var recorder: RecordingManager
    var body: some View {
        TabView {
            LiveView().tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
            RecordingLibraryView().tabItem { Label("录像", systemImage: "film.stack") }
            MigrationStatusView().tabItem { Label("移植进度", systemImage: "checklist") }
        }
        .alert("Memo", isPresented: Binding(get: { store.message != nil || recorder.message != nil }, set: { if !$0 { store.message = nil; recorder.message = nil } })) {
            Button("知道了") { store.message = nil; recorder.message = nil }
        } message: { Text(store.message ?? recorder.message ?? "") }
    }
}

struct LiveView: View {
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var recorder: RecordingManager
    @State private var editor: Source?
    @State private var preview: Source?
    @State private var deleting: Source?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportWarning = false
    @State private var document = SourceDocument()
    @State private var grid = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("录制测试版 · 原流保存", systemImage: "record.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: grid ? 3 : 1), spacing: 12) {
                        ForEach(store.sources) { source in
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.tint)
                                Text(source.name).font(.headline).lineLimit(2)
                                Text(Link.platform(source.url)).font(.caption2).foregroundStyle(.secondary)
                                Button("预览") { openPreview(source) }.buttonStyle(.bordered)
                                if let state = recorder.states[source.id] {
                                    Text(state.text).font(.caption2)
                                    Text(String(format: "%.0f 秒 · %.1f MB", state.mediaSeconds, Double(state.bytes) / 1_048_576))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Button(recorder.busy(source.id) ? "停止" : "录制") {
                                    if recorder.busy(source.id) { recorder.stop(source.id) }
                                    else { recorder.start(source) }
                                }.buttonStyle(.borderedProminent).tint(recorder.busy(source.id) ? .red : .accentColor)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                            .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { editor = source }.disabled(recorder.busy(source.id))
                                Button("移除", systemImage: "trash", role: .destructive) { deleting = source }.disabled(recorder.busy(source.id))
                                Button(recorder.listeningID == source.id ? "停止后台收听" : "后台收听（HLS）") {
                                    if recorder.listeningID == source.id { recorder.stopListening() }
                                    else { recorder.listen(source) }
                                }
                                Button("复制录制诊断") { UIPasteboard.general.string = recorder.states[source.id]?.diagnostic ?? "暂无诊断" }
                            }
                        }
                        if store.sources.count < 9 {
                            Button { editor = Source() } label: {
                                Label("添加", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 140)
                            }.buttonStyle(.bordered)
                        }
                    }
                    Text("媒体直链支持 HLS、HTTP-FLV、RTMP(S)、RTSP 录制；平台分享解析仍在移植。长按直播源可开启真实后台收听。无声录制在后台受系统时限约束，时限到后会停止并尽量保留片段。").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Memo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(grid ? "切换列表" : "切换九宫格") { grid.toggle() }
                        Button("导入直播源") { importing = true }
                        Button("导出直播源") { exportWarning = true }
                        Button("停止全部录制", role: .destructive) { recorder.stopAll() }.disabled(recorder.activeCount == 0)
                        if recorder.listeningID != nil { Button("停止后台收听") { recorder.stopListening() } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $editor) { SourceEditor(source: $0) }
            .sheet(item: $preview) { StreamPreview(source: $0) }
            .confirmationDialog("移除直播源？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("移除", role: .destructive) { if let source = deleting { store.remove(source) }; deleting = nil }
            }
            .alert("备份包含请求头与 Cookie", isPresented: $exportWarning) {
                Button("取消", role: .cancel) {}
                Button("导出") {
                    do { document = SourceDocument(data: try store.exportData()); exporting = true }
                    catch { store.message = error.localizedDescription }
                }
            } message: { Text("请将备份保存在你信任的位置。") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                switch result { case .success(let url): store.importBackup(url); case .failure(let error): store.message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Memo-直播源") { result in
                if case .failure(let error) = result { store.message = error.localizedDescription }
            }
        }
    }
    private func openPreview(_ source: Source) {
        guard Link.platform(source.url) == "媒体直链",
              URL(string: source.url)?.pathExtension.lowercased() == "m3u8",
              source.cookie.isEmpty, source.referer.isEmpty, source.agent == "Mozilla/5.0" else {
            store.message = "此开发版暂仅验证无自定义请求头的 HLS 直链。此源已保留，完整解析与录制仍在移植。"; return
        }
        preview = source
    }
}

struct SourceEditor: View {
    @EnvironmentObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $source.name)
                TextField("直播分享文案或媒体直链", text: $source.url, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section("请求头（可选）") {
                    TextField("Referer", text: $source.referer).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Cookie", text: $source.cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("User-Agent", text: $source.agent).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("直播源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try store.save(source); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct StreamPreview: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorder: RecordingManager
    @State private var player: AVPlayer?
    @State private var audioError: String?
    var body: some View {
        NavigationStack {
            VStack {
                VideoPlayer(player: player)
                Text("预览不会保存录像。后台持续性仍需真机验证。").font(.footnote).padding()
                if let audioError { Text(audioError).font(.footnote) }
            }
            .navigationTitle(source.name)
            .toolbar { Button("关闭") { dismiss() } }
            .onAppear {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                    try AVAudioSession.sharedInstance().setActive(true)
                    if let url = URL(string: source.url) { player = AVPlayer(url: url); player?.play() }
                } catch { audioError = "音频会话未能启动：\(error.localizedDescription)" }
            }
            .onDisappear {
                player?.pause(); player = nil
                if recorder.listeningID == nil {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }
}

struct MigrationStatusView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("已接入，待真机验证") {
                    Text("直播源管理与 Android 备份兼容")
                    Text("HLS 直链预览与真实音频会话")
                    Text("FFmpeg 直链原流录制、独立停止、有限重连、MKV→MP4")
                    Text("本地录像、分享、导入和保存到相册")
                }
                Section("待移植") {
                    Text("抖音／Bilibili 分享解析与会话")
                    Text("抖音视频、图集、主页分页下载")
                    Text("Bilibili 分 P、画质、音轨与 DASH 合成")
                    Text("下载队列、录像管理与系统导出")
                    Text("锁屏与切 App 的长期录制测试")
                }
                Section {
                    Text("以 Android 3.2.0-beta1 全部功能为目标。当前为直链录制测试版，尚未完成平台解析与作品下载移植。")
                    Text("目标：iPhone 16 Pro Max / iOS 18.6.2。签名不会解除系统后台限制。")
                }
            }.navigationTitle("移植进度")
        }
    }
}

struct SourceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
