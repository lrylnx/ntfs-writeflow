import SwiftUI
import AppKit
import ServiceManagement

@main struct WriteFlowCompatApp: App {
    @NSApplicationDelegateAdaptor(CompatAppDelegate.self) private var delegate
    @StateObject private var model = CompatAppModel()

    var body: some Scene {
        WindowGroup("NTFS 畅写 · 兼容版") {
            CompatContentView(model: model)
                .frame(minWidth: 850, minHeight: 620)
                .task {
                    await model.refresh()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        if !Task.isCancelled { await model.refresh() }
                    }
                }
        }
        .defaultSize(width: 1000, height: 690)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新磁盘") { Task { await model.refresh() } }.keyboardShortcut("r")
                    .disabled(model.busy)
            }
        }
    }
}

final class CompatAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CompatContentView: View {
    @ObservedObject var model: CompatAppModel
    @State private var ejectTarget: CompatVolume?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("NTFS 磁盘").font(.title.bold()).padding(20)
                List(selection: $model.selection) {
                    ForEach(model.volumes) { volume in
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(volume.record.name)
                                Text(volume.record.access.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "externaldrive") }
                        .tag(volume.id).padding(.vertical, 4)
                    }
                }
                Divider()
                Text("Intel 与 Apple 芯片\nmacOS 13 及以上")
                    .font(.caption).foregroundStyle(.secondary).padding(18)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NTFS 畅写").font(.largeTitle.bold())
                            Text("兼容预览版 · 免内核扩展").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                        Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .disabled(model.busy)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(model.componentInstalled ? "FUSE-T 组件已安装" : "首次使用：安装 FUSE-T 组件",
                                  systemImage: model.componentInstalled ? "checkmark.circle.fill" : "1.circle")
                            if !model.componentInstalled {
                                Text("官方安装包已内置，无需另外下载。按系统安装器提示完成安装后，返回这里点击刷新。")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("安装内置组件…") { model.installComponent() }
                                    .disabled(model.busy)
                            }
                            Divider()
                            Label(model.helperStatus, systemImage: model.helperEnabled ? "checkmark.circle.fill" : "2.circle")
                            Text("读写外接物理磁盘需要系统管理员授权。请将应用固定放在“用户目录 → 应用程序”后配置服务。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if model.needsApproval {
                                    Button("打开系统授权设置") { SMAppService.openSystemSettingsLoginItems() }
                                } else if !model.helperEnabled {
                                    Button("安装或更新管理员助手…") { model.configureHelper() }
                                } else {
                                    Button("移除管理员助手") { Task { await model.removeHelper() } }
                                }
                            }.disabled(model.busy)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }

                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    } else if let message = model.message {
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }

                    if let selected = model.selected {
                        detail(selected)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 42)).foregroundStyle(.secondary)
                            Text("连接 NTFS 格式的外接磁盘").font(.title3.bold())
                            Text("连接后点击刷新。仅显示外接 NTFS 卷，内置磁盘不提供操作。")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }

                    Text("兼容预览版：构建目标为 macOS 13+，Intel 与 macOS 13 实机读写仍待验收。使用前请备份重要文件。FUSE-T 会显示为本地网络卷；如果系统询问网络卷访问，请按实际需要授权。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }
        }
        .confirmationDialog("安全推出整盘？", isPresented: Binding(get: { ejectTarget != nil }, set: { if !$0 { ejectTarget = nil } }), presenting: ejectTarget) { target in
            Button("安全推出整盘") { Task { await model.eject(target) } }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("请先保存文件并正常卸载同盘所有卷，等待明确的成功提示后再断开设备。") }
    }

    private func detail(_ volume: CompatVolume) -> some View {
        let record = volume.record
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "externaldrive.fill").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.title2.bold())
                    Text(record.access.rawValue + (volume.receipt != nil ? " · 由兼容版挂载" : ""))
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("格式").foregroundStyle(.secondary); Text(record.fileSystemName) }
                GridRow { Text("容量").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)) }
                if let path = record.mountPoint {
                    GridRow { Text("位置").foregroundStyle(.secondary); Text(path).textSelection(.enabled).lineLimit(2) }
                }
            }.font(.callout)
            if record.mountPoint != nil && volume.receipt == nil {
                Text("此卷由系统或其他驱动挂载。需要切换读写时，请先在原工具或“磁盘工具”中正常卸载该卷，再回到这里刷新。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if record.mountPoint == nil {
                    Button("只读挂载") { Task { await model.mount(volume, readOnly: true) } }
                        .disabled(!model.componentInstalled || !model.helperEnabled)
                    Button("读写挂载") { Task { await model.mount(volume, readOnly: false) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.componentInstalled || !model.helperEnabled || record.writableMedia != true)
                } else {
                    Button("在 Finder 中打开") { Task { await model.openInFinder(volume) } }
                        .disabled(!model.helperEnabled)
                    if volume.receipt != nil {
                        Button("正常卸载此卷") { Task { await model.unmount(volume) } }
                    }
                }
                Button("安全推出整盘…") { ejectTarget = volume }
                    .disabled(!model.helperEnabled || record.mountPoint != nil)
            }.disabled(model.busy || !model.current)
        }
    }
}
