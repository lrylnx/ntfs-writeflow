import Foundation
import Darwin
import Security
import CryptoKit

struct DiskOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Compatibility {
    static let installedHelperRoot = "/Library/PrivilegedHelperTools/local.ntfswriteflow.compat"
    static let fuseLibrary = "/usr/local/lib/libfuse-t.dylib"
    static let fuseServer = "/usr/local/bin/go-nfsv4"
    static let installerURL = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.9/fuse-t-macos-installer-1.2.9.pkg")!
    static var bundledInstaller: URL? {
        guard let url = Bundle.main.url(forResource: "fuse-t-macos-installer-1.2.9", withExtension: "pkg"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hash == "a1b893740ded8ea034f1acc522ded1144f4a567a1f416daef8c1441cf2662f7f" ? url : nil
    }
    static var componentInstalled: Bool {
        FileManager.default.fileExists(atPath: fuseLibrary)
            && FileManager.default.isExecutableFile(atPath: fuseServer)
    }

    static func servicePackage(removal: Bool = false) -> URL? {
        let name = removal ? "WriteFlow-Remove-Service" : "WriteFlow-Install-Service"
        guard let package = Bundle.main.url(forResource: name, withExtension: "pkg"),
              let checksum = Bundle.main.url(forResource: name, withExtension: "sha256"),
              let expected = try? String(contentsOf: checksum).trimmingCharacters(in: .whitespacesAndNewlines),
              let data = try? Data(contentsOf: package, options: .mappedIfSafe) else { return nil }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected ? package : nil
    }

    static var installedHelperBuild: String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: installedHelperRoot + "/version.json")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              FileManager.default.isExecutableFile(atPath: installedHelperRoot + "/WriteFlowCompatHelper") else { return nil }
        return info["build"]
    }

    static func hasManagedMounts() throws -> Bool {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { throw HelperFailure(message: "无法核对系统挂载清单，保留管理员服务。") }
        defer { free(entries) }
        for index in 0..<Int(count) {
            var value = entries[index].f_mntonname
            let path = withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix(PrivilegedMountConfiguration.namespace + "/") { return true }
        }
        return false
    }

    static func isOwnedMount(_ mount: MountedFileSystem, ticket: HelperTicket) -> Bool {
        // A local NFS volume is ours only when a root-owned receipt binds its fsid.
        mount.type == "nfs" && mount.ownerID == 0
            && mount.mountPoint == PrivilegedMountConfiguration.namespace + "/\(ticket.userID)/\(ticket.token)/volume"
            && (mount.source.hasPrefix("127.0.0.1:") || mount.source.hasPrefix("localhost:") || mount.source.hasPrefix("[::1]:") || mount.source.hasPrefix("fuse-t:"))
            && ticket.fileSystemIdentity == mount.identity
    }
}

enum HelperCommand {
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw HelperFailure(message: "系统操作未完成：\(String(decoding: data.prefix(1200), as: UTF8.self))")
        }
        return data
    }

    static func verifyCode(_ path: String, identifier: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "identifier \"\(identifier)\" and certificate leaf = H\"1DDCB3B175991894FC207A24F0B13D5C41F502B6\""
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw HelperFailure(message: "挂载引擎的固定签名验证失败，请重新构建或安装兼容版。")
        }
    }
}
