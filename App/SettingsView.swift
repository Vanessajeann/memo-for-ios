import SwiftUI
import MemoCore
import UniformTypeIdentifiers

struct SettingsView:View {
    @ObservedObject var douyin:WorksModel
    @ObservedObject var bili:WorksModel
    @EnvironmentObject var store:SourceStore
    @EnvironmentObject var recorder:RecordingManager
    @AppStorage("live.autoPreview") private var automatic = true
    @AppStorage("live.grid") private var grid = true
    @State private var importing = false
    @State private var exporting = false
    @State private var exportWarning = false
    @State private var about = false
    @State private var logout:Platform?
    @State private var browser:Platform?
    @State private var document = SourceDocument()
    var body:some View {
        NavigationStack {
            Form {
                Section("直播预览") {
                    Toggle("九宫格自动预览",isOn:$automatic)
                    Toggle("九宫格布局",isOn:$grid)
                    Text("小窗默认静音并优先使用较轻的 HLS 画质。切换页面或进入后台会释放小窗，录制任务独立运行。").font(.caption).foregroundStyle(.secondary)
                }
                Section("官方平台会话") {
                    sessionRow(douyin); sessionRow(bili)
                    Text("账号登录与验证仅在官方网页完成。队列与作品缓存不保存 Cookie；媒体下载不附带账号 Cookie。").font(.caption).foregroundStyle(.secondary)
                }
                Section("后台录制") {
                    Label(recorder.listeningText,systemImage:"headphones")
                    if recorder.listeningID != nil { Button("停止收听") { recorder.stopListening() } }
                    Text("点直播卡片右上角的 ···，选择后台收听。检测到真实音轨并开始播放后再锁屏；可在这里查看检测、缓冲和收听状态。无声录制使用系统给予的有限后台时间，时限结束会停止并保留片段。自签不会解除 iOS 的后台限制；长时间锁屏录制仍需真机验证。").font(.caption).foregroundStyle(.secondary)
                }
                Section("数据迁移") {
                    Button("导出直播源",systemImage:"square.and.arrow.up") { exportWarning = true }
                    Button("导入 Android／iOS 直播源",systemImage:"square.and.arrow.down") { importing = true }
                    Text("兼容 MemoSources v1。录像和作品请在录像页分享或保存到 Files；卸载前先导出。").font(.caption).foregroundStyle(.secondary)
                }
                Section("关于 Memo") {
                    LabeledContent("版本",value:(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "") + " · " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""))
                    LabeledContent("目标设备",value:"iPhone 16 Pro Max")
                    LabeledContent("最低系统",value:"iOS 18.0")
                    Button("功能适配与开源许可") { about = true }
                    Link("查看版本与下载",destination:URL(string:"https://github.com/Vanessajeann/memo-for-ios/releases")!)
                }
            }
            .memoPage().navigationTitle("设置")
            .sheet(item:$browser) { p in OfficialBrowser(model:p == .douyin ? douyin : bili) }
            .sheet(isPresented:$about) { AboutMemoView() }
            .confirmationDialog("退出此平台的本机登录会话？",isPresented:Binding(get:{ logout != nil },set:{ if !$0 { logout = nil } })) { Button("退出登录",role:.destructive) { if let p = logout { Task { await (p == .douyin ? douyin : bili).logout() } }; logout = nil } }
            .alert("备份包含请求头与 Cookie",isPresented:$exportWarning) {
                Button("取消",role:.cancel) {}
                Button("导出") { do { document = SourceDocument(data:try store.exportData()); exporting = true } catch { store.message = error.localizedDescription } }
            } message:{ Text("请保存在你信任的位置。") }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json,.data]) { result in switch result { case .success(let url):store.importBackup(url); case .failure(let error):store.message = error.localizedDescription } }
            .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:"Memo-直播源") { result in if case .failure(let error) = result { store.message = error.localizedDescription } }
        }
    }
    private func sessionRow(_ model:WorksModel)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text(model.platform.label).font(.headline); Spacer(); Button("管理") { model.login(); browser = model.platform } }
            HStack { Text(model.sessionLabel).font(.caption).foregroundStyle(.secondary); Spacer(); Button("退出",role:.destructive) { logout = model.platform }.font(.caption) }
        }.padding(.vertical,4)
    }
}
extension Platform:Identifiable { public var id:String { rawValue } }
struct AboutMemoView:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            List {
                Section("对标 Android Memo 3.2.0-beta1") {
                    Text("九路直播源、抖音／Bilibili 直播解析、独立录制与重新取源")
                    Text("官方网页登录、抖音主页与图集、Bilibili 视频／UP 主／分 P／画质")
                    Text("持久化下载队列、后台文件传输、原文件保存与 DASH 无转码合成")
                    Text("录像／图片管理、相册与 Files 导出、批量分享与源备份")
                }
                Section("验证边界") {
                    Text("构建和合成测试不等于真机全部通过。平台登录／验证、完整真实主页、多路预览与长期锁屏录制需实机确认。非 HLS 直播可录制，当前预览依赖系统支持的 HLS。")
                    Text("平台权限以当前会话实际返回为准；仅试看、加密内容、多段 durl、付费专用入口与非标准音轨沿用原版限制。断网和系统挂起期间错过的直播无法补回。")
                }
                Section("开源许可") {
                    Text("Memo 自有源码：MIT。FFmpeg 7.1.5：LGPL 2.1+；每个 Release 附完整源码、静态库和重新链接材料。接口解析由本项目源码独立移植，无第三方解析服务。")
                }
            }.navigationTitle("关于与适配").navigationBarTitleDisplayMode(.inline).toolbar { Button("关闭") { dismiss() } }
        }
    }
}
