import Foundation

/// 主 App 和桌面小组件共享的数据（通过 App Group 文件夹）
struct WidgetSlot: Codable, Hashable {
    var name: String
    var emoji: String
    var minutes: Int
    var recorded: Bool
}

struct WidgetSnapshot: Codable, Equatable {
    var date: String
    var kcal: Int
    var target: Int
    var count: Int
    var stickers: [String]
    var slots: [WidgetSlot]
    var water: Int
    var waterGoal: Int
    var tip: String
}

enum SharedBox {
    static let group = "group.com.huangshitie.mealsticker"
    static var dir: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var snapshotURL: URL? { dir?.appendingPathComponent("widget.json") }

    static func read() -> WidgetSnapshot? {
        guard let u = snapshotURL, let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
}
