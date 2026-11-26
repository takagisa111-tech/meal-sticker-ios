import Foundation
import SwiftUI
import UIKit

// MARK: - 餐次

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }

    var name: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        }
    }

    var emoji: String {
        switch self {
        case .breakfast: return "🌅"
        case .lunch: return "☀️"
        case .dinner: return "🌙"
        case .snack: return "🍪"
        }
    }

    var symbol: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch: return "sun.max"
        case .dinner: return "moon"
        case .snack: return "cup.and.saucer"
        }
    }

    /// 贴纸默认放在手账页上的位置（相对比例）
    var defaultPos: CGPoint {
        switch self {
        case .breakfast: return CGPoint(x: 0.28, y: 0.34)
        case .lunch: return CGPoint(x: 0.72, y: 0.38)
        case .dinner: return CGPoint(x: 0.30, y: 0.70)
        case .snack: return CGPoint(x: 0.72, y: 0.74)
        }
    }

    static var mains: [MealSlot] { [.breakfast, .lunch, .dinner] }

    static func guess(for date: Date = Date()) -> MealSlot {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        if h < 10.5 { return .breakfast }
        if h < 15 { return .lunch }
        if h < 17 { return .snack }
        if h < 21.5 { return .dinner }
        return .snack
    }
}

// MARK: - 食物分组（参考《中国居民膳食指南(2022)》）

enum FoodGroup: String, Codable, CaseIterable {
    case grain, whole_grain, tuber, veg, dark_veg, fruit, meat, seafood, egg, dairy, soy_nut, sweet, other
    // 宠物
    case kibble, wetfood, treat, human

    var name: String {
        switch self {
        case .grain: return "精制谷物"
        case .whole_grain: return "全谷杂豆"
        case .tuber: return "薯类"
        case .veg: return "浅色蔬菜"
        case .dark_veg: return "深色蔬菜"
        case .fruit: return "水果"
        case .meat: return "畜禽肉"
        case .seafood: return "鱼虾水产"
        case .egg: return "蛋类"
        case .dairy: return "奶制品"
        case .soy_nut: return "大豆坚果"
        case .sweet: return "甜食饮料"
        case .other: return "其他"
        case .kibble: return "干粮"
        case .wetfood: return "湿粮罐头"
        case .treat: return "零食"
        case .human: return "人类食物"
        }
    }
}

struct GuideRow: Identifiable {
    let id: String
    let name: String
    let emoji: String
    let groups: [FoodGroup]
    let min: Double
    let max: Double
}

/// 每日建议摄入量（克）；谷物、杂豆按生重计
let guideRows: [GuideRow] = [
    GuideRow(id: "grains", name: "谷物", emoji: "🍚", groups: [.grain, .whole_grain], min: 200, max: 300),
    GuideRow(id: "whole", name: "全谷杂豆", emoji: "🌽", groups: [.whole_grain], min: 50, max: 150),
    GuideRow(id: "tuber", name: "薯类", emoji: "🍠", groups: [.tuber], min: 50, max: 100),
    GuideRow(id: "vegs", name: "蔬菜", emoji: "🥬", groups: [.veg, .dark_veg], min: 300, max: 500),
    GuideRow(id: "dark", name: "深色蔬菜", emoji: "🥦", groups: [.dark_veg], min: 150, max: 300),
    GuideRow(id: "fruit", name: "水果", emoji: "🍎", groups: [.fruit], min: 200, max: 350),
    GuideRow(id: "meat", name: "畜禽肉", emoji: "🍖", groups: [.meat], min: 40, max: 75),
    GuideRow(id: "sea", name: "鱼虾水产", emoji: "🐟", groups: [.seafood], min: 40, max: 75),
    GuideRow(id: "egg", name: "蛋类", emoji: "🥚", groups: [.egg], min: 40, max: 50),
    GuideRow(id: "dairy", name: "奶制品", emoji: "🥛", groups: [.dairy], min: 300, max: 500),
    GuideRow(id: "soy", name: "大豆坚果", emoji: "🫘", groups: [.soy_nut], min: 25, max: 35),
]

let flagNames: [String: String] = ["fried": "油炸", "high_salt": "重盐", "sugary": "高糖", "processed": "加工肉",
                                   "hard": "偏硬难嚼", "spicy": "辛辣", "danger": "危险食物", "fatty": "高脂"]

/// 老人：参考《中国老年人膳食指南》，蛋白质和奶要够，主食可略少
let elderRows: [GuideRow] = [
    GuideRow(id: "grains", name: "谷物", emoji: "🍚", groups: [.grain, .whole_grain], min: 200, max: 250),
    GuideRow(id: "whole", name: "全谷杂豆", emoji: "🌽", groups: [.whole_grain], min: 50, max: 100),
    GuideRow(id: "vegs", name: "蔬菜", emoji: "🥬", groups: [.veg, .dark_veg], min: 300, max: 450),
    GuideRow(id: "fruit", name: "水果", emoji: "🍎", groups: [.fruit], min: 200, max: 300),
    GuideRow(id: "protein", name: "肉蛋鱼", emoji: "🐟", groups: [.meat, .seafood, .egg], min: 120, max: 150),
    GuideRow(id: "sea", name: "鱼虾水产", emoji: "🦐", groups: [.seafood], min: 40, max: 60),
    GuideRow(id: "dairy", name: "奶制品", emoji: "🥛", groups: [.dairy], min: 300, max: 400),
    GuideRow(id: "soy", name: "大豆坚果", emoji: "🫘", groups: [.soy_nut], min: 25, max: 35),
]

// MARK: - 数据

struct FoodItem: Codable, Hashable {
    var name: String
    var grams: Double
    var group: FoodGroup
}

enum MealStatus: String, Codable {
    case none, pending, done, error
}

struct Meal: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var date: String
    var slot: MealSlot
    var time: String
    var sticker: String          // 文件名，存在 Documents/stickers
    var x: Double
    var y: Double
    var rot: Double
    var scale: Double            // 宽度占手账页宽度的比例
    var z: Int
    var title: String = ""
    var emoji: String = ""
    var note: String = ""
    var status: MealStatus = .none
    var foods: [FoodItem] = []
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var flags: [String] = []
    var comment: String = ""
    var fromText: Bool = false
    var createdAt: Date = Date()
    // v2 新增（可选字段，旧数据也能正常读取）
    var cuisine: String? = nil      // 菜系，如 川菜、粤菜、日料
    var methods: [String]? = nil    // 做法，如 炒、蒸、炸
    var source: String? = nil       // photo / text / takeout / reuse
    var shop: String? = nil         // 外卖或餐厅店名
    // v3 新增
    var memberID: String? = nil     // nil = 我自己
    var danger: String? = nil       // 宠物：危险食物说明
}

/// AI 识别时可选的菜系
let cuisineList = ["川菜", "湘菜", "粤菜", "江浙菜", "鲁菜", "东北菜", "西北菜", "云贵菜", "闽菜", "徽菜", "家常菜",
                   "日料", "韩餐", "东南亚菜", "西餐", "快餐", "轻食沙拉", "面食小吃", "火锅", "烧烤", "烘焙甜品", "其他"]
/// 「这周还没吃过」会从这里挑
let cuisineSuggest = ["粤菜", "川菜", "湘菜", "江浙菜", "日料", "韩餐", "东南亚菜", "西餐", "轻食沙拉", "火锅", "西北菜", "云贵菜"]
let cookMethods = ["蒸", "煮", "炖", "炒", "煎", "炸", "烤", "凉拌", "生食"]
let cuisineEmoji: [String: String] = [
    "川菜": "🌶️", "湘菜": "🌶️", "粤菜": "🥟", "江浙菜": "🦀", "鲁菜": "🥘", "东北菜": "🥟", "西北菜": "🍜", "云贵菜": "🍲",
    "闽菜": "🍤", "徽菜": "🍲", "家常菜": "🍚", "日料": "🍣", "韩餐": "🍱", "东南亚菜": "🍛", "西餐": "🍝", "快餐": "🍔",
    "轻食沙拉": "🥗", "面食小吃": "🍜", "火锅": "🫕", "烧烤": "🍢", "烘焙甜品": "🍰", "其他": "🍽️",
]

struct DayLog: Codable, Equatable {
    var mood: String = ""
    var note: String = ""
    var water: Int = 0
}

struct Profile: Codable, Equatable {
    var sex: String = "female"
    var age: String = ""
    var height: String = ""
    var weight: String = ""
    var activity: Double = 1.375
    var goal: String = "keep"
    var avoid: String = ""
}

struct ReminderSettings: Codable, Equatable {
    var on: Bool = true
    var breakfast: Int = 8 * 60
    var lunch: Int = 12 * 60
    var dinner: Int = 18 * 60 + 30
    var water: Bool = true
    var weekly: Bool = true

    func minutes(for slot: MealSlot) -> Int {
        switch slot {
        case .breakfast: return breakfast
        case .lunch: return lunch
        case .dinner: return dinner
        case .snack: return 15 * 60 + 30
        }
    }
}

struct AppSettings: Codable, Equatable {
    var profile = Profile()            // 旧版「我」的档案，迁移用
    var reminders = ReminderSettings() // 旧版「我」的提醒，迁移用
    var autoAI: Bool = true
    var waterGoal: Int = 8
    // v3 新增（可选，兼容旧数据）
    var members: [Member]? = nil
    var currentMember: String? = nil
}

struct ReportPlan: Codable, Hashable { var when: String; var dish: String; var emoji: String; var why: String }
struct ReportItem: Codable, Hashable { var item: String; var advice: String }
struct WeekReport: Codable, Equatable {
    var at: Date
    var mealCount: Int
    var score: Int
    var headline: String
    var good: [String]
    var missing: [ReportItem]
    var tooMuch: [ReportItem]
    var plan: [ReportPlan]
    var shopping: [String]
    var habit: String
}

struct SaveFile: Codable {
    var meals: [Meal]
    var days: [String: DayLog]
    var settings: AppSettings
    var reports: [String: WeekReport]
}

// MARK: - 日期工具

enum D {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func str(_ d: Date) -> String { fmt.string(from: d) }
    static func date(_ s: String) -> Date { fmt.date(from: s) ?? Date() }
    static var today: String { str(Date()) }
    static func add(_ s: String, _ n: Int) -> String { str(cal.date(byAdding: .day, value: n, to: date(s)) ?? Date()) }

    static func weekStart(_ s: String) -> String {
        let d = date(s)
        let wd = cal.component(.weekday, from: d) // 1 = 周日
        let back = (wd + 5) % 7
        return add(s, -back)
    }

    static func weekDates(offset: Int) -> [String] {
        let start = add(weekStart(today), offset * 7)
        return (0..<7).map { add(start, $0) }
    }

    static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
    static func weekday(_ s: String) -> String { weekdayNames[cal.component(.weekday, from: date(s)) - 1] }
    static func month(_ s: String) -> Int { cal.component(.month, from: date(s)) }
    static func day(_ s: String) -> Int { cal.component(.day, from: date(s)) }
    static func year(_ s: String) -> Int { cal.component(.year, from: date(s)) }

    static func hm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func nowHM() -> String {
        let c = cal.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    static func minutes(_ hm: String) -> Int {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }
    static var nowMinutes: Int { minutes(nowHM()) }
}

// MARK: - 颜色（墨色 + 石灰白，品牌绿只用在关键位置）

extension Color {
    static let paper = Color(red: 0.945, green: 0.941, blue: 0.925)      // 页面底色 #F1F0EC
    static let card = Color.white
    static let ink = Color(red: 0.110, green: 0.110, blue: 0.102)        // 主文字 #1C1C1A
    static let ink2 = Color(red: 0.478, green: 0.471, blue: 0.447)       // 次要文字 #7A7872
    static let ink3 = Color(red: 0.663, green: 0.655, blue: 0.627)       // 辅助文字 #A9A7A0
    static let line = Color(red: 0.890, green: 0.882, blue: 0.859)       // 细线 #E3E1DB
    static let fill = Color(red: 0.965, green: 0.961, blue: 0.945)       // 浅灰填充 #F6F5F1
    static let brand = Color(red: 0.118, green: 0.369, blue: 0.247)      // 品牌绿 #1E5E3F
    static let brandSoft = Color(red: 0.906, green: 0.937, blue: 0.914)
    static let tomato = Color(red: 0.706, green: 0.318, blue: 0.247)     // 警示砖红
    static let tomatoSoft = Color(red: 0.965, green: 0.910, blue: 0.894)
    static let matcha = Color(red: 0.118, green: 0.369, blue: 0.247)
    static let matchaSoft = Color(red: 0.906, green: 0.937, blue: 0.914)
    static let butter = Color(red: 0.788, green: 0.604, blue: 0.208)     // 碳水 / 提示 赭黄
    static let butterSoft = Color(red: 0.961, green: 0.933, blue: 0.863)
    static let sky = Color(red: 0.302, green: 0.431, blue: 0.600)        // 脂肪 灰蓝
    static let berry = Color(red: 0.663, green: 0.337, blue: 0.290)      // 蛋白质 赭红
    static let dot = Color(red: 0.855, green: 0.843, blue: 0.808)
}
