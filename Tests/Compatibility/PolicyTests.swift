import Foundation

@main enum CompatibilityPolicyTests {
    static func main() {
        let token = "A0000000-0000-0000-0000-000000000001"
        let request = PrivilegedMountRequest(deviceID: "disk9s1", mediaRegistryID: 12,
            wholeMediaRegistryID: 10, mediaByteCount: 1024, readOnly: false)
        let ticket = HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: "4:5")
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        func mount(type: String = "nfs", source: String = "127.0.0.1:/volume", path: String? = nil,
                   fsid: String = "4:5", owner: UInt32 = 0) -> MountedFileSystem {
            MountedFileSystem(type: type, source: source, mountPoint: path ?? ticketPath,
                identity: fsid, ownerID: owner, isReadOnly: false)
        }
        let ticketPath = path
        for source in ["127.0.0.1:/volume", "localhost:/volume", "[::1]:/volume", "fuse-t:/volume"] {
            check(Compatibility.isOwnedMount(mount(source: source), ticket: ticket))
        }
        for source in ["192.168.1.2:/volume", "127.0.0.1.evil:/volume", "localhost.evil:/volume", "/dev/disk9s1"] {
            check(!Compatibility.isOwnedMount(mount(source: source), ticket: ticket))
        }
        check(!Compatibility.isOwnedMount(mount(type: "apfs"), ticket: ticket))
        check(!Compatibility.isOwnedMount(mount(fsid: "4:6"), ticket: ticket))
        check(!Compatibility.isOwnedMount(mount(owner: 502), ticket: ticket))
        check(!Compatibility.isOwnedMount(mount(path: path + "/child"), ticket: ticket))
        check(!Compatibility.isOwnedMount(mount(path: path.replacingOccurrences(of: "/501/", with: "/502/")), ticket: ticket))
        let unbound = HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: nil)
        check(!Compatibility.isOwnedMount(mount(), ticket: unbound))
        check(PrivilegedMountConfiguration.token(mountPoint: path, userID: 501) == token)
        check(PrivilegedMountConfiguration.token(mountPoint: path, userID: 502) == nil)
        check(PrivilegedMountConfiguration.token(mountPoint: path + "/..", userID: 501) == nil)
        check(PrivilegedMountConfiguration.token(mountPoint: path.replacingOccurrences(of: token, with: "../../etc"), userID: 501) == nil)
        print("通过：\(count) 项兼容挂载归属与路径边界检查；未访问磁盘内容。")
    }
}
