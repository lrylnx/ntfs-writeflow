import Foundation
import Darwin

final class CompatMountEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.ntfswriteflow.compat.operations")
    private var children: [String: (process: Process, diagnostic: DriverDiagnostic)] = [:]

    func mount(_ data: Data, userID: UInt32) throws -> Data {
        guard data.count <= 4096, Compatibility.componentInstalled else {
            throw HelperFailure(message: "请先安装 FUSE-T 1.2.9 组件，然后重试。")
        }
        let request = try JSONDecoder().decode(PrivilegedMountRequest.self, from: data)
        let media = try HelperMedia(request)
        guard media.volume.mountPoint == nil, request.readOnly || media.volume.writableMedia == true,
              try !allMountedTickets().contains(where: { $0.request.mediaRegistryID == request.mediaRegistryID }) else {
            throw HelperFailure(message: "该卷已经挂载、被其他用户使用或未确认可写。请先通过原工具正常卸载。")
        }
        let namespace = try HelperNamespace(userID: userID)
        var ticket = try namespace.create(request)
        let path = try namespace.mountPoint(ticket.token)
        var executableSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &executableSize)
        var executablePath = [CChar](repeating: 0, count: Int(executableSize))
        guard _NSGetExecutablePath(&executablePath, &executableSize) == 0 else {
            throw HelperFailure(message: "无法定位已签名的挂载引擎。")
        }
        let executable = URL(fileURLWithPath: String(cString: executablePath)).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("WriteFlowNTFS").path
        do {
            try HelperCommand.verifyCode(executable, identifier: "local.ntfswriteflow.compat.engine")
            try Self.verifyRootComponent(Compatibility.fuseLibrary)
            try Self.verifyRootComponent(Compatibility.fuseServer)
            try media.validate(request)
            let child = Process()
            let diagnostic = DriverDiagnostic()
            child.executableURL = URL(fileURLWithPath: executable)
            // NTFS-3G's Unix I/O performs small metadata reads. Darwin's buffered
            // block device supports them; the raw character device rejects unaligned I/O.
            child.arguments = ["/dev/\(request.deviceID)", path, "-o",
                "\(request.readOnly ? "ro" : "rw"),no_detach,backend=nfs,norecover,nosuid,nodev,uid=\(userID),gid=\(getpwuid(userID)?.pointee.pw_gid ?? 20),umask=077,volname=NTFS-WriteFlow"]
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin", "LANG": "en_US.UTF-8",
                "HOME": "/var/root", "WRITEFLOW_MEDIA_ID": String(request.mediaRegistryID),
                "WRITEFLOW_MEDIA_BYTES": String(request.mediaByteCount)]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = diagnostic.pipe
            try child.run()
            children[ticket.token] = (child, diagnostic)
            for _ in 0..<300 {
                try media.validate(request)
                if let mounted = MountedFileSystemReader.read(path: path) {
                    ticket.fileSystemIdentity = mounted.identity
                    guard Compatibility.isOwnedMount(mounted, ticket: ticket) else {
                        throw HelperFailure(message: "挂载实例或来源核验失败，未报告挂载成功。")
                    }
                    try namespace.save(ticket)
                    guard mounted.isReadOnly == request.readOnly else {
                        throw HelperFailure(message: "实际读写模式与请求不一致，请正常卸载此卷后检查。")
                    }
                    return try JSONEncoder().encode(result(ticket, mounted: mounted))
                }
                guard child.isRunning else {
                    throw HelperFailure(message: "NTFS 引擎未能挂载（退出码 \(child.terminationStatus)）。不会强制恢复或删除休眠文件。\n\(diagnostic.text)")
                }
                usleep(100_000)
            }
            throw HelperFailure(message: "挂载等待超时。请刷新确认实际状态，勿重复提交或拔盘。")
        } catch {
            if MountedFileSystemReader.read(path: path) == nil {
                if let child = children[ticket.token]?.process, child.isRunning { child.terminate() }
                children.removeValue(forKey: ticket.token)
                try? namespace.discardUnmounted(ticket.token)
            }
            throw error
        }
    }

    func mountedVolumes(userID: UInt32) throws -> Data {
        let namespace = try HelperNamespace(userID: userID)
        let results = try namespace.tokens().compactMap { token -> PrivilegedMountResult? in
            let path = try namespace.mountPoint(token)
            guard MountedFileSystemReader.read(path: path) != nil else {
                if self.children[token]?.process.isRunning != true {
                    try? namespace.discardUnmounted(token)
                    self.children.removeValue(forKey: token)
                }
                return nil
            }
            let ticket = try namespace.load(token)
            return try result(ticket, mounted: verified(ticket, namespace: namespace))
        }
        return try JSONEncoder().encode(results)
    }

    func unmount(_ token: String, handle: FileHandle, userID: UInt32) throws {
        throw HelperFailure(message: "请使用与助手版本一致的兼容版，通过系统正常卸载。")
    }

    func prepareUnmount(_ token: String, handle: FileHandle, userID: UInt32) throws {
        let namespace = try HelperNamespace(userID: userID)
        let ticket = try namespace.load(token)
        let mounted = try verified(ticket, namespace: namespace)
        let descriptor = handle.fileDescriptor
        var status = stat(), path = [CChar](repeating: 0, count: Int(PATH_MAX))
        let flags = fcntl(descriptor, F_GETFL)
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              flags >= 0, flags & O_EVTONLY != 0,
              fcntl(descriptor, F_GETPATH, &path) == 0,
              String(cString: path) == mounted.mountPoint,
              MountedFileSystemReader.read(descriptor: descriptor) == mounted else {
            throw HelperFailure(message: "卸载句柄不是原挂载根目录，已停止操作。")
        }
        guard mounted.isReadOnly || fsync(descriptor) == 0 else {
            throw HelperFailure(message: "同步失败（\(errno)），请勿拔盘。")
        }
    }

    func finishUnmount(_ token: String, userID: UInt32) throws {
        let namespace = try HelperNamespace(userID: userID)
        _ = try namespace.load(token)
        let path = try namespace.mountPoint(token)
        guard MountedFileSystemReader.read(path: path) == nil else {
            throw HelperFailure(message: "仍有挂载，尚未确认卸载完成。")
        }
        if let child = children[token]?.process {
            for _ in 0..<50 where child.isRunning { usleep(100_000) }
            guard !child.isRunning else { throw HelperFailure(message: "卷已卸载，引擎仍在收尾；暂勿拔盘，请稍后刷新。") }
            children.removeValue(forKey: token)
        }
        try namespace.discardUnmounted(token)
    }

    func prepareEject(_ data: Data, handles: [FileHandle], userID: UInt32) throws {
        guard data.count <= 4096, handles.isEmpty else { throw HelperFailure(message: "兼容版要求先正常卸载同盘所有卷。") }
        let request = try JSONDecoder().decode(PrivilegedEjectRequest.self, from: data)
        guard try !allMountedTickets().contains(where: { $0.request.wholeMediaRegistryID == request.wholeMediaRegistryID }) else {
            throw HelperFailure(message: "同盘仍有兼容版挂载，请先逐个正常卸载。")
        }
        let eject = try HelperEject(request: request, userID: userID)
        try eject.validateIdentity()
        guard try eject.relatedMounts().isEmpty else { throw HelperFailure(message: "同盘还有其他挂载，请先通过原工具正常卸载全部分卷。") }
    }

    private func verified(_ ticket: HelperTicket, namespace: HelperNamespace) throws -> MountedFileSystem {
        try HelperMedia(ticket.request).validate(ticket.request)
        let path = try namespace.mountPoint(ticket.token)
        guard let mount = MountedFileSystemReader.read(path: path), Compatibility.isOwnedMount(mount, ticket: ticket) else {
            throw HelperFailure(message: "原介质或受管挂载的身份已变化，请停止操作并检查磁盘。")
        }
        return mount
    }

    private func result(_ ticket: HelperTicket, mounted: MountedFileSystem) -> PrivilegedMountResult {
        PrivilegedMountResult(token: ticket.token, mountPoint: mounted.mountPoint, deviceID: ticket.request.deviceID,
            mediaRegistryID: ticket.request.mediaRegistryID, wholeMediaRegistryID: ticket.request.wholeMediaRegistryID,
            fileSystemIdentity: mounted.identity, readOnly: mounted.isReadOnly)
    }

    private func allMountedTickets() throws -> [HelperTicket] {
        guard FileManager.default.fileExists(atPath: PrivilegedMountConfiguration.namespace) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: PrivilegedMountConfiguration.namespace).flatMap { name -> [HelperTicket] in
            guard let userID = UInt32(name), userID >= 501, userID != UInt32.max else {
                throw HelperFailure(message: "挂载记录目录异常，已停止操作。")
            }
            let namespace = try HelperNamespace(userID: userID)
            return try namespace.tokens().compactMap { token in
                guard let mounted = MountedFileSystemReader.read(path: try namespace.mountPoint(token)) else { return nil }
                let ticket = try namespace.load(token)
                guard Compatibility.isOwnedMount(mounted, ticket: ticket) else { throw HelperFailure(message: "存在无法确认身份的挂载，请先检查。") }
                return ticket
            }
        }
    }

    private static func verifyRootComponent(_ path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var component = resolved
        while component != "/" {
            var info = stat()
            guard lstat(component, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                throw HelperFailure(message: "FUSE-T 的安装路径或权限不正确，请使用官方安装包重新安装。")
            }
            component = URL(fileURLWithPath: component).deletingLastPathComponent().path
        }
    }
}

// Consume stderr for the entire driver's lifetime so diagnostic output cannot fill
// a pipe or cause SIGPIPE after mount() returns. Only a bounded local error is kept.
private final class DriverDiagnostic: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.data.append(chunk)
                if self.data.count > 4096 { self.data.removeFirst(self.data.count - 4096) }
            }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
    deinit { pipe.fileHandleForReading.readabilityHandler = nil }
}
