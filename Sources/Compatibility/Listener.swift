import Foundation
import Darwin

private final class PrivilegedMountEndpoint: NSObject, PrivilegedMountProtocol, @unchecked Sendable {
    let userID: UInt32
    let engine: CompatMountEngine

    init(userID: UInt32, engine: CompatMountEngine) {
        self.userID = userID
        self.engine = engine
    }

    func mount(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        engine.queue.async {
            do { reply(try self.engine.mount(request, userID: self.userID), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func unmount(_ token: String, handle: FileHandle, withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            // XPC 传输的描述符由接收端独立拥有；强持有到操作结束，再且仅关闭一次。
            defer { try? handle.close() }
            do { try self.engine.unmount(token, handle: handle, userID: self.userID); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func prepareUnmount(_ token: String, handle: FileHandle, withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            defer { try? handle.close() }
            do { try self.engine.prepareUnmount(token, handle: handle, userID: self.userID); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func finishUnmount(_ token: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            do { try self.engine.finishUnmount(token, userID: self.userID); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func mountedVolumes(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        engine.queue.async {
            do { reply(try self.engine.mountedVolumes(userID: self.userID), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func prepareEject(_ request: Data, handles: [FileHandle], withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            let error: String? = {
                // 先完成正常卸载并关闭接收端根句柄，再允许前台开始原始设备授权。
                defer { for handle in handles { try? handle.close() } }
                do { try self.engine.prepareEject(request, handles: handles, userID: self.userID); return nil }
                catch { return error.localizedDescription }
            }()
            reply(error)
        }
    }


}

final class PrivilegedMountListener: NSObject, NSXPCListenerDelegate {
    private let engine = CompatMountEngine()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard geteuid() == 0, connection.effectiveUserIdentifier >= 501,
              connection.effectiveUserIdentifier != UInt32.max else { return false }
        // 系统在每条消息上验证签名；不根据可能复用的 PID 查询客户端身份。
        connection.setCodeSigningRequirement(PrivilegedMountConfiguration.clientRequirement)
        let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
        interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
            for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
        connection.exportedInterface = interface
        connection.exportedObject = PrivilegedMountEndpoint(userID: connection.effectiveUserIdentifier, engine: engine)
        connection.resume()
        return true
    }
}
