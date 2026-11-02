import AppKit
import Combine
import ServiceManagement
import Darwin

@MainActor final class CompatAppModel: ObservableObject {
    @Published var volumes: [CompatVolume] = []
    @Published var selection: String?
    @Published var busy = false
    @Published var current = false
    @Published var message: String?
    @Published var failure: String?
    @Published var helperEnabled = false
    @Published var needsApproval = false
    @Published var componentInstalled = Compatibility.componentInstalled
    @Published var helperStatus = "尚未配置"
    @Published var lastRefresh: Date?
    private let inventory = CompatInventory()
    private var ejectedMedia = EjectedMediaSession()

    var selected: CompatVolume? { volumes.first { $0.id == selection } }

    func installComponent() {
        guard !busy else { return }
        guard let installer = Compatibility.bundledInstaller, NSWorkspace.shared.open(installer) else {
            failure = "无法打开内置组件安装包，请重新解压完整应用。"
            return
        }
        message = "已打开系统安装器。请按提示完成安装，然后返回这里点击刷新。"
        failure = nil
    }

    func refreshHelper() {
        componentInstalled = Compatibility.componentInstalled
        let installed = Compatibility.installedHelperBuild
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        helperEnabled = installed != nil && installed == expected
        needsApproval = false
        if helperEnabled { helperStatus = "管理员助手已安装" }
        else if installed != nil { helperStatus = "管理员助手需要更新" }
        else { helperStatus = "管理员助手尚未安装" }
    }

    func configureHelper() {
        guard !busy else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                guard try !Compatibility.hasManagedMounts() else {
                    throw DiskOperationError(message: "请先正常卸载受管卷，再安装或更新助手。")
                }
                // Migrate the earlier SMAppService preview only when no NTFS media
                // is attached; an unreachable old service must not stop live I/O.
                if Compatibility.installedHelperBuild == nil,
                   SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).status == .enabled {
                    let devices = try await inventory.snapshot([])
                    guard !devices.contains(where: { $0.record.isNTFS && $0.record.isInternal == false }) else {
                        throw DiskOperationError(message: "旧预览服务需要迁移，请先确认安全并断开 NTFS 介质，再配置助手。")
                    }
                    try await SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).unregister()
                }
                guard let package = Compatibility.servicePackage(), NSWorkspace.shared.open(package) else {
                    throw DiskOperationError(message: "无法打开内置的管理员助手安装包，请重新解压完整应用。")
                }
                message = "已打开系统安装器。完成管理员助手安装后，请返回应用刷新。"
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }

    func removeHelper() async {
        await operate {
            guard try !Compatibility.hasManagedMounts() else {
                throw DiskOperationError(message: "请先正常卸载所有受管卷，再移除助手。")
            }
            let mounts = try await PrivilegedMountClient.mountedVolumes()
            guard mounts.isEmpty else { throw DiskOperationError(message: "仍有受管卷，请先正常卸载。") }
            guard let package = Compatibility.servicePackage(removal: true), NSWorkspace.shared.open(package) else {
                throw DiskOperationError(message: "无法打开内置的助手移除包。")
            }
            self.message = "已打开助手移除包，请按系统提示完成。"
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await load(); failure = nil }
        catch { current = false; failure = "磁盘状态未能完整读取：\(error.localizedDescription)" }
    }

    private func load() async throws {
        refreshHelper()
        let receipts = helperEnabled ? try await PrivilegedMountClient.mountedVolumes() : []
        if helperEnabled { helperStatus = "管理员助手连接正常" }
        let records = try await inventory.snapshot(receipts)
        if ejectedMedia.reconcile(records: records.map(\.record), unreadableCount: 0) { message = nil }
        volumes = records.filter { $0.record.isNTFS && $0.record.isInternal == false && !ejectedMedia.contains($0.record) }
            .sorted { $0.record.name.localizedStandardCompare($1.record.name) == .orderedAscending }
        if !volumes.contains(where: { $0.id == selection }) { selection = volumes.first?.id }
        current = true
        lastRefresh = Date()
    }

    private func fresh(_ expected: CompatVolume) async throws -> CompatVolume {
        let receipts = try await PrivilegedMountClient.mountedVolumes()
        let volume = try await inventory.read(expected.id, receipts: receipts)
        guard expected.record.matchesMediaIdentity(of: volume.record),
              expected.record.mountedFileSystem == volume.record.mountedFileSystem else {
            throw DiskOperationError(message: "磁盘或挂载身份已经变化，请刷新后重新选择。")
        }
        return volume
    }

    func mount(_ volume: CompatVolume, readOnly: Bool) async {
        await operate {
            guard self.componentInstalled else { throw DiskOperationError(message: "请先点击“安装内置组件”，安装完成后刷新。") }
            let target = try await self.fresh(volume).record
            guard target.canOfferMount, let mediaID = target.mediaRegistryID, let wholeID = target.wholeMediaRegistryID else {
                throw DiskOperationError(message: "该卷已被挂载或不符合外部 NTFS 卷条件。")
            }
            _ = try await PrivilegedMountClient.mount(PrivilegedMountRequest(deviceID: target.id, mediaRegistryID: mediaID,
                wholeMediaRegistryID: wholeID, mediaByteCount: target.mediaByteCount, readOnly: readOnly))
            try await self.load()
            guard let actual = self.volumes.first(where: { $0.id == target.id }), actual.receipt != nil,
                  target.matchesMediaIdentity(of: actual.record), actual.record.access == (readOnly ? .readOnly : .readWrite) else {
                throw DiskOperationError(message: "系统返回后未能确认预期访问模式，请刷新检查。")
            }
            self.message = readOnly ? "已只读挂载，可在 Finder 中打开。" : "已读写挂载，可在 Finder 中管理文件。"
        }
    }

    func unmount(_ volume: CompatVolume) async {
        await operate {
            let target = try await self.fresh(volume)
            guard let receipt = target.receipt, let before = target.record.mountedFileSystem else {
                throw DiskOperationError(message: "该卷由其他工具挂载，请使用原工具正常卸载。")
            }
            let fd = Darwin.open(receipt.mountPoint, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw DiskOperationError(message: "无法打开卷根目录，请检查网络卷访问权限。") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard MountedFileSystemReader.read(descriptor: fd) == before else { throw DiskOperationError(message: "挂载实例已经变化。") }
            try await PrivilegedMountClient.prepareUnmount(token: receipt.token, handle: handle)
            try handle.close()
            try await self.inventory.normallyUnmount(before)
            try await PrivilegedMountClient.finishUnmount(token: receipt.token)
            self.message = "卷已正常卸载。断开设备前，请再点击“安全推出整盘”。"
        }
    }

    func openInFinder(_ volume: CompatVolume) async {
        await operate {
            let target = try await self.fresh(volume)
            guard let path = target.record.mountPoint, target.record.mountedFileSystem != nil,
                  NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                throw DiskOperationError(message: "无法打开此卷，请确认它已挂载。")
            }
        }
    }

    func eject(_ volume: CompatVolume) async {
        await operate {
            let target = try await self.fresh(volume).record
            let receipts = try await PrivilegedMountClient.mountedVolumes()
            let all = try await self.inventory.snapshot(receipts)
            guard let whole = all.first(where: { $0.id == target.wholeDiskID })?.record,
                  let mediaID = target.mediaRegistryID, let wholeID = target.wholeMediaRegistryID,
                  whole.mediaRegistryID == wholeID, whole.mediaByteCount > 0,
                  all.filter({ $0.record.wholeMediaRegistryID == wholeID }).allSatisfy({ $0.record.mountPoint == nil }) else {
                throw DiskOperationError(message: "请先通过各自的挂载工具正常卸载同盘所有分卷，再安全推出。")
            }
            let request = PrivilegedEjectRequest(deviceID: target.id, wholeDiskID: target.wholeDiskID,
                mediaRegistryID: mediaID, wholeMediaRegistryID: wholeID,
                mediaByteCount: target.mediaByteCount, wholeMediaByteCount: whole.mediaByteCount)
            try await PrivilegedMountClient.prepareEject(request, handles: [])
            let handle = try await AuthorizedDeviceHandle.open(wholeDiskID: target.wholeDiskID)
            defer { try? handle.close() }
            let receipt = try await HelperEject.eject(request: request, handle: handle, userID: geteuid())
            let after = try await self.inventory.snapshot(try await PrivilegedMountClient.mountedVolumes())
            if let reason = EjectVerification.unconfirmedReason(expected: target, records: after.map(\.record), unreadableCount: 0, receipt: receipt) {
                throw DiskOperationError(message: reason)
            }
            self.ejectedMedia.remember(receipt)
            self.message = receipt.message
        }
    }

    private func operate(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil; message = nil
        defer { busy = false }
        do { try await action(); try await load() }
        catch {
            let detail = error.localizedDescription
            do { try await load() } catch { current = false }
            failure = detail
        }
        refreshHelper()
    }
}
