import SwiftUI
import UserNotifications

// MARK: - 「我的」

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: IDBox?
    @State private var adding = false
    @State private var keyInput = ""
    @State private var testing = false
    @State private var notifStatus = "检查中…"
    @State private var deleting: Member?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.members) { m in
                        Button { editing = IDBox(id: m.id) } label: {
                            HStack(spacing: 12) {
                                MemberAvatar(member: m, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                                    Text("\(m.kind.title) · 推荐摄入 \(m.kcalTarget) 千卡/日").font(.caption).foregroundStyle(Color.ink2)
                                }
                                Spacer()
                                if m.id == store.currentID { Text("当前").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brand).padding(.horizontal, 7).padding(.vertical, 2).background(Color.brandSoft).clipShape(Capsule()) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.ink2.opacity(0.5))
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if m.id != "me" {
                                Button(role: .destructive) { deleting = m } label: { Label("删除", systemImage: "trash") }
                            }
                            Button { editing = IDBox(id: m.id) } label: { Label("修改", systemImage: "pencil") }.tint(.sky)
                        }
                    }
                    Button { adding = true } label: { Label("添加家人或宠物", systemImage: "plus") }
                } header: { Text("成员") } footer: { Text("每个成员有自己的手账、营养分析和提醒。可以帮老人记录，也可以记录狗狗和猫咪吃了什么。") }

                Section {
                    Toggle("记录后自动分析营养", isOn: $store.settings.autoAI)
                    Stepper("每日饮水目标  \(store.settings.waterGoal) 杯", value: $store.settings.waterGoal, in: 4...14)
                    HStack {
                        Text("通知权限")
                        Spacer()
                        Text(notifStatus).foregroundStyle(.secondary)
                    }
                    if notifStatus != "已开启" {
                        Button("去系统设置打开通知") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: { Text("通用") }

                Section {
                    SecureField("粘贴新的 API Key（sk-…）", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("保存 Key") {
                            store.apiKey = keyInput
                            keyInput = ""
                            store.flash("已保存")
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Button(testing ? "测试中…" : "测试连接") { Task { await test() } }.disabled(testing)
                    }
                    HStack {
                        Text("当前 Key")
                        Spacer()
                        Text(masked(store.apiKey)).foregroundStyle(.secondary).font(.footnote.monospaced())
                    }
                } header: { Text("DeepSeek AI 识别") } footer: { Text("识别用的是 DeepSeek 开放平台（模型 deepseek-flash），按调用量从你的 DeepSeek 余额扣费，一张图大约几分钱。") }

                Section("数据") {
                    HStack { Text("记录"); Spacer(); Text("\(store.meals.count) 条").foregroundStyle(.secondary) }
                    Text("所有记录和贴纸都保存在这台手机里。删除 App 会清空数据。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .task { await checkNotif() }
        }
        .sheet(item: $editing) { b in MemberEditView(memberID: b.id) }
        .sheet(isPresented: $adding) { MemberEditView(memberID: nil) }
        .confirmationDialog("删除「\(deleting?.displayName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let d = deleting { store.removeMember(d.id) }
                deleting = nil
            }
        } message: { Text("会一起删除 TA 的所有记录和贴纸，不能恢复。") }
    }

    private func masked(_ k: String) -> String {
        guard k.count > 10 else { return k.isEmpty ? "未设置" : "••••" }
        return String(k.prefix(5)) + "••••" + String(k.suffix(4))
    }

    private func test() async {
        testing = true
        do {
            _ = try await AI.json(prompt: "只输出 JSON：{\"ok\":true}", key: store.apiKey)
            store.flash("✅ DeepSeek 连接正常")
        } catch {
            store.flash((error as? AIError)?.message ?? error.localizedDescription)
        }
        testing = false
    }

    private func checkNotif() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifStatus = "已开启"
        case .denied: notifStatus = "已关闭"
        default: notifStatus = "未设置"
        }
    }
}

// MARK: - 添加 / 编辑成员

struct MemberEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let memberID: String?          // nil = 新建

    @State private var m = Member.new(kind: .elder)
    @State private var picked = false
    @State private var confirmDelete = false

    private var isNew: Bool { memberID == nil }
    private let emojis: [MemberKind: [String]] = [
        .me: ["🙂", "😎", "🧑", "👩", "👨", "🧑‍🍳"],
        .elder: ["👵", "👴", "🧓", "👩‍🦳", "👨‍🦳", "🌸"],
        .dog: ["🐶", "🐕", "🦮", "🐩", "🐕‍🦺", "🦴"],
        .cat: ["🐱", "🐈", "🐈‍⬛", "😺", "😸", "🐾"],
    ]

    var body: some View {
        NavigationStack {
            Form {
                if isNew && !picked {
                    Section {
                        ForEach([MemberKind.elder, .dog, .cat]) { k in
                            Button {
                                m = Member.new(kind: k)
                                withAnimation { picked = true }
                            } label: {
                                HStack(spacing: 14) {
                                    Text(k.defaultEmoji).font(.system(size: 30)).frame(width: 52, height: 52).background(k.accentSoft).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(k.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
                                        Text(k.subtitle).font(.caption).foregroundStyle(Color.ink2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    } header: { Text("要记录谁？") }
                } else {
                    identity
                    details(for: m.kind)
                    reminders
                    if !isNew && m.id != "me" {
                        Section {
                            Button("删除这个成员", role: .destructive) { confirmDelete = true }
                        } footer: { Text("会一起删除 TA 的所有记录和贴纸。") }
                    }
                }
            }
            .navigationTitle(isNew ? (picked ? "添加\(m.kind.title)" : "添加成员") : m.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if !isNew || picked {
                    ToolbarItem(placement: .confirmationAction) { Button(isNew ? "添加" : "保存") { save() }.fontWeight(.semibold) }
                }
            }
        }
        .onAppear {
            if let id = memberID, let existing = store.member(id) { m = existing; picked = true }
        }
        .confirmationDialog("删除「\(m.displayName)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.removeMember(m.id); dismiss() }
        }
    }

    private func save() {
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty && m.kind != .me { m.name = m.kind.title }
        if isNew { store.addMember(m) } else { store.updateMember(m.id) { $0 = m } }
        dismiss()
    }

    private var identity: some View {
        Section {
            HStack(spacing: 14) {
                MemberAvatar(member: m, size: 56)
                TextField(m.kind.isPet ? "名字，比如 豆豆" : (m.kind == .elder ? "称呼，比如 外婆" : "名字"), text: $m.name)
                    .font(.system(size: 18, weight: .semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(emojis[m.kind] ?? [], id: \.self) { e in
                        Button { m.emoji = e } label: {
                            Text(e).font(.system(size: 26)).frame(width: 44, height: 44)
                                .background(m.emoji == e ? m.kind.accentSoft : Color.clear).clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: { Text(m.kind.title) }
    }

    @ViewBuilder
    private func details(for kind: MemberKind) -> some View {
        if kind.isPet {
            Section {
                TextField("品种（比如 柯基、英短）", text: $m.breed)
                Picker("性别", selection: $m.sex) { Text("公").tag("male"); Text("母").tag("female") }
                Toggle("已绝育", isOn: $m.neutered)
                numberRow("年龄", "岁", $m.age)
                numberRow("体重", "kg", $m.weight)
                Picker("体重目标", selection: $m.goal) { Text("保持").tag("keep"); Text("减重").tag("lose"); Text("增重").tag("gain") }
                TextField("过敏或不能吃的（可选）", text: $m.avoid)
                TextField("健康情况（可选，比如 肾不好、肠胃敏感）", text: $m.health)
                HStack {
                    Text("每日热量目标"); Spacer()
                    if m.kcalOverride != nil {
                        Button("恢复自动") { m.kcalOverride = nil }.font(.caption).buttonStyle(.borderless)
                    }
                    Text("\(m.kcalTarget) kcal").bold()
                }
            } header: { Text("身体情况") } footer: { Text("按体重和是否绝育估算每天需要的热量，只是参考，具体以兽医建议为准。") }
        } else {
            Section {
                Picker("性别", selection: $m.sex) { Text("女").tag("female"); Text("男").tag("male") }
                numberRow("年龄", "岁", $m.age)
                numberRow("身高", "cm", $m.height)
                numberRow("体重", "kg", $m.weight)
                Picker("活动量", selection: $m.activity) {
                    Text("久坐").tag(1.2); Text("轻度活动").tag(1.375); Text("中度运动").tag(1.55); Text("高强度").tag(1.725)
                }
                Picker("目标", selection: $m.goal) {
                    Text("均衡保持").tag("keep"); Text(kind == .elder ? "控制体重" : "减脂").tag("lose"); Text(kind == .elder ? "增重增肌" : "增肌").tag("gain")
                }
                TextField("忌口 / 过敏（比如 不吃香菜、乳糖不耐）", text: $m.avoid)
                if kind == .elder {
                    TextField("健康情况（比如 牙口不好、高血压、糖尿病）", text: $m.health)
                }
                HStack {
                    Text("每日热量目标"); Spacer()
                    if m.kcalOverride != nil {
                        Button("恢复自动") { m.kcalOverride = nil }.font(.caption).buttonStyle(.borderless)
                    }
                    Text("\(m.kcalTarget) kcal").bold()
                }
            } header: { Text("身体情况") } footer: { Text(kind == .elder ? "AI 会按老年人的营养重点来分析，比如蛋白质、钙、少盐和好不好嚼。" : "用来估算热量目标，让 AI 建议更贴合你。") }
        }
    }

    private var reminders: some View {
        Section {
            Toggle(m.kind.isPet ? "喂食提醒" : "三餐提醒", isOn: $m.reminders.on)
            if m.reminders.on {
                timeRow("\(m.kind.slotEmoji(.breakfast)) \(m.kind.slotName(.breakfast))", \.breakfast)
                timeRow("\(m.kind.slotEmoji(.lunch)) \(m.kind.slotName(.lunch))", \.lunch)
                timeRow("\(m.kind.slotEmoji(.dinner)) \(m.kind.slotName(.dinner))", \.dinner)
                if m.kind == .me {
                    Toggle("💧 喝水提醒（10点 / 15点 / 20点）", isOn: $m.reminders.water)
                    Toggle("✨ 周日晚提醒看周报", isOn: $m.reminders.weekly)
                }
            }
        } header: { Text("提醒") } footer: { Text(m.kind == .me ? "到点推送通知，当天已经记录的餐不会再提醒。" : "到点提醒你\(m.kind.isPet ? "喂它" : "关心一下长辈吃饭")，记录了的那顿就不再提醒。") }
    }

    private func numberRow(_ label: String, _ unit: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(unit, text: binding).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func timeRow(_ label: String, _ path: WritableKeyPath<ReminderSettings, Int>) -> some View {
        let binding = Binding<Date>(
            get: {
                let v = m.reminders[keyPath: path]
                return Calendar.current.date(bySettingHour: v / 60, minute: v % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                m.reminders[keyPath: path] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
        return DatePicker(label, selection: binding, displayedComponents: .hourAndMinute)
    }
}
