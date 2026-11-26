import SwiftUI
import UIKit

struct MealDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let mealID: String

    @State private var title = ""
    @State private var time = Date()
    @State private var slot: MealSlot = .lunch
    @State private var note = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var kind: MemberKind { (store.member(store.meal(mealID)?.memberID) ?? store.member).kind }

    var body: some View {
        NavigationStack {
            Group {
                if let m = store.meal(mealID) {
                    content(m)
                } else {
                    Text("这条记录已经删除了").foregroundStyle(Color.ink2)
                }
            }
            .background(PageBackground())
            .navigationTitle(kind.isPet ? "进食详情" : "餐食详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() }.fontWeight(.semibold) }
            }
        }
        .onAppear(perform: loadFields)
        .confirmationDialog("删除这条记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.delete(mealID); dismiss() }
        } message: { Text("贴纸与营养数据将一并删除，且无法恢复。") }
    }

    private func loadFields() {
        guard !loaded, let m = store.meal(mealID) else { return }
        loaded = true
        title = m.title
        slot = m.slot
        note = m.note
        let mins = D.minutes(m.time)
        time = Calendar.current.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()) ?? Date()
    }

    private func save() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        store.update(mealID) { m in
            m.title = String(title.prefix(12)); m.slot = slot; m.note = String(note.prefix(300)); m.time = hm
        }
    }

    @ViewBuilder
    private func content(_ m: Meal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Group {
                        if let img = store.image(m.sticker) {
                            Image(uiImage: img).resizable().scaledToFit().padding(8)
                                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                        } else {
                            Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: 44))
                        }
                    }
                    .frame(width: 96, height: 96)
                    .background(Color.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("名称", text: $title).font(.system(size: 20, weight: .semibold))
                        DatePicker("用餐时间", selection: $time, displayedComponents: .hourAndMinute)
                            .font(.system(size: 13)).foregroundStyle(Color.ink2)
                    }
                }
                Picker("餐次", selection: $slot) {
                    ForEach(MealSlot.allCases) { s in Text(kind.slotName(s)).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.top, 16)

                nutrition(m)

                SectionHeader(title: "备注与纠正")
                TextField("例如：米饭只吃了半碗，重新识别时会参考", text: $note, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(2...6)
                    .padding(12).surface(radius: 12)
                    .padding(.top, 8)

                Button {
                    save()
                    let img = m.fromText ? nil : store.image(m.sticker)
                    let t = note.isEmpty ? title : note
                    Task { await store.analyze(mealID, image: img, text: t) }
                } label: {
                    Label(m.status == .pending ? "正在识别…" : "重新识别营养", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButton())
                .disabled(m.status == .pending)
                .padding(.top, 20)

                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("删除这条记录").font(.system(size: 15)).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func nutrition(_ m: Meal) -> some View {
        switch m.status {
        case .pending:
            HStack(spacing: 8) { ProgressView(); Text("正在识别食物与营养…").font(.system(size: 13)).foregroundStyle(Color.ink2) }
                .padding(.top, 20)
        case .done:
            if let d = m.danger, !d.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tomato)
                    Text(d).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.tomato)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tomatoSoft).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 16)
            }
            SectionHeader(title: "营养成分")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    cell("能量", "\(Int(m.kcal))", "千卡")
                    cell("蛋白质", "\(Int(m.protein))", "g")
                    cell("碳水", "\(Int(m.carbs))", "g")
                    cell("脂肪", "\(Int(m.fat))", "g")
                }
                .padding(.vertical, 14)
                if !m.flags.isEmpty {
                    Rectangle().fill(Color.line).frame(height: 0.5)
                    FlowLayout { ForEach(m.flags, id: \.self) { f in Pill(text: flagNames[f] ?? f, style: .red) } }
                        .padding(14)
                }
                if !m.comment.isEmpty {
                    Rectangle().fill(Color.line).frame(height: 0.5)
                    Text(m.comment).font(.system(size: 13)).foregroundStyle(Color.ink).padding(14)
                }
            }
            .surface()
            .padding(.top, 8)
            if !m.foods.isEmpty {
                SectionHeader(title: "食物明细")
                VStack(spacing: 0) {
                    ForEach(m.foods.indices, id: \.self) { i in
                        let f = m.foods[i]
                        if i > 0 { Rectangle().fill(Color.line).frame(height: 0.5).padding(.leading, 14) }
                        HStack(spacing: 8) {
                            Text(f.name).font(.system(size: 14)).foregroundStyle(Color.ink)
                            Pill(text: f.group.name)
                            Spacer()
                            Text("\(Int(f.grams)) g").font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.ink2)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                }
                .surface()
                .padding(.top, 8)
            }
        case .error:
            Text("识别失败，可补充描述后重新识别。").font(.system(size: 13)).foregroundStyle(Color.ink2).padding(.top, 20)
        case .none:
            Text("暂无营养数据，可点击下方按钮进行识别。").font(.system(size: 13)).foregroundStyle(Color.ink2).padding(.top, 20)
        }
    }

    private func cell(_ label: String, _ v: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(Color.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
    }
}

struct NextMealView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var ideas: [MealIdea] = []
    @State private var tip = ""
    @State private var error = ""
    @State private var loading = true
    @State private var nearby: IDBox?

    private var slot: MealSlot {
        let r = store.member.reminders, now = D.nowMinutes
        let recorded = Set(store.meals(on: D.today).map(\.slot))
        return MealSlot.mains.first { r.minutes(for: $0) > now && !recorded.contains($0) } ?? .dinner
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading {
                        HStack(spacing: 8) { ProgressView(); Text("正在看你今天和这周吃了什么…").foregroundStyle(Color.ink2) }
                            .padding(.top, 30)
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(Color.ink2)
                    } else {
                        ForEach(ideas) { i in
                            CardBox {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(i.emoji.isEmpty ? "🍽️" : i.emoji).font(.system(size: 32))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(i.dish).font(.headline)
                                        Text(i.why).font(.subheadline).foregroundStyle(Color.ink2)
                                        if i.kcal > 0 { Text("约 \(Int(i.kcal)) kcal").font(.caption).foregroundStyle(Color.ink2) }
                                        if !i.search.isEmpty {
                                            Button { nearby = IDBox(id: i.search) } label: {
                                                Label("附近找「\(i.search)」", systemImage: "mappin.and.ellipse").font(.caption.weight(.semibold))
                                            }
                                            .foregroundStyle(Color.tomato)
                                            .padding(.top, 2)
                                        }
                                    }
                                }
                            }
                        }
                        if !tip.isEmpty {
                            Text("💡 " + tip).font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.butterSoft).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(18)
            }
            .background(PageBackground())
            .navigationTitle(store.kind.isPet ? "\(store.kind.slotName(slot))喂养建议" : "\(slot.name)推荐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好的") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
        .sheet(item: $nearby) { b in NearbyView(keyword: b.id) }
    }

    private func load() async {
        let todayMeals = store.meals(on: D.today)
        let todayText = todayMeals.isEmpty ? "今天还没记录" : todayMeals.map { "\(store.kind.slotName($0.slot))：\($0.title) \($0.foods.map(\.name).joined(separator: "、"))" }.joined(separator: "；")
        let (ctx, _) = Nutrition.weekContext(store: store, dates: D.weekDates(offset: 0))
        do {
            let (i, t) = try await AI.nextMeal(slot: slot, today: todayText, context: ctx, member: store.member, key: store.apiKey)
            ideas = i; tip = t
        } catch {
            self.error = (error as? AIError)?.message ?? error.localizedDescription
        }
        loading = false
    }
}
