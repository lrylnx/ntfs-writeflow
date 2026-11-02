import Foundation
import DiskArbitration
import Darwin

struct CompatVolume: Identifiable {
    let record: VolumeRecord
    let receipt: PrivilegedMountResult?
    var id: String { record.id }
}

actor CompatInventory {
    private let session = DASessionCreate(nil)
    private var bindings: [UInt64: RetainedDiskBinding] = [:]

    func normallyUnmount(_ expected: MountedFileSystem) throws {
        guard expected.type == "nfs", expected.ownerID == 0,
              expected.mountPoint.hasPrefix(PrivilegedMountConfiguration.namespace + "/\(geteuid())/"),
              MountedFileSystemReader.read(path: expected.mountPoint) == expected else {
            throw DiskOperationError(message: "受管网络卷的挂载身份已变化，已停止卸载。")
        }
        // Disk Arbitration performs the normal unmount in the front user's session.
        // No force flag and no background Full Disk Access permission are used.
        _ = try HelperCommand.run("/usr/sbin/diskutil", ["unmount", expected.mountPoint])
        guard MountedFileSystemReader.read(path: expected.mountPoint) == nil else {
            throw DiskOperationError(message: "系统仍报告挂载，尚未确认卸载完成。")
        }
    }

    func snapshot(_ receipts: [PrivilegedMountResult]) throws -> [CompatVolume] {
        let data = try HelperCommand.run("/usr/sbin/diskutil", ["list", "-plist"])
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ids = list["AllDisks"] as? [String] else { throw DiskOperationError(message: "无法读取磁盘清单。") }
        var result: [CompatVolume] = []
        for id in ids where VolumeRecord.validDeviceID(id) {
            result.append(try read(id, receipts: receipts))
        }
        let current = Set(result.compactMap { $0.record.mediaRegistryID })
        bindings = bindings.filter { current.contains($0.key) }
        return result
    }

    func read(_ id: String, receipts: [PrivilegedMountResult]) throws -> CompatVolume {
        guard VolumeRecord.validDeviceID(id) else { throw DiskOperationError(message: "设备标识无效。") }
        let data = try HelperCommand.run("/usr/sbin/diskutil", ["info", "-plist", id])
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let initial = VolumeRecord(info: info) else {
            throw DiskOperationError(message: "无法解析磁盘身份。")
        }
        // Internal/unknown devices remain in the complete snapshot for protection checks,
        // but never pass through the external-media operation binding.
        if initial.isInternal != false { return CompatVolume(record: initial, receipt: nil) }
        guard let session,
              let binding = RetainedDiskBinding(session: session, expected: initial) else {
            throw DiskOperationError(message: "无法完整确认磁盘身份，请刷新后重试。")
        }
        bindings[binding.mediaRegistryID] = binding
        let receipt = receipts.first { $0.deviceID == id && $0.mediaRegistryID == binding.mediaRegistryID
            && $0.wholeMediaRegistryID == binding.wholeMediaRegistryID }
        var mounted = (info["MountPoint"] as? String).flatMap { MountedFileSystemReader.read(path: $0) }
        if let receipt {
            guard PrivilegedMountConfiguration.token(mountPoint: receipt.mountPoint, userID: geteuid()) == receipt.token,
                  let actual = MountedFileSystemReader.read(path: receipt.mountPoint), actual.type == "nfs",
                  actual.ownerID == 0, actual.identity == receipt.fileSystemIdentity,
                  actual.isReadOnly == receipt.readOnly else {
                throw DiskOperationError(message: "受管挂载实例已经变化，请停止磁盘操作并重新查询。")
            }
            info["MountPoint"] = receipt.mountPoint
            mounted = actual
        }
        guard let record = VolumeRecord(info: info, mediaRegistryID: binding.mediaRegistryID,
            wholeMediaRegistryID: binding.wholeMediaRegistryID, mountedFileSystem: mounted) else {
            throw DiskOperationError(message: "无法解析磁盘身份。")
        }
        try binding.validateMediaIdentity(record)
        return CompatVolume(record: record, receipt: receipt)
    }
}
