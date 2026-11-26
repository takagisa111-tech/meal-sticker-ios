import Foundation
import SwiftUI
import UIKit
import Security
import WidgetKit

@MainActor
final class Store: ObservableObject {
    @Published var meals: [Meal] = [] { didSet { scheduleSave() } }
    @Published var days: [String: DayLog] = [:] { didSet { scheduleSave() } }
    @Published var settings = AppSettings() { didSet { scheduleSave(); if settings != oldValue { refreshReminders() } } }
    @Published var reports: [String: WeekReport] = [:] { didSet { scheduleSave() } }
    @Published var toast: String?
    @Published var openAdd = false

    private var saveTask: Task<Void, Never>?
    private var loading = true
    private var imageCache: [String: UIImage] = [:]

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var dataURL: URL { docs.appendingPathComponent("shitie.json") }
    private var stickerDir: URL { docs.appendingPathComponent("stickers", isDirectory: true) }

    init() {
        try? FileManager.default.createDirectory(at: stickerDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dataURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            if let f = try? dec.decode(SaveFile.self, from: data) {
                meals = f.meals; days = f.days; settings = f.settings; reports = f.reports
            } else {
                // 读不出来时先把原文件备份，绝不直接覆盖用户数据
                let stamp = Int(Date().timeIntervalSince1970)
                try? data.write(to: docs.appendingPathComponent("shitie-backup-\(stamp).json"))
            }
        }
        // 迁移：旧版只有「我」，从旧档案生成成员列表
        if settings.members == nil || settings.members?.isEmpty == true {
            settings.members = [Member.makeMe(from: settings.profile, reminders: settings.reminders)]
        }
        if settings.currentMember == nil || !(settings.members ?? []).contains(where: { $0.id == settings.currentMember }) {
            settings.currentMember = "me"
        }
        loading = false
    }

    // MARK: 保存

    private func scheduleSave() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let f = SaveFile(meals: meals, days: days, settings: settings, reports: reports)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(f) { try? data.write(to: dataURL, options: .atomic) }
        writeWidget()
    }

    // MARK: 成员

    var members: [Member] { settings.members ?? [] }
    var currentID: String { settings.currentMember ?? "me" }
    var member: Member { members.first { $0.id == currentID } ?? members.first ?? Member.makeMe(from: settings.profile, reminders: settings.reminders) }
    var kind: MemberKind { member.kind }

    func member(_ id: String?) -> Member? { members.first { $0.id == (id ?? "me") } }

    func switchTo(_ id: String) {
        guard id != currentID else { return }
        settings.currentMember = id
    }

    func updateMember(_ id: String, _ change: (inout Member) -> Void) {
        guard var list = settings.members, let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        settings.members = list
    }

    func addMember(_ m: Member) {
        var list = members
        list.append(m)
        settings.members = list
        settings.currentMember = m.id
    }

    func removeMember(_ id: String) {
        guard id != "me" else { return }
        for m in meals where m.memberID == id {
            try? FileManager.default.removeItem(at: stickerDir.appendingPathComponent(m.sticker))
        }
        meals.removeAll { $0.memberID == id }
        days = days.filter { !$0.key.hasPrefix(id + "|") }
        reports = reports.filter { !$0.key.hasPrefix(id + "|") }
        settings.members = members.filter { $0.id != id }
        if currentID == id { settings.currentMember = "me" }
    }

    private func owns(_ m: Meal, _ id: String) -> Bool { (m.memberID ?? "me") == id }

    // MARK: 桌面小组件（显示「我」）

    private var lastWidget: WidgetSnapshot?

    func writeWidget() {
        guard let dir = SharedBox.dir else { return }
        let today = D.today
        let me = member("me") ?? member
        let ms = meals(on: today, member: me.id).sorted { $0.z > $1.z }
        var names: [String] = []
        for (i, m) in ms.prefix(4).enumerated() {
            let name = "w\(i)-\(m.sticker)"
            names.append(name)
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path), let img = image(m.sticker) {
                let small = StickerMaker.normalized(img, maxSide: 220)
                try? small.pngData()?.write(to: url)
            }
        }
        let recorded = Set(ms.map(\.slot))
        let snap = WidgetSnapshot(
            date: today, kcal: Int(ms.reduce(0) { $0 + $1.kcal }), target: me.kcalTarget, count: ms.count, stickers: names,
            slots: MealSlot.mains.map { WidgetSlot(name: $0.name, emoji: $0.emoji, minutes: me.reminders.minutes(for: $0), recorded: recorded.contains($0)) },
            water: day(today, member: me.id).water, waterGoal: settings.waterGoal,
            tip: Nutrition.tips(meals: meals(in: D.weekDates(offset: 0), member: me.id), member: me, dates: D.weekDates(offset: 0)).first.map { "\($0.emoji) \($0.title)" } ?? ""
        )
        guard snap != lastWidget else { return }
        lastWidget = snap
        if let d = try? JSONEncoder().encode(snap), let u = SharedBox.snapshotURL { try? d.write(to: u, options: .atomic) }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("w") && f.hasSuffix(".png") && !names.contains(f) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: 图片

    func saveSticker(_ img: UIImage, prefix: String = "") -> String {
        let name = prefix + UUID().uuidString + ".png"
        if let data = img.pngData() { try? data.write(to: stickerDir.appendingPathComponent(name)) }
        imageCache[name] = img
        return name
    }

    func image(_ name: String) -> UIImage? {
        if let i = imageCache[name] { return i }
        guard let i = UIImage(contentsOfFile: stickerDir.appendingPathComponent(name).path) else { return nil }
        imageCache[name] = i
        return i
    }

    /// 手账背景图（存为 JPEG，替换旧的）
    func setPaperImage(_ img: UIImage, for id: String) {
        let small = StickerMaker.normalized(img, maxSide: 1600)
        let name = "paper-" + UUID().uuidString + ".jpg"
        if let d = small.jpegData(compressionQuality: 0.85) { try? d.write(to: stickerDir.appendingPathComponent(name)) }
        imageCache[name] = small
        if let old = member(id)?.paperImage { try? FileManager.default.removeItem(at: stickerDir.appendingPathComponent(old)); imageCache[old] = nil }
        updateMember(id) { $0.paperImage = name; $0.paper = .custom }
    }

    // MARK: 餐食（默认针对当前成员）

    func meals(on date: String, member id: String? = nil) -> [Meal] {
        let who = id ?? currentID
        return meals.filter { $0.date == date && owns($0, who) }.sorted { $0.createdAt < $1.createdAt }
    }

    func meals(in dates: [String], member id: String? = nil) -> [Meal] {
        let set = Set(dates), who = id ?? currentID
        return meals.filter { set.contains($0.date) && owns($0, who) }
    }

    func meal(_ id: String) -> Meal? { meals.first { $0.id == id } }

    func update(_ id: String, _ change: (inout Meal) -> Void) {
        guard let i = meals.firstIndex(where: { $0.id == id }) else { return }
        var m = meals[i]
        change(&m)
        meals[i] = m
    }

    @discardableResult
    func addMeal(date: String, slot: MealSlot, sticker: UIImage, note: String = "", title: String = "", emoji: String = "", fromText: Bool = false) -> Meal {
        let existing = meals(on: date)
        let same = existing.filter { $0.slot == slot }.count
        let p = slot.defaultPos
        let isToday = date == D.today
        var m = Meal(
            date: date, slot: slot,
            time: isToday ? D.nowHM() : D.hm(member.reminders.minutes(for: slot)),
            sticker: saveSticker(sticker),
            x: min(0.86, max(0.14, p.x + Double(same) * 0.07 + Double.random(in: -0.03...0.03))),
            y: min(0.88, max(0.26, p.y + Double(same) * 0.05 + Double.random(in: -0.025...0.025))),
            rot: Double.random(in: -8...8), scale: Double.random(in: 0.34...0.38),
            z: (existing.map(\.z).max() ?? 0) + 1,
            title: title, emoji: emoji, note: note, fromText: fromText
        )
        m.memberID = currentID == "me" ? nil : currentID
        meals.append(m)
        refreshReminders()
        return m
    }

    /// 常吃的：按名字合并当前成员的历史记录
    var reuseCandidates: [ReuseItem] {
        var groups: [String: (Meal, Int)] = [:]
        for m in meals where owns(m, currentID) && m.status == .done && !m.title.isEmpty {
            if let g = groups[m.title] {
                groups[m.title] = (m.createdAt > g.0.createdAt ? m : g.0, g.1 + 1)
            } else {
                groups[m.title] = (m, 1)
            }
        }
        return groups.values
            .sorted { $0.1 == $1.1 ? $0.0.createdAt > $1.0.createdAt : $0.1 > $1.1 }
            .prefix(30)
            .map { ReuseItem(meal: $0.0, count: $0.1) }
    }

    @discardableResult
    func duplicate(_ src: Meal, date: String, slot: MealSlot) -> Meal? {
        guard let img = image(src.sticker) else { return nil }
        var m = addMeal(date: date, slot: slot, sticker: img, title: src.title, emoji: src.emoji, fromText: src.fromText)
        update(m.id) { n in
            n.status = src.status; n.foods = src.foods; n.kcal = src.kcal; n.protein = src.protein; n.carbs = src.carbs
            n.fat = src.fat; n.fiber = src.fiber; n.flags = src.flags; n.comment = src.comment
            n.cuisine = src.cuisine; n.methods = src.methods; n.shop = src.shop; n.danger = src.danger; n.source = "reuse"
        }
        m = meal(m.id) ?? m
        refreshReminders()
        return m
    }

    func delete(_ id: String) {
        if let m = meal(id) {
            try? FileManager.default.removeItem(at: stickerDir.appendingPathComponent(m.sticker))
            imageCache[m.sticker] = nil
        }
        meals.removeAll { $0.id == id }
        refreshReminders()
    }

    // MARK: 每日（喝水、心情、小记）

    private func dayKey(_ d: String, _ id: String) -> String { id == "me" ? d : id + "|" + d }
    func day(_ d: String, member id: String? = nil) -> DayLog { days[dayKey(d, id ?? currentID)] ?? DayLog() }
    func setDay(_ d: String, _ change: (inout DayLog) -> Void) {
        var v = day(d); change(&v); days[dayKey(d, currentID)] = v
    }

    var streak: Int {
        let has = Set(meals.filter { owns($0, currentID) }.map(\.date))
        var d = D.today
        if !has.contains(d) { d = D.add(d, -1) }
        var n = 0
        while has.contains(d) { n += 1; d = D.add(d, -1) }
        return n
    }

    // MARK: 周报

    func reportKey(_ week: String) -> String { currentID == "me" ? week : currentID + "|" + week }
    func report(_ week: String) -> WeekReport? { reports[reportKey(week)] }
    func setReport(_ r: WeekReport, week: String) { reports[reportKey(week)] = r }

    // MARK: 当前成员的快捷属性

    var kcalTarget: Int { member.kcalTarget }
    var profileText: String { member.profileText }

    // MARK: API Key

    var apiKey: String {
        get { Keychain.get("deepseek") ?? Secrets.deepSeekKey }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { Keychain.delete("deepseek") } else { Keychain.set("deepseek", v) }
            objectWillChange.send()
        }
    }

    // MARK: 提醒（所有成员）

    func refreshReminders() {
        guard !loading else { return }
        let week = D.weekDates(offset: 0)
        let plans = members.map { m -> ReminderPlan in
            let tips = Nutrition.tips(meals: meals(in: week, member: m.id), member: m, dates: week)
            return ReminderPlan(member: m, recordedToday: Set(meals(on: D.today, member: m.id).map(\.slot)),
                                tips: tips.map { "\($0.emoji) \($0.title)，\($0.detail)" })
        }
        Reminders.reschedule(plans)
    }

    func flash(_ msg: String) {
        toast = msg
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self?.toast == msg { self?.toast = nil }
        }
    }

    // MARK: AI 识别（按这一餐所属的成员分析）

    func analyze(_ id: String, image: UIImage?, text: String? = nil, takeout: Bool = false) async {
        guard let m0 = meal(id) else { return }
        let who = member(m0.memberID) ?? member
        let extra = [text, m0.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
        if image == nil && extra.isEmpty { update(id) { $0.status = .none }; return }
        update(id) { $0.status = .pending }
        do {
            let r = try await AI.analyzeMeal(meal: m0, image: image, text: extra, member: who, key: apiKey, takeout: takeout)
            let newSticker: String? = takeout ? saveSticker(StickerMaker.emojiSticker(r.emoji.isEmpty ? "🛵" : r.emoji)) : nil
            if let ns = newSticker, let old = meal(id)?.sticker {
                try? FileManager.default.removeItem(at: stickerDir.appendingPathComponent(old))
                imageCache[old] = nil
            }
            update(id) { m in
                if let ns = newSticker { m.sticker = ns }
                m.status = .done
                if !r.title.isEmpty { m.title = r.title }
                if !r.emoji.isEmpty { m.emoji = r.emoji }
                m.foods = r.foods; m.kcal = r.kcal; m.protein = r.protein; m.carbs = r.carbs
                m.fat = r.fat; m.fiber = r.fiber; m.flags = r.flags; m.comment = r.comment
                if !r.cuisine.isEmpty { m.cuisine = r.cuisine }
                if !r.methods.isEmpty { m.methods = r.methods }
                if !r.shop.isEmpty { m.shop = r.shop }
                m.danger = r.danger.isEmpty ? nil : r.danger
            }
            if !r.danger.isEmpty { flash("⚠️ " + r.danger) }
            refreshReminders()
        } catch {
            update(id) { $0.status = .error }
            flash((error as? AIError)?.message ?? "识别失败：\(error.localizedDescription)")
        }
    }
}

struct ReuseItem: Identifiable {
    let meal: Meal
    let count: Int
    var id: String { meal.id }
}

// MARK: - Keychain

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "shitie", kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
