import SwiftUI
import PhotosUI
import UserNotifications

/// 「管家」：对话式 agent。说一句或拍一张，记录、查询、做饭、点外卖、排菜单。
/// 界面参考主流 agent：空白输入框、可展开的执行步骤、结构化结果卡片、操作需要用户点确认。
struct ButlerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var butler: Butler
    @State private var input = ""
    @State private var photo: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var sheet: ButlerSheet?
    @FocusState private var focused: Bool
    @StateObject private var speech = SpeechInput()
    @State private var holding = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if butler.messages.isEmpty { emptyState }
                        ForEach(butler.messages) { m in
                            if m.role == "user" { UserBubble(message: m) } else { AssistantMessage(message: m, send: send) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: butler.messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(PageBackground())
            .safeAreaInset(edge: .bottom) { composer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MemberMenu(compact: true) }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("管家").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                        Text("在帮 \(store.member.displayName)").font(.system(size: 10.5)).foregroundStyle(Color.ink3)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { butler.newChat() } label: { Label("新对话", systemImage: "square.and.pencil") }
                        Button { sheet = .memory } label: { Label("管家记得的事（\(butler.memories.count)）", systemImage: "brain") }
                        Button { sheet = .fridge } label: { Label("我的冰箱（\(butler.fridge.count)）", systemImage: "refrigerator") }
                        Button { sheet = .tools } label: { Label("附近餐厅和更多工具", systemImage: "square.grid.2x2") }
                        Divider()
                        Button { sheet = .server } label: { Label("服务器设置", systemImage: "server.rack") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                            .frame(width: 34, height: 34)
                    }
                }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .memory: MemoryListView()
            case .fridge: FridgeListView()
            case .server: AgentServerView()
            case .tools: EatView()
            }
        }
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { photo = $0 }.ignoresSafeArea() }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
        .onChange(of: butler.draft) { _, d in
            if let d { input = d; butler.draft = nil; focused = true }
        }
        .onAppear {
            if let d = butler.draft { input = d; butler.draft = nil; focused = true }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
                pickerItem = nil
            }
        }
    }

    private func send(_ text: String) {
        butler.send(text, image: nil, store: store)
    }

    // MARK: 空状态：不放示例，只说明能做什么

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 90)
            Text(store.member.emoji).font(.system(size: 46))
                .frame(width: 84, height: 84)
                .background(Color.card).clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            Text("今天想吃点什么？").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.ink)
            Text("说一句或拍张照：记一餐、查记录、冰箱里有什么能做、外卖怎么点、排一周菜单。")
                .font(.system(size: 13.5)).foregroundStyle(Color.ink2).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 输入框

    private var composer: some View {
        VStack(spacing: 8) {
            if holding || speech.recording {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.brand)
                        .symbolEffect(.variableColor.iterative, isActive: speech.recording)
                    Text(speech.text.isEmpty ? "在听…说完松开就发送" : speech.text)
                        .font(.system(size: 15)).foregroundStyle(speech.text.isEmpty ? Color.ink3 : Color.ink).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(12).background(Color.brandSoft).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity)
            }
            if let e = speech.error, !holding {
                Text(e).font(.system(size: 12)).foregroundStyle(Color.tomato).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let p = photo {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: p).resizable().scaledToFill().frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { photo = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Color.ink.opacity(0.7))
                        }
                        .offset(x: 6, y: -6)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                    Button { showLibrary = true } label: { Label("从相册选", systemImage: "photo") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                        .frame(width: 36, height: 36).background(Color.fill).clipShape(Circle())
                }
                TextField(photo == nil ? "问管家，或按住 🎙 说话" : "补充一句（可不填）", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .focused($focused)
                    .padding(.vertical, 8)
                if butler.streaming {
                    Button { butler.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.ink).clipShape(Circle())
                    }
                } else if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil {
                    // 没打字时是麦克风：按住说话，松开发送
                    Image(systemName: holding ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(holding ? .white : Color.ink)
                        .frame(width: 36, height: 36).background(holding ? Color.brand : Color.fill).clipShape(Circle())
                        .scaleEffect(holding ? 1.15 : 1)
                        .animation(.easeOut(duration: 0.15), value: holding)
                        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
                            if pressing {
                                holding = true
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                Task { await speech.start() }
                            } else {
                                holding = false
                                Task {
                                    let t = await speech.finish()
                                    if !t.isEmpty { butler.send(t, image: nil, store: store) }
                                }
                            }
                        })
                        .accessibilityLabel("按住说话")
                } else {
                    let ready = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil
                    Button {
                        butler.send(input, image: photo, store: store)
                        input = ""; photo = nil
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(ready ? Color.brand : Color.ink3).clipShape(Circle())
                    }
                    .disabled(!ready)
                }
            }
            .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 4)
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color.paper.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }
}

enum ButlerSheet: String, Identifiable {
    case memory, fridge, server, tools
    var id: String { rawValue }
}

// MARK: - 消息

struct UserBubble: View {
    @EnvironmentObject var butler: Butler
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(message.images, id: \.self) { name in
                if let img = butler.image(name) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            if !message.text.isEmpty {
                Text(message.text).font(.system(size: 15.5)).foregroundStyle(Color.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(red: 0.902, green: 0.894, blue: 0.867))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

struct AssistantMessage: View {
    @EnvironmentObject var butler: Butler
    @EnvironmentObject var store: Store
    let message: ChatMessage
    let send: (String) -> Void

    private var isLive: Bool { butler.streaming && butler.messages.last?.id == message.id }
    private var replaced: Set<String> {
        Set(butler.messages.flatMap { $0.segments.compactMap { $0.card?["replaces"].str } }.filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.segments) { seg in
                switch seg.kind {
                case "text":
                    let t = cleanAgentText(seg.text)
                    if !t.isEmpty { MDText(text: t) }
                case "steps":
                    StepsView(steps: seg.steps, live: isLive && seg.id == message.segments.last(where: { $0.kind == "steps" })?.id)
                case "action":
                    if let a = seg.action {
                        ActionChip(action: a, undone: seg.undone,
                                   canUndo: ["remember", "forget", "fridge"].contains(a["kind"].str) || butler.canUndo(seg.id)) {
                            butler.undo(message: message.id, segment: seg.id)
                        }
                    }
                case "card":
                    if let c = seg.card {
                        AgentCardView(card: c, message: message, superseded: replaced.contains(c["id"].str), send: send)
                    }
                default: EmptyView()
                }
            }
            if isLive && (message.segments.last?.kind != "text") && !(message.segments.last?.steps.contains(where: { $0.status == "running" }) ?? false) {
                ThinkingDots()
            }
            if let e = message.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Color.tomato)
                    if butler.messages.last?.id == message.id {
                        Button("重试") { butler.retry(store: store) }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.tomatoSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !message.footer.isEmpty {
                Text(message.footer).font(.system(size: 10.5)).foregroundStyle(Color.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 轻量 Markdown：粗体、斜体、链接、列表、小标题
struct MDText: View {
    let text: String
    var body: some View {
        Text(attributed).font(.system(size: 15.5)).foregroundStyle(Color.ink).lineSpacing(4).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var attributed: AttributedString {
        var out = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            var line = raw
            var heading = false
            if let r = line.range(of: #"^#{1,4}\s+"#, options: .regularExpression) { line.removeSubrange(r); heading = true }
            if let r = line.range(of: #"^\s*[-*•]\s+"#, options: .regularExpression) { line.replaceSubrange(r, with: "• ") }
            var a = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            if heading { a.font = .system(size: 16, weight: .semibold) }
            out += a
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}

struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.ink3).frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }
        .padding(.vertical, 6)
        .onAppear { on = true }
    }
}

// MARK: - 执行步骤（可展开，像 agent 的「思考过程」）

struct StepsView: View {
    let steps: [AgentStep]
    let live: Bool
    @State private var open: Bool? = nil

    private var running: Bool { steps.contains(where: { $0.status == "running" }) }
    private var expanded: Bool { open ?? (live || running) }
    private var title: String {
        if running { return (steps.last(where: { $0.status == "running" })?.label ?? "处理中") + "…" }
        return "完成 \(steps.count) 步：" + steps.map { $0.label }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open = !expanded } } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.mini) } else {
                        Image(systemName: steps.contains(where: { $0.status == "error" }) ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(steps.contains(where: { $0.status == "error" }) ? Color.tomato : Color.brand)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().overlay(Color.line)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { s in StepRow(step: s) }
                }
                .padding(12)
            }
        }
        .background(Color.fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
    }
}

struct StepRow: View {
    let step: AgentStep
    private var isSQL: Bool { let u = step.detail.uppercased(); return u.hasPrefix("SELECT") || u.hasPrefix("WITH") }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(step.icon).font(.system(size: 13)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
                    switch step.status {
                    case "running": ProgressView().controlSize(.mini)
                    case "error": Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tomato)
                    default: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.brand)
                    }
                }
                ForEach(Array(step.notes.enumerated()), id: \.offset) { _, n in
                    Text(n).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 11.5, design: isSQL ? Font.Design.monospaced : Font.Design.default))
                        .foregroundStyle(Color.ink2).lineLimit(6).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ActionChip: View {
    let action: JSONValue
    let undone: Bool
    var canUndo = true
    let undo: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(icon).font(.system(size: 13))
            Text(label).font(.system(size: 12.5)).foregroundStyle(undone ? Color.ink3 : Color.ink2).strikethrough(undone).lineLimit(2)
            Spacer(minLength: 4)
            if undone { Text("已撤销").font(.system(size: 11)).foregroundStyle(Color.ink3) }
            else if canUndo { Button("撤销", action: undo).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.brandSoft.opacity(undone ? 0.4 : 1))
        .clipShape(Capsule())
    }
    private var icon: String {
        switch action["kind"].str {
        case "fridge": return "🧊"
        case "edit_meal": return "✏️"
        case "settings": return "⚙️"
        case "notify": return "⏰"
        default: return "🧠"
        }
    }
    private var label: String {
        let slotNames = ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"]
        switch action["kind"].str {
        case "edit_meal":
            var parts: [String] = []
            if action["portion"].num > 0 { parts.append("份量 ×\(action["portion"].str)") }
            if let s = slotNames[action["slot"].str] { parts.append("改到\(s)") }
            if !action["date"].str.isEmpty { parts.append("改到 \(action["date"].str)") }
            if !action["title"].str.isEmpty { parts.append("改名「\(action["title"].str)」") }
            if action["kcal"].num > 0 { parts.append("\(action["kcal"].int) kcal") }
            return "已改「\(action["title_before"].str)」：" + parts.joined(separator: "，")
        case "settings":
            var parts: [String] = []
            let r = action["reminder"]
            if let s = slotNames[r["slot"].str] { parts.append("\(s)提醒 \(r["time"].str)") }
            if case .bool(let on) = action["reminders_on"] { parts.append(on ? "打开提醒" : "关闭提醒") }
            if !action["paper"].str.isEmpty { parts.append("换纸张") }
            if action["weight"].num > 0 { parts.append("体重 \(action["weight"].str)kg") }
            if !action["goal"].str.isEmpty { parts.append(["lose": "目标减脂", "keep": "目标保持", "gain": "目标增重"][action["goal"].str] ?? "") }
            if case .string = action["avoid"] { parts.append("忌口：\(action["avoid"].str)") }
            if case .string = action["health"] { parts.append("健康：\(action["health"].str)") }
            if case .number = action["water"] { parts.append("喝水 \(action["water"].int) 杯") }
            if !action["mood"].str.isEmpty { parts.append("心情 \(action["mood"].str)") }
            if action["switch"].bool { parts.append("切换成员") }
            return "已设置：" + parts.joined(separator: "，")
        case "notify":
            return "提醒 \(action["when"].str.suffix(11))：\(action["text"].str)"
        case "remember": return "记住了：" + action["text"].str
        case "forget": return "忘掉了：" + action["text"].str
        case "fridge":
            let a = action["add"].strs.map { "+" + $0 }, r = action["remove"].strs.map { "−" + $0 }
            return "冰箱 " + (a + r).joined(separator: " ")
        default: return action["kind"].str
        }
    }
}

// MARK: - 结果卡片

struct AgentCardView: View {
    let card: JSONValue
    let message: ChatMessage
    let superseded: Bool
    let send: (String) -> Void
    var body: some View {
        switch card["kind"].str {
        case "meal": MealDraftCard(card: card, message: message, superseded: superseded, send: send)
        case "recipe": RecipeCard(card: card)
        case "menu": MenuCard(card: card)
        case "plan": PlanCard(card: card)
        case "table": TableCard(card: card)
        case "safety": SafetyCard(card: card)
        case "shopping": ShoppingCard(items: card["items"].strs, note: card["note"].str)
        case "sources": SourcesCard(card: card)
        case "journal": JournalCard(card: card, message: message, send: send)
        case "confirm": ConfirmCard(card: card, message: message)
        case "share": ShareCard(date: card["date"].str)
        case "occasion": OccasionCard(card: card)
        default: EmptyView()
        }
    }
}

struct MealDraftCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var butler: Butler
    let card: JSONValue
    let message: ChatMessage
    let superseded: Bool
    let send: (String) -> Void
    @State private var slot: MealSlot = .lunch
    @State private var saving = false
    @State private var ready = false

    private var id: String { card["id"].str }
    private var saved: Bool { message.saved.contains(id) }
    private var date: String { card["date"].str.isEmpty ? D.today : card["date"].str }
    private var who: Member? { store.member(card["member_id"].str) }

    var body: some View {
        CardBox {
            HStack(alignment: .top, spacing: 12) {
                Text(card["emoji"].str.isEmpty ? "🍽️" : card["emoji"].str).font(.system(size: 26))
                    .frame(width: 46, height: 46).background(Color.fill).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card["title"].str).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                    HStack(spacing: 4) {
                        if let w = who, w.id != "me" { Text(w.displayName + " ·") }
                        Text(dateLabel)
                        Menu {
                            ForEach(MealSlot.allCases) { s in Button((who?.kind ?? .me).slotName(s)) { slot = s } }
                        } label: {
                            HStack(spacing: 2) { Text((who?.kind ?? .me).slotName(slot)); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                                .foregroundStyle(Color.brand)
                        }
                        .disabled(saved)
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Color.ink2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(card["kcal"].int)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
                    Text("kcal").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(card["foods"].arr.enumerated()), id: \.offset) { _, f in
                    HStack {
                        Text(f["name"].str).font(.system(size: 13.5)).foregroundStyle(Color.ink)
                        Text("\(f["grams"].int)g").font(.system(size: 12)).foregroundStyle(Color.ink3)
                        Spacer()
                        if f["kcal"].num > 0 { Text("\(f["kcal"].int)").font(.system(size: 12.5, design: .rounded)).foregroundStyle(Color.ink2) }
                    }
                }
            }
            HStack(spacing: 6) {
                Pill(text: "蛋白 \(card["protein"].int)g", style: .red)
                Pill(text: "碳水 \(card["carbs"].int)g", style: .yellow)
                Pill(text: "脂肪 \(card["fat"].int)g", style: .blue)
                ForEach(card["flags"].strs, id: \.self) { f in Pill(text: flagNames[f] ?? f) }
            }
            ForEach(card["warnings"].strs, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.tomato)
            }
            if !card["comment"].str.isEmpty {
                Text(card["comment"].str).font(.system(size: 12.5)).foregroundStyle(Color.ink2)
            }
            let q = card["question"]
            if !q.isNull && !saved && !superseded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(q["question"].str).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
                    FlowLayout(spacing: 6) {
                        ForEach(q["options"].strs, id: \.self) { o in
                            Button(o) { send(o) }
                                .font(.system(size: 13)).foregroundStyle(Color.ink)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.fill).clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                                .disabled(butler.streaming)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.butterSoft.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if superseded {
                Text("已按你的回答更新，见下面的新卡片").font(.system(size: 12.5)).foregroundStyle(Color.ink3)
            } else if saved {
                Label("已记到\(dateLabel)\((who?.kind ?? .me).slotName(slot))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.brand)
            } else {
                Button {
                    saving = true
                    Task {
                        let img = card["image_id"].str.isEmpty ? nil : butler.image(card["image_id"].str)
                        if await store.saveDraft(card, slot: slot, date: date, photo: img) != nil {
                            butler.markSaved(message: message.id, draft: id)
                            store.flash("已记到\(dateLabel)\((who?.kind ?? .me).slotName(slot)) ✓")
                        }
                        saving = false
                    }
                } label: {
                    HStack { if saving { ProgressView().tint(.white) }; Text(saving ? "正在做贴纸…" : "记到\((who?.kind ?? .me).slotName(slot))") }
                }
                .buttonStyle(PrimaryButton())
                .disabled(saving)
            }
        }
        .opacity(superseded ? 0.55 : 1)
        .onAppear {
            if !ready { slot = MealSlot(rawValue: card["slot"].str) ?? .guess(); ready = true }
        }
    }

    private var dateLabel: String {
        if date == D.today { return "今天" }
        if date == D.add(D.today, -1) { return "昨天" }
        return "\(D.month(date))月\(D.day(date))日"
    }
}

struct RecipeCard: View {
    let card: JSONValue
    @State private var cooking = false
    var body: some View {
        CardBox {
            HStack(alignment: .firstTextBaseline) {
                Text(card["title"].str).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                if card["kcal"].num > 0 { Text("\(card["kcal"].int) kcal/份").font(.system(size: 12)).foregroundStyle(Color.ink2) }
            }
            HStack(spacing: 6) {
                Pill(text: card["category"].str)
                if card["difficulty"].int > 0 { Pill(text: String(repeating: "★", count: card["difficulty"].int) + " 难度", style: .yellow) }
                Pill(text: "\(card["steps"].arr.count) 步")
            }
            if !card["intro"].str.isEmpty {
                Text(card["intro"].str).font(.system(size: 12.5)).foregroundStyle(Color.ink2).lineLimit(2)
            }
            IngredientSplit(have: card["have"].strs, need: card["need"].strs)
            HStack(spacing: 8) {
                Button { cooking = true } label: { Label("开始做", systemImage: "frying.pan") }.buttonStyle(PrimaryButton())
                if !card["need"].strs.isEmpty { AddShoppingButton(items: card["need"].strs, compact: true) }
            }
            Text("菜谱来自 " + card["source"].str).font(.system(size: 10.5)).foregroundStyle(Color.ink3)
        }
        .fullScreenCover(isPresented: $cooking) { CookingView(recipe: card) }
    }
}

struct IngredientSplit: View {
    let have: [String]
    let need: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !have.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("冰箱有").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink3).frame(width: 40, alignment: .leading)
                    FlowLayout(spacing: 5) { ForEach(have, id: \.self) { Pill(text: $0, style: .green) } }
                }
            }
            if !need.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("要买").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink3).frame(width: 40, alignment: .leading)
                    FlowLayout(spacing: 5) { ForEach(need, id: \.self) { Pill(text: $0, style: .yellow) } }
                }
            }
        }
    }
}

struct MenuCard: View {
    let card: JSONValue
    var body: some View {
        CardBox {
            HStack {
                Text("🧾 " + (card["shop"].str.isEmpty ? "这份菜单" : card["shop"].str)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                Text("认出 \(card["count"].int) 道").font(.system(size: 12)).foregroundStyle(Color.ink2)
            }
            Text("这顿建议 ≤ \(card["budget"].int) kcal（今天已吃 \(card["eaten"].int)）").font(.system(size: 12.5)).foregroundStyle(Color.ink2)
            ForEach(Array(card["picks"].arr.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Color.brand).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p["name"].str).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Color.ink)
                        Text("约 \(p["kcal"].int) kcal · 蛋白 \(p["protein"].int)g" + (p["veg"].bool ? " · 有蔬菜" : ""))
                            .font(.system(size: 12)).foregroundStyle(Color.ink2)
                        if !p["hidden"].str.isEmpty { Text("留意：" + p["hidden"].str).font(.system(size: 12)).foregroundStyle(Color(red: 0.55, green: 0.40, blue: 0.10)) }
                    }
                }
            }
            if !card["avoid"].arr.isEmpty {
                Divider().overlay(Color.line)
                ForEach(Array(card["avoid"].arr.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle").font(.system(size: 13)).foregroundStyle(Color.tomato)
                        Text(a["name"].str).font(.system(size: 13.5)).foregroundStyle(Color.ink)
                        Text(a["why"].str).font(.system(size: 12)).foregroundStyle(Color.ink2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

struct PlanCard: View {
    let card: JSONValue
    @State private var cooking: JSONValue?
    var body: some View {
        CardBox {
            HStack {
                Text("🗓️ \(card["rows"].arr.count) 天晚饭" + (card["member"].str.isEmpty ? "" : " · " + card["member"].str))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                Pill(text: card["passed"].bool ? "✓ 全部通过 · 校验 \(card["rounds"].int) 次" : "有 \(card["violations"].arr.count) 处没满足",
                     style: card["passed"].bool ? .green : .red)
            }
            ForEach(Array(card["rows"].arr.enumerated()), id: \.offset) { _, r in
                Button {
                    let d = card["details"][r["recipe_id"].str]
                    if !d.isNull { cooking = d }
                } label: {
                    HStack(spacing: 10) {
                        Text(r["weekday"].str).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink2).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r["title"].str).font(.system(size: 14.5)).foregroundStyle(Color.ink)
                            if !r["side"].str.isEmpty { Text("+ " + r["side"].str).font(.system(size: 12)).foregroundStyle(Color.ink2) }
                        }
                        Spacer()
                        if r["fish"].bool { Text("🐟").font(.system(size: 12)) }
                        if r["veg"].bool { Text("🥬").font(.system(size: 12)) }
                        Text("\(r["kcal"].int)").font(.system(size: 12.5, design: .rounded)).foregroundStyle(Color.ink2).frame(width: 34, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.ink3)
                    }
                }
                .buttonStyle(.plain)
            }
            FlowLayout(spacing: 5) { ForEach(card["checks"].strs, id: \.self) { Pill(text: "✓ " + $0, style: .green) } }
            ForEach(card["violations"].strs, id: \.self) { v in Text("· " + v).font(.system(size: 12)).foregroundStyle(Color.tomato) }
            if !card["shopping"].strs.isEmpty { AddShoppingButton(items: card["shopping"].strs, compact: false) }
        }
        .fullScreenCover(item: Binding(get: { cooking.map { RecipeBox(recipe: $0) } }, set: { cooking = $0?.recipe })) { b in
            CookingView(recipe: b.recipe)
        }
    }
}

struct RecipeBox: Identifiable {
    let recipe: JSONValue
    var id: String { recipe["id"].str }
}

struct TableCard: View {
    let card: JSONValue
    @State private var showSQL = false
    @State private var all = false
    var body: some View {
        CardBox(padding: 14) {
            HStack {
                Text("查询结果 · \(card["rows"].arr.count) 行").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2)
                Spacer()
                Button(showSQL ? "收起 SQL" : "看 SQL") { showSQL.toggle() }.font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brand)
            }
            if showSQL {
                Text(card["sql"].str).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.ink2)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).textSelection(.enabled)
            }
            let cols = card["columns"].strs
            let rows = card["rows"].arr
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(cols, id: \.self) { Text($0).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink3) } }
                    ForEach(Array(rows.prefix(all ? 31 : 8).enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(Array(r.arr.enumerated()), id: \.offset) { _, v in
                                Text(v.isNull ? "—" : v.str).font(.system(size: 12.5)).foregroundStyle(Color.ink).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if rows.count > 8 && !all { Button("展开全部 \(rows.count) 行") { all = true }.font(.system(size: 12)).foregroundStyle(Color.brand) }
        }
    }
}

struct SafetyCard: View {
    let card: JSONValue
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 18)).foregroundStyle(Color.tomato)
            VStack(alignment: .leading, spacing: 4) {
                Text((card["member"].str.isEmpty ? "" : card["member"].str + " · ") + card["foods"].strs.joined(separator: "、"))
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.ink)
                ForEach(card["issues"].strs, id: \.self) { Text($0).font(.system(size: 12.5)).foregroundStyle(Color.tomato) }
                Text("规则检查（不依赖 AI）").font(.system(size: 10.5)).foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(Color.tomatoSoft).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ShoppingCard: View {
    let items: [String]
    let note: String
    var body: some View {
        CardBox {
            CardTitle(text: "🛒 购物清单", trailing: "\(items.count) 样")
            FlowLayout(spacing: 6) { ForEach(items, id: \.self) { Pill(text: $0) } }
            if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(Color.ink2) }
            AddShoppingButton(items: items, compact: false)
        }
    }
}

struct AddShoppingButton: View {
    @EnvironmentObject var store: Store
    let items: [String]
    let compact: Bool
    @State private var state = 0   // 0 未加 1 加中 2 已加
    var body: some View {
        Button {
            state = 1
            Task {
                do {
                    let n = try await ShoppingSync.add(items)
                    state = 2
                    store.flash("已加 \(n) 样到「提醒事项」")
                } catch {
                    state = 0
                    store.flash((error as? AIError)?.message ?? error.localizedDescription)
                }
            }
        } label: {
            Label(state == 2 ? "已加入" : (compact ? "缺的加清单" : "加入「提醒事项」购物清单（\(items.count)）"),
                  systemImage: state == 2 ? "checkmark" : "cart.badge.plus")
        }
        .buttonStyle(SoftButton(color: state == 2 ? .brand : .ink))
        .disabled(state != 0)
    }
}

struct SourcesCard: View {
    let card: JSONValue
    @State private var open: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出处").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
            ForEach(Array(card["items"].arr.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 4) {
                    Button { open = open == c["id"].str ? nil : c["id"].str } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.ink2)
                                .frame(width: 18, height: 18).background(Color.card).clipShape(Circle())
                                .overlay(Circle().strokeBorder(Color.line, lineWidth: 0.5))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c["title"].str).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
                                Text(c["source"].str).font(.system(size: 11)).foregroundStyle(Color.ink2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    if open == c["id"].str {
                        Text(c["text"].str).font(.system(size: 12)).foregroundStyle(Color.ink2).padding(.leading, 26)
                        if let u = URL(string: c["url"].str), !c["url"].str.isEmpty {
                            Link("打开原文", destination: u).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brand).padding(.leading, 26)
                        }
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fill).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
    }
}

// MARK: - 烹饪模式：一步一屏，大字，识别「X 分钟」给计时器

struct CookingView: View {
    @Environment(\.dismiss) private var dismiss
    let recipe: JSONValue
    @State private var page = 0
    @State private var timerEnd: Date?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var steps: [String] { recipe["steps"].strs }
    private var total: Int { steps.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).frame(width: 36, height: 36) }
                Spacer()
                Text(recipe["title"].str).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                Text("\(page + 1)/\(total)").font(.system(size: 13, design: .rounded)).foregroundStyle(Color.ink2).frame(width: 36)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ProgressBar(value: Double(page + 1) / Double(max(total, 1)), color: .brand, height: 4).padding(.horizontal, 20).padding(.top, 8)
            TabView(selection: $page) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("准备").font(.system(size: 28, weight: .bold)).foregroundStyle(Color.ink)
                        ForEach(recipe["amounts"].strs, id: \.self) { a in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color.brand).frame(width: 6, height: 6).padding(.top, 9)
                                Text(a).font(.system(size: 19)).foregroundStyle(Color.ink)
                            }
                        }
                        if !recipe["need"].strs.isEmpty { IngredientSplit(have: recipe["have"].strs, need: recipe["need"].strs).padding(.top, 8) }
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .tag(0)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    VStack(alignment: .leading, spacing: 20) {
                        Text("第 \(i + 1) 步").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand)
                        Text(s).font(.system(size: 25, weight: .medium)).foregroundStyle(Color.ink).lineSpacing(6)
                        if let sec = CookingView.seconds(in: s) {
                            Button {
                                timerEnd = Date().addingTimeInterval(sec)
                                CookingView.notify(after: sec, title: recipe["title"].str, body: "第 \(i + 1) 步的时间到了")
                            } label: { Label("计时 " + CookingView.fmt(sec), systemImage: "timer") }
                            .buttonStyle(SoftButton(color: .brand)).frame(maxWidth: 220)
                        }
                        Spacer()
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .tag(i + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if let end = timerEnd {
                let left = end.timeIntervalSince(now)
                HStack {
                    Image(systemName: "timer")
                    Text(left > 0 ? CookingView.fmt(left) : "时间到！").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Button("取消") { timerEnd = nil; UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["cook-timer"]) }
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(left > 0 ? Color.ink : Color.tomato)
                .padding(14).background(left > 0 ? Color.butterSoft : Color.tomatoSoft)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.horizontal, 20)
            }
            HStack(spacing: 12) {
                Button { withAnimation { page = max(0, page - 1) } } label: { Label("上一步", systemImage: "chevron.left") }
                    .buttonStyle(SoftButton()).disabled(page == 0)
                if page < total - 1 {
                    Button { withAnimation { page += 1 } } label: { Text(page == 0 ? "开始" : "下一步") }.buttonStyle(PrimaryButton())
                } else {
                    Button { dismiss() } label: { Text("做好了 🎉") }.buttonStyle(PrimaryButton())
                }
            }
            .padding(20)
        }
        .background(PageBackground())
        .onReceive(tick) { now = $0 }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    static func seconds(in s: String) -> TimeInterval? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:-|~|–|到)?\s*(?:\d+(?:\.\d+)?)?\s*(分钟|分|秒|小时)"#
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let m = String(s[r])
        guard let nr = m.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression), let n = Double(m[nr]) else { return nil }
        if m.hasSuffix("秒") { return n }
        if m.hasSuffix("小时") { return n * 3600 }
        return n * 60
    }

    static func fmt(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func notify(after sec: TimeInterval, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = "⏰ " + title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: "cook-timer", content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, sec), repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - 记忆、冰箱、服务器设置

struct MemoryListView: View {
    @EnvironmentObject var butler: Butler
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("教管家一件事，比如「我家一碗饭约 150g」", text: $draft)
                        Button("添加") {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            butler.memories.append(MemoryItem(id: "M" + UUID().uuidString.prefix(5).lowercased(), text: t))
                            draft = ""; butler.save()
                        }
                    }
                } footer: { Text("管家会在估算份量、推荐菜和排菜单时用上这些。对话里说「记住…」「忘掉…」也可以。") }
                Section {
                    if butler.memories.isEmpty { Text("还没有").foregroundStyle(Color.ink3) }
                    ForEach(butler.memories.reversed()) { m in
                        Text(m.text).font(.system(size: 15))
                    }
                    .onDelete { idx in
                        let list = Array(butler.memories.reversed())
                        let ids = Set(idx.map { list[$0].id })
                        butler.memories.removeAll { ids.contains($0.id) }
                        butler.save()
                    }
                }
            }
            .navigationTitle("管家记得的事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct FridgeListView: View {
    @EnvironmentObject var butler: Butler
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("加食材，多个用空格或逗号隔开", text: $draft).onSubmit(add)
                        Button("添加", action: add)
                    }
                } footer: { Text("也可以直接在对话里拍一张冰箱照片。推荐菜谱和排菜单时会优先用上这些。") }
                Section {
                    if butler.fridge.isEmpty { Text("空空的").foregroundStyle(Color.ink3) }
                    ForEach(butler.fridge, id: \.self) { Text($0) }
                        .onDelete { idx in butler.fridge.remove(atOffsets: idx); butler.save() }
                }
            }
            .navigationTitle("我的冰箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("清空", role: .destructive) { butler.fridge = []; butler.save() }.disabled(butler.fridge.isEmpty) }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
    private func add() {
        let items = draft.components(separatedBy: CharacterSet(charactersIn: " ,，、;；")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for x in items where !butler.fridge.contains(x) { butler.fridge.append(x) }
        draft = ""; butler.save()
    }
}

struct AgentServerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var url = AgentConfig.url
    @State private var token = AgentConfig.token
    @State private var status = ""
    @State private var testing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AgentConfig.cloud, text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("口令（服务器设置了 APP_TOKEN 才需要）", text: $token)
                } header: { Text("管家服务器") } footer: {
                    Text("默认是云端：\(AgentConfig.cloud)\n管家会用你在「我的」里填的 DeepSeek Key，服务器不保存。\n本地调试：模拟器填 http://localhost:8765。")
                }
                Section {
                    Button { test() } label: { HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } } }
                    if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(status.hasPrefix("✓") ? Color.brand : Color.tomato) }
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("保存") { AgentConfig.url = url; AgentConfig.token = token; dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button("用云端") { url = AgentConfig.cloud } }
            }
        }
    }
    private func test() {
        AgentConfig.url = url; AgentConfig.token = token
        testing = true; status = ""
        Task {
            defer { testing = false }
            guard let u = URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/health") else { status = "地址格式不对"; return }
            do {
                let (d, r) = try await URLSession.shared.data(from: u)
                let j = try? JSONDecoder().decode(JSONValue.self, from: d)
                if (r as? HTTPURLResponse)?.statusCode == 200, j?["ok"].bool == true {
                    if j?["key"].bool == true { status = "✓ 连上了（模型 \(j?["model"].str ?? "")）" }
                    else if !store.apiKey.isEmpty { status = "✓ 连上了（用你 App 里的 DeepSeek Key）" }
                    else { status = "连上了，但还缺 DeepSeek Key：去「我的」里填一下" }
                } else { status = "服务器返回异常" }
            } catch { status = "连不上：\(error.localizedDescription)" }
        }
    }
}

// MARK: - 手账装饰物

struct DecoView: View {
    let deco: Deco
    let W: CGFloat
    var body: some View {
        let c = Color(hex: deco.color)
        let s = W * CGFloat(deco.size)
        Group {
            switch deco.kind {
            case "tape":
                Tape(color: c).scaleEffect(s / 90)
                    .frame(width: s, height: s * 24 / 90)
            case "emoji":
                Text(deco.text).font(.system(size: s))
            case "icon":
                Image(systemName: deco.text).font(.system(size: s, weight: .regular)).foregroundStyle(c)
            case "text":
                Text(deco.text)
                    .font(.system(size: s, weight: .semibold, design: .rounded)).foregroundStyle(c)
                    .padding(.horizontal, s * 0.2)
                    .background(alignment: .bottom) {
                        if deco.highlight {
                            Rectangle().fill(Color(hex: "#F2D38B").opacity(0.75)).frame(height: s * 0.55)
                        }
                    }
                    .fixedSize()
            case "note":
                Text(deco.text)
                    .font(.system(size: max(9, W * 0.03), weight: .medium, design: .rounded)).foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .padding(W * 0.02)
                    .frame(width: s, alignment: .leading)
                    .background(ZStack { Color.white; c.opacity(0.45) })
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
            case "stamp":
                Text(deco.text)
                    .font(.system(size: s * 0.2, weight: .heavy, design: .rounded)).foregroundStyle(c)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6)
                    .padding(s * 0.12)
                    .frame(width: s, height: s)
                    .overlay(Circle().stroke(c, lineWidth: max(1.5, s * 0.035)))
                    .overlay(Circle().inset(by: s * 0.08).stroke(c.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .opacity(0.85)
            default:
                EmptyView()
            }
        }
        .rotationEffect(.degrees(deco.rot))
    }
}

extension Deco {
    static func from(_ j: JSONValue) -> Deco {
        Deco(kind: j["kind"].str, text: j["text"].str, x: j["x"].num, y: j["y"].num, rot: j["rot"].num,
             size: j["size"].num > 0 ? j["size"].num : 0.06, color: j["color"].str.isEmpty ? "#3A3A36" : j["color"].str,
             highlight: j["highlight"].bool)
    }
}

// MARK: - 管家设计的手账：预览 + 一键应用

struct JournalPreview: View {
    @EnvironmentObject var store: Store
    let card: JSONValue

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let member = store.member(card["member_id"].str) ?? store.member
            let date = card["date"].str.isEmpty ? D.today : card["date"].str
            let decos = card["decos"].arr.map(Deco.from)
            ZStack(alignment: .topLeading) {
                PaperBackground(style: PaperStyle(rawValue: card["paper"].str) ?? member.paper, imageName: member.paperImage)
                Grain(opacity: 0.8)
                Tape(color: Color(red: 0.86, green: 0.82, blue: 0.70).opacity(0.75)).rotationEffect(.degrees(-3)).position(x: W / 2, y: 9)
                VStack(spacing: 3) {
                    Text(String(format: "%02d.%02d", D.month(date), D.day(date)))
                        .font(.system(size: W * 0.085, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                    Text("\(card["title"].str) · 星期\(D.weekday(date))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink2)
                }
                .frame(width: W).padding(.top, H * 0.045)
                ForEach(decos.filter { $0.kind != "tape" }) { d in
                    DecoView(deco: d, W: W).position(x: CGFloat(d.x) * W, y: CGFloat(d.y) * H)
                }
                ForEach(Array(card["stickers"].arr.enumerated()), id: \.offset) { _, s in
                    if let m = store.meal(s["id"].str) {
                        VStack(spacing: 0) {
                            if let img = store.image(m.sticker) {
                                Image(uiImage: img).resizable().scaledToFit()
                                    .shadow(color: Color(red: 0.31, green: 0.2, blue: 0.08).opacity(0.25), radius: 3, y: 3)
                            } else {
                                Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: W * 0.12))
                            }
                            Text(m.title).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.ink2).lineLimit(1).fixedSize()
                        }
                        .frame(width: W * CGFloat(s["scale"].num))
                        .rotationEffect(.degrees(s["rot"].num))
                        .position(x: CGFloat(s["x"].num) * W, y: CGFloat(s["y"].num) * H)
                    }
                }
                ForEach(decos.filter { $0.kind == "tape" }) { d in
                    DecoView(deco: d, W: W).position(x: CGFloat(d.x) * W, y: CGFloat(d.y) * H)
                }
                Text(card["caption"].str).font(.system(size: 11, design: .serif)).italic().foregroundStyle(Color.ink2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: W - 24).position(x: W / 2, y: H - 22)
            }
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
    }
}

private struct JournalBackup {
    var day: DayLog
    var meals: [String: (Double, Double, Double, Double)]
}

struct JournalCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var butler: Butler
    let card: JSONValue
    let message: ChatMessage
    let send: (String) -> Void
    @State private var backup: JournalBackup?

    private var cid: String { card["id"].str }
    private var applied: Bool { message.saved.contains(cid) }
    private var memberID: String { card["member_id"].str.isEmpty ? store.currentID : card["member_id"].str }
    private var date: String { card["date"].str.isEmpty ? D.today : card["date"].str }

    var body: some View {
        CardBox {
            HStack {
                Text("🎨 " + (card["style"].str.isEmpty ? "手账设计" : card["style"].str)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                if card["fixes"].int > 0 { Pill(text: "自动修正 \(card["fixes"].int) 处排版", style: .blue) }
            }
            JournalPreview(card: card)
            if !card["caption"].str.isEmpty {
                Text("「\(card["caption"].str)」").font(.system(size: 13, design: .serif)).foregroundStyle(Color.ink2)
            }
            if applied {
                HStack {
                    Label("已用到\(date == D.today ? "今天" : "\(D.month(date))月\(D.day(date))日")的手账", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.brand)
                    Spacer()
                    if backup != nil { Button("撤销", action: undo).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2) }
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: apply) { Label("用这版", systemImage: "wand.and.stars") }.buttonStyle(PrimaryButton())
                    Button { send("换一版不一样的风格") } label: { Label("换一版", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(SoftButton()).disabled(butler.streaming)
                }
            }
        }
    }

    private func apply() {
        var snap = JournalBackup(day: store.day(date, member: memberID), meals: [:])
        for s in card["stickers"].arr {
            let id = s["id"].str
            guard let m = store.meal(id) else { continue }
            snap.meals[id] = (m.x, m.y, m.rot, m.scale)
            store.update(id) { $0.x = s["x"].num; $0.y = s["y"].num; $0.rot = s["rot"].num; $0.scale = s["scale"].num }
        }
        let decos = card["decos"].arr.map(Deco.from)
        store.setDay(date, member: memberID) { d in
            d.paper = card["paper"].str.isEmpty ? nil : card["paper"].str
            d.title = card["title"].str
            d.caption = card["caption"].str
            d.decos = decos
        }
        backup = snap
        butler.markSaved(message: message.id, draft: cid)
        store.flash("手账换好了，去「今日」看看 ✨")
    }

    private func undo() {
        guard let b = backup else { return }
        for (id, v) in b.meals { store.update(id) { $0.x = v.0; $0.y = v.1; $0.rot = v.2; $0.scale = v.3 } }
        store.setDay(date, member: memberID) { $0 = b.day }
        backup = nil
        butler.unmarkSaved(message: message.id, draft: cid)
        store.flash("已恢复原来的手账")
    }
}

// MARK: - 需要确认的操作（删除记录）

struct ConfirmCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var butler: Butler
    let card: JSONValue
    let message: ChatMessage
    private var done: Bool { message.saved.contains(card["id"].str) }
    var body: some View {
        CardBox(padding: 14) {
            Text(card["title"].str).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Color.ink)
            if done {
                Label("已删除", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2)
            } else if store.meal(card["action"]["id"].str) == nil {
                Text("这条记录已经不在了").font(.system(size: 12.5)).foregroundStyle(Color.ink3)
            } else {
                Button(role: .destructive) {
                    store.delete(card["action"]["id"].str)
                    butler.markSaved(message: message.id, draft: card["id"].str)
                    store.flash("已删除")
                } label: { Label(card["button"].str.isEmpty ? "确认" : card["button"].str, systemImage: "trash") }
                .buttonStyle(SoftButton(color: .tomato))
            }
        }
    }
}

struct ShareCard: View {
    let date: String
    @State private var open = false
    var body: some View {
        CardBox(padding: 14) {
            HStack {
                Text("📤 \(date == D.today ? "今天" : "\(D.month(date))月\(D.day(date))日")的手账").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
            }
            Button { open = true } label: { Label("生成图片并分享", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButton())
        }
        .sheet(isPresented: $open) { ExportView(date: date.isEmpty ? D.today : date) }
    }
}

// MARK: - 办一件事：请客 / 给家人做饭

struct OccasionCard: View {
    @EnvironmentObject var store: Store
    let card: JSONValue
    @State private var cooking: JSONValue?
    @State private var reminded: Set<String> = []

    private func when(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)
    }

    var body: some View {
        CardBox {
            HStack {
                Text("🍽️ \(card["people"].int) 人 · \(D.month(card["date"].str))月\(D.day(card["date"].str))日 \(card["time"].str)")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                Pill(text: card["passed"].bool ? "✓ 每道菜都适合每个人" : "有 \(card["violations"].arr.count) 处没满足", style: card["passed"].bool ? .green : .red)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(card["guests"].arr.enumerated()), id: \.offset) { _, g in
                    Pill(text: g["name"].str + (g["rules"].strs.isEmpty ? "" : "：" + g["rules"].strs.joined(separator: "、")), style: .yellow)
                }
            }
            if !card["why"].str.isEmpty { Text(card["why"].str).font(.system(size: 12.5)).foregroundStyle(Color.ink2) }
            ForEach(Array(card["dishes"].arr.enumerated()), id: \.offset) { _, d in
                Button {
                    let r = card["details"][d["recipe_id"].str]
                    if !r.isNull { cooking = r }
                } label: {
                    HStack {
                        Text(d["title"].str).font(.system(size: 14.5)).foregroundStyle(Color.ink)
                        Pill(text: d["category"].str)
                        Spacer()
                        Text("\(d["minutes"].int) 分钟").font(.system(size: 12)).foregroundStyle(Color.ink2)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.ink3)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(card["violations"].strs, id: \.self) { v in Text("· " + v).font(.system(size: 12)).foregroundStyle(Color.tomato) }
            Divider().overlay(Color.line)
            Text("时间线").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
            ForEach(Array(card["timeline"].arr.enumerated()), id: \.offset) { i, t in
                let key = "\(i)"
                HStack(alignment: .top, spacing: 10) {
                    Text(String(t["time"].str.suffix(5))).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color.brand).frame(width: 44, alignment: .leading)
                    Text(t["text"].str).font(.system(size: 13.5)).foregroundStyle(Color.ink)
                    Spacer()
                    if let w = when(t["time"].str), w > Date() {
                        Button {
                            Reminders.once(id: "occasion.\(card["date"].str).\(i)", title: "🍽️ " + t["text"].str, body: "\(card["time"].str) 开饭", at: w)
                            reminded.insert(key)
                        } label: { Image(systemName: reminded.contains(key) ? "bell.fill" : "bell").foregroundStyle(reminded.contains(key) ? Color.brand : Color.ink3) }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    for (i, t) in card["timeline"].arr.enumerated() {
                        if let w = when(t["time"].str), w > Date() {
                            Reminders.once(id: "occasion.\(card["date"].str).\(i)", title: "🍽️ " + t["text"].str, body: "\(card["time"].str) 开饭", at: w)
                            reminded.insert("\(i)")
                        }
                    }
                    store.flash("已按时间线设好 \(reminded.count) 个提醒")
                } label: { Label("全部设提醒", systemImage: "bell.badge") }
                .buttonStyle(PrimaryButton())
                if !card["shopping"].strs.isEmpty { AddShoppingButton(items: card["shopping"].strs, compact: true) }
            }
        }
        .fullScreenCover(item: Binding(get: { cooking.map { RecipeBox(recipe: $0) } }, set: { cooking = $0?.recipe })) { b in
            CookingView(recipe: b.recipe)
        }
    }
}
