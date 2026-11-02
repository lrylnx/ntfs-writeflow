import Foundation

@main enum InventoryProbe {
    static func main() async throws {
        let values = try await CompatInventory().snapshot([])
        print("只读清单验证通过：\(values.count) 个设备；外接 NTFS \(values.filter { $0.record.isNTFS && $0.record.isInternal == false }.count) 个。未读取文件内容或提交磁盘修改。")
    }
}
