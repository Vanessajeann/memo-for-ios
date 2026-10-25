import SwiftUI
import MemoCore
import AVKit
import UniformTypeIdentifiers

@main
struct MemoApp: App {
    @UIApplicationDelegateAdaptor(MemoAppDelegate.self) private var delegate
    @StateObject private var store = SourceStore()
    @StateObject private var recorder = RecordingManager()
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var douyin = WorksModel(platform: .douyin)
    @StateObject private var bili = WorksModel(platform: .bilibili)
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView(douyin: douyin, bili: bili).environmentObject(store).environmentObject(recorder).environmentObject(downloads)
                .onAppear { recorder.monitor() }
                .onChange(of: scenePhase) { _, phase in
                    recorder.background(phase == .background); downloads.setForeground(phase == .active)
                    douyin.setForeground(phase == .active); bili.setForeground(phase == .active)
                }
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
    @EnvironmentObject var downloads: DownloadManager
    @ObservedObject var douyin: WorksModel
    @ObservedObject var bili: WorksModel
    @State private var tab = Int(ProcessInfo.processInfo.environment["MEMO_UI_TAB"] ?? "0") ?? 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    private let names = ["直播","录像","作品","设置"]
    private let icons = ["dot.radiowaves.left.and.right","film.stack","square.grid.2x2","slider.horizontal.3"]
    var body: some View {
        GeometryReader { bounds in
        ZStack {
            MemoBackground()
            Group {
                switch tab {
                case 1: RecordingLibraryView()
                case 2: WorksView(douyin:douyin,bili:bili)
                case 3: SettingsView(douyin:douyin,bili:bili)
                default: LiveView()
                }
            }
        }.frame(width:bounds.size.width,height:bounds.size.height)
        }
        .tint(MemoStyle.blue)
        .safeAreaInset(edge:.bottom,spacing:0) {
            HStack(spacing:4) {
                ForEach(0..<4) { index in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response:0.36,dampingFraction:0.82)) { tab = index }
                    } label: {
                        VStack(spacing:4) { Image(systemName:icons[index]).font(.system(size:20,weight:.medium)); Text(names[index]).font(.caption2.weight(.medium)) }
                            .foregroundStyle(tab == index ? MemoStyle.blue : .secondary).frame(maxWidth:.infinity,minHeight:52)
                            .background { if tab == index { RoundedRectangle(cornerRadius:23).fill(MemoStyle.blue.opacity(0.11)).matchedGeometryEffect(id:"tab",in:navigation) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(names[index]).accessibilityAddTraits(tab == index ? .isSelected : [])
                }
            }
            .padding(6).background(.regularMaterial,in:RoundedRectangle(cornerRadius:30))
            .overlay(RoundedRectangle(cornerRadius:30).stroke(.white.opacity(0.45),lineWidth:1))
            .shadow(color:MemoStyle.blue.opacity(0.10),radius:18,y:8).padding(.horizontal,24).padding(.top,8).padding(.bottom,6)
        }
        .alert("Memo",isPresented:Binding(get:{ store.message != nil || recorder.message != nil || downloads.message != nil },set:{ if !$0 { store.message = nil; recorder.message = nil; downloads.message = nil } })) {
            Button("知道了") { store.message = nil; recorder.message = nil; downloads.message = nil }
        } message: { Text(store.message ?? recorder.message ?? downloads.message ?? "") }
    }
}

struct LiveView: View {
    @EnvironmentObject var store:SourceStore
    @EnvironmentObject var recorder:RecordingManager
    @State private var editor:Source?
    @State private var preview:Source?
    @State private var deleting:Source?
    @AppStorage("live.grid") private var grid = true
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        VStack(alignment:.leading,spacing:5) { Text("LIVE STUDIO").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(MemoStyle.blue); Text("留住正在发生的精彩").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer()
                        Label("\(recorder.activeCount) / 9",systemImage:"record.circle").font(.caption.monospacedDigit()).foregroundStyle(recorder.activeCount > 0 ? MemoStyle.red : .secondary)
                    }
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:grid && !typeSize.isAccessibilitySize ? 3 : 1),spacing:12) {
                        ForEach(0..<9,id:\.self) { index in
                            if index < store.sources.count {
                                LiveTile(source:store.sources[index],index:index,grid:grid && !typeSize.isAccessibilitySize,edit:{ editor = store.sources[index] },remove:{ deleting = store.sources[index] },preview:{ preview = store.sources[index] })
                            } else {
                                Button { editor = Source() } label: {
                                    VStack(alignment:.leading) {
                                        Text(String(format:"%02d",index+1)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                        Spacer(minLength:14); Image(systemName:"plus").font(.title3.weight(.light)).frame(maxWidth:.infinity); Spacer(minLength:14)
                                    }.padding(12).frame(minHeight:grid ? 170 : 100).glassCard(radius:22)
                                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("空位 \(index+1)，添加直播源")
                            }
                        }
                    }
                    Label("原流保存 · 独立录制 · 本机管理",systemImage:"externaldrive").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }
            .memoPage().navigationTitle("Memo")
            .toolbar {
                ToolbarItemGroup(placement:.topBarTrailing) {
                    Button("停止全部录制",systemImage:"stop.circle") { recorder.stopAll() }.tint(MemoStyle.red).disabled(recorder.activeCount == 0)
                    Button("添加直播源",systemImage:"plus") { editor = Source() }.disabled(store.sources.count >= 9)
                    Menu { Button(grid ? "切换列表" : "切换九宫格") { grid.toggle() } } label:{ Image(systemName:"ellipsis.circle") }
                }
            }
            .sheet(item:$editor) { SourceEditor(source:$0) }
            .fullScreenCover(item:$preview) { StreamPreview(source:$0) }
            .confirmationDialog("移除直播源？",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } })) {
                Button("移除",role:.destructive) { if let s = deleting { store.remove(s) }; deleting = nil }
            }
        }
    }
}
struct LiveTile:View {
    let source:Source
    let index:Int
    let grid:Bool
    let edit:()->Void, remove:()->Void, preview:()->Void
    @EnvironmentObject var recorder:RecordingManager
    @Environment(\.scenePhase) private var phase
    @AppStorage("live.autoPreview") private var automatic = true
    @StateObject private var stream = StreamSession()
    var body:some View {
        VStack(spacing:0) {
            ZStack(alignment:.top) {
                LinearGradient(colors:[Color(red:0.09,green:0.14,blue:0.24),Color(red:0.19,green:0.28,blue:0.42)],startPoint:.topLeading,endPoint:.bottomTrailing)
                if stream.player != nil { PlayerSurface(player:stream.player) }
                VStack {
                    HStack(spacing:2) {
                        Text(source.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength:0)
                        Menu {
                            Button("放大预览",systemImage:"arrow.up.left.and.arrow.down.right",action:preview)
                            Button("刷新预览",systemImage:"arrow.clockwise") { Task { await stream.open(source) } }
                            Button("编辑",systemImage:"pencil",action:edit).disabled(recorder.busy(source.id))
                            Button(recorder.listeningID == source.id ? "停止后台收听" : "后台收听",systemImage:"headphones") {
                                if recorder.listeningID == source.id { recorder.stopListening() }
                                else { Task { do { let r = try await PlatformClient.shared.live(source); if let hls = r.preview { recorder.listen(hls) } else { recorder.message = "此媒体未返回可收听的 HLS 音轨" } } catch { recorder.message = DownloadManager.safeError(error) } } }
                            }
                            Button("复制诊断",systemImage:"doc.on.doc") { UIPasteboard.general.string = recorder.states[source.id]?.diagnostic ?? "暂无诊断" }
                            Button("移除",systemImage:"trash",role:.destructive,action:remove).disabled(recorder.busy(source.id))
                        } label:{ Image(systemName:"ellipsis").frame(width:30,height:36).contentShape(Rectangle()) }.accessibilityLabel("管理 \(source.name)")
                    }.padding(.leading,10).background(.black.opacity(0.18))
                    Spacer()
                    if stream.player == nil { Image(systemName:stream.error.isEmpty ? "play.rectangle" : "wifi.exclamationmark").font(.title2.weight(.ultraLight)).opacity(0.8).allowsHitTesting(false) }
                    Spacer()
                    HStack { Text(Link.platform(source.url)).font(.system(size:9)).lineLimit(1); Spacer(minLength:0); Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:10)) }.padding(8).allowsHitTesting(false)
                }.foregroundStyle(.white)
            }
            .frame(height:grid ? 126 : 190).clipped().onTapGesture(perform:preview)
            HStack(spacing:2) {
                VStack(alignment:.leading,spacing:3) {
                    Text(recorder.states[source.id]?.text ?? "待录制").font(.system(size:10)).lineLimit(1).foregroundStyle(recorder.busy(source.id) ? MemoStyle.red : .secondary)
                    Text(duration(recorder.states[source.id]?.mediaSeconds ?? 0)).font(.system(size:11,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength:0)
                Button {
                    if recorder.busy(source.id) { recorder.stop(source.id) } else { recorder.start(source) }
                } label:{ Image(systemName:recorder.busy(source.id) ? "stop.fill" : "record.circle").font(.system(size:21)).foregroundStyle(MemoStyle.red).frame(width:40,height:46).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel((recorder.busy(source.id) ? "停止并保存 " : "开始录制 ") + source.name)
            }.padding(.leading,9).padding(.trailing,1)
        }
        .glassCard(radius:22)
        .task(id:"\(source.url)|\(phase)|\(automatic)") {
            if automatic && phase == .active && ProcessInfo.processInfo.environment["MEMO_UI_CAPTURE"] == nil { await stream.open(source) } else { stream.stop() }
        }
        .onDisappear { stream.stop() }
    }
    private func duration(_ value:Double)->String { let n = max(0,Int(value)); return String(format:"%02d:%02d:%02d",n/3600,n/60%60,n%60) }
}
struct SourceEditor:View {
    @EnvironmentObject var store:SourceStore
    @Environment(\.dismiss) private var dismiss
    @State var source:Source
    @State private var error:String?
    @State private var qualities:[LiveStream] = []
    @State private var loading = false
    var body:some View {
        NavigationStack {
            Form {
                Section("直播源") {
                    TextField("名称",text:$source.name)
                    TextField("直播分享文案或媒体直链",text:$source.url,axis:.vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("从剪贴板粘贴",systemImage:"doc.on.clipboard") { if let s = UIPasteboard.general.string { source.url = s } }
                }
                Section("画质") {
                    Picker("录制画质",selection:$source.qualityId) {
                        Text("最高实际可用画质").tag(0)
                        if source.qualityId > 0 && !qualities.contains(where:{ $0.qualityID == source.qualityId }) { Text("已保存档位 \(source.qualityId)").tag(source.qualityId) }
                        ForEach(uniqueQualities) { q in Text(q.label + " · " + q.protocolName).tag(q.qualityID) }
                    }
                    Button(loading ? "解析中…" : "查询当前可用画质") {
                        loading = true
                        Task { defer { loading = false }; do { var s = source; s.qualityId = 0; let result = try await PlatformClient.shared.live(s); qualities = result.result?.streams ?? []; if qualities.isEmpty { error = "此直链由服务器决定画质" } } catch { self.error = DownloadManager.safeError(error) } }
                    }.disabled(loading)
                }
                Section("请求头（可选）") {
                    TextField("Referer",text:$source.referer).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Cookie",text:$source.cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("User-Agent",text:$source.agent).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { Text("支持抖音／Bilibili 直播分享与 HLS、HTTP-FLV、RTMP(S)、RTSP 直链。平台登录和验证可在设置中完成。").font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(MemoStyle.red) }
            }.navigationTitle("直播源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("保存") { do { try store.save(source); dismiss() } catch { self.error = error.localizedDescription } } }
            }
        }
    }
    private var uniqueQualities:[LiveStream] { var seen = Set<Int>(); return qualities.filter { seen.insert($0.qualityID).inserted } }
}
struct StreamPreview:View {
    let source:Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject var recorder:RecordingManager
    @StateObject private var stream = StreamSession()
    @State private var muted = false
    var body:some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = stream.player { VideoPlayer(player:player) }
                else { VStack(spacing:16) { if stream.error.isEmpty { ProgressView().tint(.white) }; Text(stream.error.isEmpty ? stream.label : stream.error).foregroundStyle(.white).multilineTextAlignment(.center) }.padding() }
            }
            .navigationTitle(source.name).navigationBarTitleDisplayMode(.inline).toolbarColorScheme(.dark,for:.navigationBar)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement:.bottomBar) {
                    Button(muted ? "打开声音" : "静音",systemImage:muted ? "speaker.slash" : "speaker.wave.2") { muted.toggle(); stream.player?.isMuted = muted }
                    Spacer()
                    Button(recorder.busy(source.id) ? "停止录制" : "录制",systemImage:"record.circle") { if recorder.busy(source.id) { recorder.stop(source.id) } else { recorder.start(source) } }.tint(MemoStyle.red)
                    Spacer()
                    Button(recorder.listeningID == source.id ? "停止后台收听" : "后台收听",systemImage:"headphones") {
                        if recorder.listeningID == source.id { recorder.stopListening() }
                        else if let s = stream.resolved { recorder.listen(s) }
                    }.disabled(stream.resolved == nil && recorder.listeningID != source.id)
                }
            }
            .task(id:phase) { if phase == .active { await stream.open(source,muted:muted) } else { stream.stop() } }
            .onDisappear { stream.stop() }
        }
    }
}
struct SourceDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.json] }
    var data = Data()
    init(data:Data = Data()) { self.data = data }
    init(configuration:ReadConfiguration)throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration)throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
