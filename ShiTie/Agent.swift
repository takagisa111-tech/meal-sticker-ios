import Foundation
import SwiftUI
import UIKit

// MARK: - 任意 JSON（卡片内容由服务器决定，App 按字段读）

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var str: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return abs(n) < 1e15 && n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }
    var num: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        default: return 0
        }
    }
    var int: Int { Int(num.rounded()) }
    var bool: Bool { if case .bool(let b) = self { return b }; return false }
    var arr: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var obj: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    var strs: [String] { arr.map(\.str).filter { !$0.isEmpty } }
    var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - 对话数据

struct AgentStep: Codable, Identifiable, Equatable {
    var id: String
    var icon: String
    var label: String
    var status: String          // running / done / error
    var detail: String = ""
    var notes: [String] = []
}

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String            // text / steps / card / action
    var text = ""
    var steps: [AgentStep] = []
    var card: JSONValue? = nil
    var action: JSONValue? = nil
    var undone = false
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var role: String            // user / assistant
    var text = ""               // 用户消息
    var images: [String] = []   // 用户附图（文件名，也作为 image_id）
    var segments: [Segment] = []
    var memo = ""               // 服务器给的隐藏备注，下一轮原样带回去
    var footer = ""
    var error: String? = nil
    var saved: [String] = []    // 已经记下的草稿 id
    var at = Date()

    /// 发给模型的文字
    var content: String {
        if role == "user" { return text }
        let t = segments.filter { $0.kind == "text" }.map(\.text).joined()
        return memo.isEmpty ? t : t + "\n" + memo
    }
}

struct MemoryItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var at = Date()
}

private struct ButlerFile: Codable {
    var messages: [ChatMessage]
    var memories: [MemoryItem]
    var fridge: [String]
}

// MARK: - 服务器设置

enum AgentConfig {
    static var url: String {
        get { UserDefaults.standard.string(forKey: "agentURL") ?? "http://localhost:8765" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agentURL") }
    }
    static var token: String {
        get { Keychain.get("agentToken") ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { Keychain.delete("agentToken") } else { Keychain.set("agentToken", v) }
        }
    }
}

/// 去掉给 App 渲染用的标记：[[R012]]、〔…〕
func cleanAgentText(_ s: String) -> String {
    var t = s.replacingOccurrences(of: #"\s?\[\[[A-Z]{1,2}\d{1,3}[a-z]?\]\]"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\s?\[\[[A-Za-z0-9]+\]\]"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"〔[^〕]*〕"#, with: "", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 管家：对话、长期记忆、冰箱

@MainActor
final class Butler: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var memories: [MemoryItem] = []
    @Published var fridge: [String] = []
    @Published var streaming = false

    private var task: Task<Void, Never>?
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var fileURL: URL { docs.appendingPathComponent("butler.json") }
    var imageDir: URL { docs.appendingPathComponent("butler", isDirectory: true) }
    private var imageCache: [String: UIImage] = [:]

    init() {
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: fileURL), let f = try? dec.decode(ButlerFile.self, from: d) {
            messages = f.messages; memories = f.memories; fridge = f.fridge
        }
        // 上次没跑完就被关掉的回复，标成中断
        for i in messages.indices where messages[i].role == "assistant" && messages[i].footer.isEmpty && messages[i].error == nil {
            if messages[i].segments.isEmpty { messages[i].error = "上次没有完成" }
            for j in messages[i].segments.indices {
                for k in messages[i].segments[j].steps.indices where messages[i].segments[j].steps[k].status == "running" {
                    messages[i].segments[j].steps[k].status = "error"
                }
            }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(ButlerFile(messages: Array(messages.suffix(200)), memories: memories, fridge: fridge)) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }

    func image(_ name: String) -> UIImage? {
        if let i = imageCache[name] { return i }
        guard let i = UIImage(contentsOfFile: imageDir.appendingPathComponent(name + ".jpg").path) else { return nil }
        imageCache[name] = i
        return i
    }

    private func saveImage(_ img: UIImage) -> String {
        let name = "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        if let d = AI.jpeg(img) {
            try? d.write(to: imageDir.appendingPathComponent(name + ".jpg"))
            imageCache[name] = UIImage(data: d)
        }
        return name
    }

    func newChat() {
        stop()
        messages = []
        save()
    }

    // MARK: 发送

    func send(_ text: String, image: UIImage?, store: Store) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streaming, !t.isEmpty || image != nil else { return }
        var u = ChatMessage(role: "user", text: t.isEmpty ? "帮我看看这张图" : t)
        if let img = image { u.images = [saveImage(img)] }
        messages.append(u)
        start(store: store)
    }

    func retry(store: Store) {
        guard !streaming, let last = messages.last else { return }
        if last.role == "assistant" { messages.removeLast() }
        guard messages.last?.role == "user" else { return }
        start(store: store)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func start(store: Store) {
        let a = ChatMessage(role: "assistant")
        let history = messages
        messages.append(a)
        streaming = true
        let body = requestBody(history: history, store: store)
        let aid = a.id
        task = Task { [weak self] in
            await self?.stream(body: body, aid: aid, store: store)
        }
    }

    private func mutate(_ id: String, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    private func stream(body: Data, aid: String, store: Store) async {
        defer {
            streaming = false
            mutate(aid) { m in
                for j in m.segments.indices {
                    for k in m.segments[j].steps.indices where m.segments[j].steps[k].status == "running" { m.segments[j].steps[k].status = "error" }
                }
            }
            save()
        }
        guard let url = URL(string: AgentConfig.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/agent") else {
            mutate(aid) { $0.error = "服务器地址不对，去右上角 ··· → 服务器设置 里改一下" }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 240)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !AgentConfig.token.isEmpty { req.setValue(AgentConfig.token, forHTTPHeaderField: "X-App-Token") }
        req.httpBody = body
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                var msg = ""
                for try await line in bytes.lines { msg += line }
                mutate(aid) { $0.error = h.statusCode == 401 ? "服务器口令不对（服务器设置 → 口令）" : "服务器出错（\(h.statusCode)）\(msg.prefix(120))" }
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                      let ev = try? JSONDecoder().decode(JSONValue.self, from: d) else { continue }
                handle(ev, aid: aid, store: store)
            }
        } catch is CancellationError {
            mutate(aid) { $0.footer = "已停止" }
        } catch let e as URLError where e.code == .cancelled {
            mutate(aid) { $0.footer = "已停止" }
        } catch {
            let tip = (error as? URLError).map { e -> String in
                switch e.code {
                case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                    return "连不上管家服务器（\(AgentConfig.url)）。确认 Mac 上的 run_app.command 在运行，真机要和 Mac 在同一个 Wi-Fi。"
                default: return e.localizedDescription
                }
            } ?? error.localizedDescription
            mutate(aid) { $0.error = tip }
        }
    }

    private func handle(_ ev: JSONValue, aid: String, store: Store) {
        switch ev["type"].str {
        case "text":
            let delta = ev["delta"].str
            mutate(aid) { m in
                if let last = m.segments.indices.last, m.segments[last].kind == "text" { m.segments[last].text += delta }
                else { m.segments.append(Segment(kind: "text", text: delta)) }
            }
        case "step":
            let s = AgentStep(id: ev["id"].str, icon: ev["icon"].str, label: ev["label"].str, status: ev["status"].str, detail: ev["detail"].str)
            mutate(aid) { m in
                for j in m.segments.indices where m.segments[j].kind == "steps" {
                    if let k = m.segments[j].steps.firstIndex(where: { $0.id == s.id }) {
                        let notes = m.segments[j].steps[k].notes
                        m.segments[j].steps[k] = s
                        m.segments[j].steps[k].notes = notes
                        return
                    }
                }
                if let last = m.segments.indices.last, m.segments[last].kind == "steps" { m.segments[last].steps.append(s) }
                else { m.segments.append(Segment(kind: "steps", steps: [s])) }
            }
        case "note":
            let sid = ev["step"].str, text = ev["text"].str
            mutate(aid) { m in
                for j in m.segments.indices where m.segments[j].kind == "steps" {
                    if let k = m.segments[j].steps.firstIndex(where: { $0.id == sid }) { m.segments[j].steps[k].notes.append(text) }
                }
            }
        case "action":
            let a = ev["action"]
            apply(a)
            mutate(aid) { $0.segments.append(Segment(kind: "action", action: a)) }
        case "card":
            mutate(aid) { $0.segments.append(Segment(kind: "card", card: ev["card"])) }
        case "memo":
            mutate(aid) { $0.memo = ev["text"].str }
        case "done":
            let st = ev["stats"]
            mutate(aid) { $0.footer = "\(st["seconds"].str) 秒 · \(st["llm_calls"].str) 次调用" }
        case "error":
            mutate(aid) { $0.error = ev["message"].str }
        default: break
        }
    }

    // MARK: 动作（记忆、冰箱）

    private func apply(_ a: JSONValue) {
        switch a["kind"].str {
        case "remember":
            if !memories.contains(where: { $0.text == a["text"].str }) { memories.append(MemoryItem(id: a["id"].str, text: a["text"].str)) }
        case "forget":
            memories.removeAll { $0.id == a["id"].str }
        case "fridge":
            var set = fridge
            for x in a["add"].strs where !set.contains(x) { set.append(x) }
            set.removeAll { a["remove"].strs.contains($0) }
            fridge = set
        default: break
        }
        save()
    }

    func undo(message mid: String, segment sid: String) {
        guard let m = messages.first(where: { $0.id == mid }), let s = m.segments.first(where: { $0.id == sid }), let a = s.action, !s.undone else { return }
        switch a["kind"].str {
        case "remember": memories.removeAll { $0.id == a["id"].str }
        case "forget": memories.append(MemoryItem(id: a["id"].str, text: a["text"].str))
        case "fridge":
            fridge.removeAll { a["add"].strs.contains($0) }
            for x in a["remove"].strs where !fridge.contains(x) { fridge.append(x) }
        default: break
        }
        mutate(mid) { m in
            if let j = m.segments.firstIndex(where: { $0.id == sid }) { m.segments[j].undone = true }
        }
        save()
    }

    func markSaved(message mid: String, draft: String) {
        mutate(mid) { if !$0.saved.contains(draft) { $0.saved.append(draft) } }
        save()
    }

    // MARK: 请求体：对话 + App 里的数据（服务器不存）

    private func requestBody(history: [ChatMessage], store: Store) -> Data {
        let msgs: [[String: Any]] = history.suffix(24).compactMap { (m: ChatMessage) -> [String: Any]? in
            guard m.error == nil || m.role == "user" else { return nil }
            var d: [String: Any] = ["role": m.role, "content": m.content]
            if m.role == "user", !m.images.isEmpty { d["image_ids"] = m.images }
            return d
        }
        var images: [String: String] = [:]
        if let last = history.last, last.role == "user" {
            for name in last.images {
                if let data = try? Data(contentsOf: imageDir.appendingPathComponent(name + ".jpg")) {
                    images[name] = "data:image/jpeg;base64," + data.base64EncodedString()
                }
            }
        }
        let since = D.add(D.today, -120)
        let records: [[String: Any]] = store.meals.filter { $0.date >= since && $0.status == .done }.map(Butler.record)
        let members: [[String: Any]] = store.members.map(Butler.memberInfo)
        let ctx: [String: Any] = [
            "today": D.today, "now": D.nowHM(), "member_id": store.currentID, "members": members,
            "memories": memories.map { ["id": $0.id, "text": $0.text] }, "fridge": fridge, "records": records,
        ]
        let body: [String: Any] = ["messages": msgs, "images": images, "context": ctx]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func record(_ m: Meal) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = m.id
        d["member"] = m.memberID ?? "me"
        d["date"] = m.date
        d["slot"] = m.slot.rawValue
        d["time"] = m.time
        d["title"] = m.title
        d["emoji"] = m.emoji
        d["kcal"] = m.kcal
        d["protein"] = m.protein
        d["carbs"] = m.carbs
        d["fat"] = m.fat
        d["fiber"] = m.fiber
        d["source"] = m.source ?? (m.fromText ? "text" : "photo")
        d["cuisine"] = m.cuisine ?? ""
        d["shop"] = m.shop ?? ""
        d["methods"] = m.methods ?? []
        d["flags"] = m.flags
        d["comment"] = m.comment
        d["foods"] = m.foods.map { f -> [String: Any] in ["name": f.name, "grams": f.grams, "group": f.group.rawValue] }
        return d
    }

    private static func memberInfo(_ m: Member) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = m.id
        d["name"] = m.displayName
        d["kind"] = m.kind.rawValue
        d["age"] = m.age
        d["sex"] = m.sex
        d["avoid"] = m.avoid
        d["health"] = m.health
        d["goal"] = m.goal
        d["kcal_target"] = m.kcalTarget
        d["breed"] = m.breed
        return d
    }
}

// MARK: - 把记录卡片记进手账

extension Store {
    @discardableResult
    func saveDraft(_ c: JSONValue, slot: MealSlot, date: String, photo: UIImage?) async -> Meal? {
        let who = c["member_id"].str
        if !c["copy_of"].str.isEmpty, let src = meal(c["copy_of"].str) {
            let m = duplicate(src, date: date, slot: slot)
            if let id = m?.id { update(id) { $0.source = "agent" } }
            return m
        }
        var sticker = StickerMaker.emojiSticker(c["emoji"].str)
        if let p = photo {
            let base = StickerMaker.normalized(p)
            sticker = StickerMaker.make(base, shape: .lift, lifted: await StickerMaker.liftSubject(base))
        }
        let m = addMeal(date: date, slot: slot, sticker: sticker, title: c["title"].str, emoji: c["emoji"].str, fromText: photo == nil)
        update(m.id) { n in
            n.memberID = (who.isEmpty || who == "me") ? nil : who
            n.status = .done
            n.foods = c["foods"].arr.map { FoodItem(name: $0["name"].str, grams: $0["grams"].num, group: FoodGroup(rawValue: $0["group"].str) ?? .other) }
            n.kcal = c["kcal"].num; n.protein = c["protein"].num; n.carbs = c["carbs"].num; n.fat = c["fat"].num; n.fiber = c["fiber"].num
            n.flags = c["flags"].strs; n.comment = c["comment"].str
            n.cuisine = c["cuisine"].str.isEmpty ? nil : c["cuisine"].str
            n.methods = c["methods"].strs
            n.source = photo == nil ? "agent" : "photo"
            let warn = c["warnings"].strs
            if !warn.isEmpty && (member(who)?.kind.isPet ?? false) { n.danger = warn.joined(separator: "；") }
        }
        refreshReminders()
        return meal(m.id)
    }
}
