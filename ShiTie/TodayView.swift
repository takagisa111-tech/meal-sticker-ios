import SwiftUI
import PhotosUI
import UIKit

struct TodayView: View {
    @EnvironmentObject var store: Store
    @Binding var date: String
    @Binding var tab: Tab

    @State private var selected: String?
    @State private var addReq: AddRequest?
    @State private var detail: IDBox?
    @State private var showNext = false
    @State private var showPaper = false
    @State private var slotChoice: MealSlot?
    @State private var showExport = false
    @State private var shareImage: UIImage?
    @State private var note = ""
    @State private var tick = Date()
    @State private var pinching = false
    @FocusState private var noteFocused: Bool

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var isPet: Bool { store.kind.isPet }
    private var defaultSlot: MealSlot { date == D.today ? MealSlot.guess() : .lunch }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    weekStrip.padding(.top, 14)
                    banner
                    paper.padding(.top, 16)
                    slotRow.padding(.top, 14)

                    SectionHeader(title: isPet ? "今日进食" : "今日摄入")
                    summaryCard.padding(.top, 8)

                    insights

                    if !isPet {
                        SectionHeader(title: "饮水")
                        waterCard.padding(.top, 8)
                    }

                    SectionHeader(title: isPet ? "今日状态" : "今日小记", action: "导出手账") { exportImage() }
                    diaryCard.padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDisabled(pinching)
            .scrollDismissesKeyboard(.interactively)
            .background(PageBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $addReq) { r in AddMealView(date: date, slot: r.slot, mode: r.mode) }
        .sheet(item: $detail) { b in MealDetailView(mealID: b.id) }
        .sheet(isPresented: $showNext) { NextMealView() }
        .sheet(isPresented: $showPaper) { PaperPicker() }
        .sheet(isPresented: $showExport) { ExportView(date: date) }
        .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
            if let img = shareImage { ShareSheet(items: [img]) }
        }
        .confirmationDialog(slotChoice.map { store.kind.slotName($0) } ?? "", isPresented: Binding(get: { slotChoice != nil }, set: { if !$0 { slotChoice = nil } }), titleVisibility: .visible) {
            if let s = slotChoice {
                ForEach(store.meals(on: date).filter { $0.slot == s }) { m in
                    Button(m.title.isEmpty ? "\(m.time) 的记录" : "\(m.title) · \(m.time)") { detail = IDBox(id: m.id) }
                }
                Button("再记一份") { addReq = AddRequest(slot: s) }
            }
        }
        .onAppear { note = store.day(date).note }
        .onChange(of: date) { _, d in note = store.day(d).note; selected = nil }
        .onChange(of: store.currentID) { _, _ in note = store.day(date).note; selected = nil }
        .onReceive(timer) { tick = $0 }
        .onChange(of: store.openAdd) { _, v in
            if v { store.openAdd = false; addReq = AddRequest(slot: MealSlot.guess()) }
        }
    }

    // MARK: 顶部

    private static let cnMonths = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]

    private var header: some View {
        let week = D.cal.component(.weekOfYear, from: D.date(date))
        let isToday = date == D.today
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.cnMonths[D.month(date) - 1]) · 第 \(week) 周")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2)
                Text(isToday ? "今天" : "\(D.month(date))月\(D.day(date))日")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
            }
            Spacer()
            MemberMenu(compact: true)
        }
        .padding(.top, 8)
    }

    /// 一周日期条：点任意一天切换；左右按钮翻周
    private var weekStrip: some View {
        let start = D.weekStart(date)
        let days = (0..<7).map { D.add(start, $0) }
        return HStack(spacing: 0) {
            Button { date = D.add(date, -7) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
                    .frame(width: 22, height: 52).contentShape(Rectangle())
            }
            .accessibilityLabel("上一周")
            ForEach(days, id: \.self) { d in
                let sel = d == date
                let has = !store.meals(on: d).isEmpty
                let future = d > D.today
                Button { withAnimation(.easeInOut(duration: 0.15)) { date = d } } label: {
                    VStack(spacing: 5) {
                        Text(D.weekday(d)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(sel ? Color.white.opacity(0.8) : Color.ink3)
                        Text("\(D.day(d))").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(sel ? Color.white : (future ? Color.ink3 : Color.ink))
                        Circle().fill(has ? (sel ? Color.white : Color.brand) : Color.clear).frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background {
                        if sel { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink) }
                        else if d == D.today { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.line, lineWidth: 1) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { date = D.add(date, 7) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
                    .frame(width: 22, height: 52).contentShape(Rectangle())
            }
            .accessibilityLabel("下一周")
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .surface()
    }

    // MARK: 餐次（一字排开）

    private var slotRow: some View {
        let ms = store.meals(on: date)
        let kind = store.kind
        return HStack(spacing: 8) {
            ForEach(MealSlot.allCases) { s in
                let sm = ms.filter { $0.slot == s }.sorted { $0.time < $1.time }
                slotTile(s, sm, kind: kind)
            }
        }
    }

    private func slotTile(_ s: MealSlot, _ sm: [Meal], kind: MemberKind) -> some View {
        let done = !sm.isEmpty
        let k = sm.reduce(0) { $0 + $1.kcal }
        let pending = sm.contains { $0.status == .pending }
        let r = store.member.reminders
        return ZStack(alignment: .topTrailing) {
            Button {
                if sm.isEmpty { addReq = AddRequest(slot: s) }
                else if sm.count == 1 { detail = IDBox(id: sm[0].id) }
                else { slotChoice = s }
            } label: {
                VStack(spacing: 6) {
                    Group {
                        if let m = sm.first, let img = store.image(m.sticker) {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else if let m = sm.first {
                            Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: 24))
                        } else {
                            Image(systemName: kind.slotSymbol(s)).font(.system(size: 18, weight: .regular)).foregroundStyle(Color.ink3)
                        }
                    }
                    .frame(width: 40, height: 40)
                    Text(kind.slotName(s)).font(.system(size: 13, weight: .semibold)).foregroundStyle(done ? Color.ink : Color.ink2)
                    Group {
                        if pending { Text("识别中").foregroundStyle(Color.ink3) }
                        else if done { Text(k > 0 ? "\(Int(k)) 千卡" : "\(sm.count) 条").foregroundStyle(Color.brand) }
                        else { Text(s == .snack ? "随时" : D.hm(r.minutes(for: s))).foregroundStyle(Color.ink3) }
                    }
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .surface(done ? Color.card : Color.card.opacity(0.6), radius: 14)
            .overlay {
                if !done {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.ink3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .allowsHitTesting(false)
                }
            }
            if done {
                Button { addReq = AddRequest(slot: s) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.brand)
                        .frame(width: 22, height: 22).background(Color.brandSoft).clipShape(Circle())
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .accessibilityLabel("再记一份\(kind.slotName(s))")
            }
        }
    }

    // MARK: 提醒横幅

    @ViewBuilder private var banner: some View {
        let _ = tick
        let m = store.member
        if date == D.today, m.reminders.on {
            let r = m.reminders
            let now = D.nowMinutes
            let recorded = Set(store.meals(on: date).map(\.slot))
            let verb = m.kind.isPet ? "喂" : "用"
            if let due = MealSlot.mains.first(where: { !recorded.contains($0) && now >= r.minutes(for: $0) && now < r.minutes(for: $0) + 150 }) {
                bannerBox(symbol: "bell", title: m.kind == .me ? "\(due.name)时间" : "\(m.displayName)的\(m.kind.slotName(due))时间",
                          sub: m.kind.isPet ? "喂食后拍一张，记录进食情况" : "\(verb)餐后拍照记录，分析会更准确",
                          tint: .brand, button: "记录") { addReq = AddRequest(slot: due, mode: .camera) }
                    .padding(.top, 12)
            } else if let missed = MealSlot.mains.first(where: { !recorded.contains($0) && now >= r.minutes(for: $0) + 150 && ($0 != .breakfast || now < 15 * 60) }) {
                bannerBox(symbol: "exclamationmark.circle", title: "\(m.kind.slotName(missed))尚未记录", sub: "漏记会影响本周的膳食评估",
                          tint: .butter, button: "补记") { addReq = AddRequest(slot: missed) }
                    .padding(.top, 12)
            } else if let next = MealSlot.mains.first(where: { !recorded.contains($0) && r.minutes(for: $0) > now }) {
                let left = r.minutes(for: next) - now
                bannerBox(symbol: "clock", title: "下一餐 · \(m.kind.slotName(next)) \(D.hm(r.minutes(for: next)))",
                          sub: "还有 \(left / 60 > 0 ? "\(left / 60) 小时 " : "")\(left % 60) 分钟",
                          tint: .ink2, button: m.kind.isPet ? "喂什么" : "吃什么") { showNext = true }
                    .padding(.top, 12)
            }
        }
    }

    private func bannerBox(symbol: String, title: String, sub: String, tint: Color, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.1)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink)
                Text(sub).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: action) {
                HStack(spacing: 2) {
                    Text(button)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand)
                .padding(.vertical, 8).padding(.leading, 8)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .surface(radius: 14)
    }

    // MARK: 手账页

    private var paper: some View {
        VStack(spacing: 10) {
            PaperView(date: date, selected: $selected, onOpen: { detail = IDBox(id: $0) }, onPinch: { pinching = $0 })
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
                .shadow(color: Color(red: 0.25, green: 0.18, blue: 0.08).opacity(0.14), radius: 16, y: 10)
                .overlay(alignment: .bottomTrailing) {
                    Button { showPaper = true } label: {
                        Image(systemName: "swatchpalette").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.ink2)
                            .frame(width: 30, height: 30).background(.regularMaterial).clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.line, lineWidth: 0.5))
                    }
                    .padding(10)
                    .padding(.bottom, 22)
                    .accessibilityLabel("更换手账背景")
                }
            stickerTools
        }
    }

    @ViewBuilder private var stickerTools: some View {
        if let id = selected, store.meal(id)?.date == date {
            HStack(spacing: 0) {
                tool("square.3.layers.3d.top.filled", "置顶") {
                    let z = (store.meals(on: date).map(\.z).max() ?? 0) + 1
                    store.update(id) { $0.z = z }
                }
                Rectangle().fill(Color.line).frame(width: 0.5, height: 26)
                tool("arrow.uturn.backward", "摆正") { store.update(id) { $0.rot = 0 } }
                Rectangle().fill(Color.line).frame(width: 0.5, height: 26)
                tool("info.circle", "详情") { detail = IDBox(id: id) }
                Rectangle().fill(Color.line).frame(width: 0.5, height: 26)
                tool("checkmark", "完成", tint: .brand) { withAnimation { selected = nil } }
            }
            .surface(radius: 14)
            Text("拖动调整位置，双指缩放或旋转").font(.system(size: 11)).foregroundStyle(Color.ink3)
        } else if !store.meals(on: date).isEmpty {
            Text("轻点贴纸即可编辑").font(.system(size: 11)).foregroundStyle(Color.ink3)
        }
    }

    private func tool(_ icon: String, _ label: String, tint: Color = .ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 摄入汇总

    private var summaryCard: some View {
        let ms = store.meals(on: date)
        let a = Nutrition.aggregate(ms)
        let t = Double(store.kcalTarget)
        let left = t - a.kcal
        let pet = isPet ? Nutrition.petStats(ms, member: store.member) : nil
        let pT = t * (isPet ? 0.25 : 0.15) / 4, cT = t * (isPet ? 0.45 : 0.55) / 4, fT = t * (isPet ? 0.30 : 0.25) / 9
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                stat("已摄入", "\(Int(a.kcal))", "千卡")
                vline
                stat(left >= 0 ? "剩余" : "超出", "\(Int(abs(left)))", "千卡", tint: left < -t * 0.1 ? .tomato : .ink)
                vline
                if let pet {
                    stat("零食占比", "\(Int(pet.treatShare * 100))", "%", tint: pet.treatShare > 0.1 ? .tomato : .ink)
                } else {
                    stat("饮水", "\(store.day(date).water)", "/ \(store.settings.waterGoal) 杯")
                }
            }
            // 宏量营养素堆叠条
            GeometryReader { g in
                let W = g.size.width
                let total = max(t, a.kcal)
                let segs: [(Double, Color)] = [(a.protein * 4, .berry), (a.carbs * 4, .butter), (a.fat * 9, .sky)]
                HStack(spacing: 2) {
                    ForEach(segs.indices, id: \.self) { j in
                        let sg = segs[j]
                        if sg.0 > 0 { Rectangle().fill(sg.1).frame(width: max(2, W * sg.0 / total - 2)) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: W, height: 8)
                .background(Color.fill)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
            }
            .frame(height: 8)
            HStack(spacing: 0) {
                legend("蛋白质", a.protein, pT, .berry)
                legend("碳水", a.carbs, cT, .butter)
                legend("脂肪", a.fat, fT, .sky)
            }
            if a.count > a.analyzed {
                Label("\(a.count - a.analyzed) 餐尚未完成识别，数据暂未计入", systemImage: "hourglass")
                    .font(.system(size: 12)).foregroundStyle(Color.ink2)
            }
            ForEach(ms.filter { ($0.danger ?? "").isEmpty == false }) { m in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tomato)
                    Text(m.danger ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.tomato)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tomatoSoft).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .surface()
    }

    private var vline: some View { Rectangle().fill(Color.line).frame(width: 0.5, height: 36) }

    private func stat(_ label: String, _ value: String, _ unit: String, tint: Color = .ink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
                Text(unit).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    private func legend(_ name: String, _ v: Double, _ target: Double, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(name).foregroundStyle(Color.ink2)
            Text("\(Int(v))/\(Int(target))g").foregroundStyle(Color.ink).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 洞察

    @ViewBuilder private var insights: some View {
        if date == D.today {
            let tips = Nutrition.tips(store: store, dates: D.weekDates(offset: 0))
            if !tips.isEmpty {
                SectionHeader(title: "饮食洞察", action: "查看分析") { tab = .nutrition }
                VStack(spacing: 0) {
                    let top = Array(tips.prefix(3))
                    ForEach(top.indices, id: \.self) { i in
                        let t = top[i]
                        if i > 0 { Rectangle().fill(Color.line).frame(height: 0.5).padding(.leading, 58) }
                        TipRow(emoji: t.emoji, title: t.title, detail: t.detail).padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
                .surface()
                .padding(.top, 8)
            }
        }
    }

    // MARK: 饮水

    private var waterCard: some View {
        let w = store.day(date).water
        let goal = max(1, store.settings.waterGoal)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "drop").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.sky)
                    .frame(width: 32, height: 32).background(Color.sky.opacity(0.1)).clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(w)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        Text("/ \(goal) 杯").font(.system(size: 12)).foregroundStyle(Color.ink3)
                    }
                    Text(w >= goal ? "今日饮水已达标" : "约 \(w * 250) 毫升，还差 \(goal - w) 杯").font(.system(size: 12)).foregroundStyle(Color.ink2)
                }
                Spacer()
                HStack(spacing: 0) {
                    waterStep("minus", "少一杯") { store.setDay(date) { $0.water = max(0, $0.water - 1) } }
                        .disabled(w == 0)
                    Rectangle().fill(Color.line).frame(width: 0.5, height: 18)
                    waterStep("plus", "多一杯") { store.setDay(date) { $0.water += 1 } }
                }
                .background(Color.fill).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
            }
            HStack(spacing: 4) {
                ForEach(0..<goal, id: \.self) { i in
                    Capsule().fill(i < w ? Color.sky : Color.fill).frame(height: 5)
                        .overlay(Capsule().strokeBorder(i < w ? Color.clear : Color.line, lineWidth: 0.5))
                }
            }
        }
        .padding(14)
        .surface()
    }

    private func waterStep(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                .frame(width: 40, height: 32).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: 小记

    static func moods(pet: Bool) -> [(String, String)] {
        pet ? [("😸", "精神好"), ("🐾", "正常"), ("😴", "犯困"), ("🤒", "不适"), ("😾", "挑食")]
            : [("😋", "满足"), ("😊", "不错"), ("😐", "一般"), ("😮‍💨", "撑了"), ("🤢", "不适")]
    }

    private var diaryCard: some View {
        let moods = Self.moods(pet: isPet)
        let cur = store.day(date).mood
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ForEach(moods.indices, id: \.self) { k in
                    let e = moods[k]
                    let on = cur == e.0
                    Button { store.setDay(date) { $0.mood = $0.mood == e.0 ? "" : e.0 } } label: {
                        VStack(spacing: 4) {
                            Text(e.0).font(.system(size: 22)).opacity(on || cur.isEmpty ? 1 : 0.45)
                            Text(e.1).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.ink : Color.ink3)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? Color.fill : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.line : Color.clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField(isPet ? "精神状态、食欲、排便情况…" : "记录今天的饮食感受…", text: $note, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(3...8)
                .focused($noteFocused)
                .padding(12)
                .background(Color.fill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
                .onChange(of: note) { _, v in
                    // 边输入边保存，切换日期、切到后台都不会丢
                    if store.day(date).note != v { store.setDay(date) { $0.note = String(v.prefix(500)) } }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { noteFocused = false }.fontWeight(.semibold)
                    }
                }
            HStack(spacing: 4) {
                if !store.day(date).note.isEmpty || !cur.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.brand)
                    Text("已自动保存，导出手账时会一起带上").font(.system(size: 11)).foregroundStyle(Color.ink3)
                } else {
                    Text("心情和小记会自动保存，并出现在导出的手账图片里").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
        }
        .padding(14)
        .surface()
    }

    @MainActor private func exportImage() {
        let d = store.day(date)
        guard !store.meals(on: date).isEmpty || !d.note.isEmpty || !d.mood.isEmpty else { store.flash("这一天还没有记录"); return }
        if noteFocused { noteFocused = false }
        store.setDay(date) { $0.note = note }
        showExport = true
    }
}

/// 列表行按下时的轻微反馈
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.black.opacity(configuration.isPressed ? 0.035 : 0))
    }
}

// MARK: - 手账页（贴纸可拖动、双指缩放旋转）

struct PaperView: View {
    @EnvironmentObject var store: Store
    let date: String
    @Binding var selected: String?
    var interactive = true
    var onOpen: (String) -> Void = { _ in }
    var onPinch: (Bool) -> Void = { _ in }

    @State private var dragID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var liveScale: CGFloat = 1
    @State private var liveAngle: Angle = .zero
    @State private var decoDrag: String?
    @State private var decoOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let meals = store.meals(on: date)
            let member = store.member
            let log = store.day(date)
            let paper = PaperStyle(rawValue: log.paper ?? "") ?? member.paper
            let decos = log.decos ?? []
            ZStack(alignment: .topLeading) {
                PaperBackground(style: paper, imageName: member.paperImage)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = nil } }
                Grain(opacity: 0.8)
                Tape(color: Color(red: 0.86, green: 0.82, blue: 0.70).opacity(0.75)).rotationEffect(.degrees(-3)).position(x: W / 2, y: 9)
                VStack(spacing: 4) {
                    Text(String(format: "%02d.%02d", D.month(date), D.day(date)))
                        .font(.system(size: W * 0.085, weight: .medium, design: .serif))
                        .foregroundStyle(Color.ink)
                    Text((log.title ?? "").isEmpty ? "\(member.displayName) · 星期\(D.weekday(date)) \(log.mood)" : "\(log.title ?? "") · 星期\(D.weekday(date)) \(log.mood)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink2)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(paper == .custom ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(width: W)
                .padding(.top, H * 0.045)
                .allowsHitTesting(false)

                if meals.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 26, weight: .light))
                        Text(member.kind.isPet ? "拍下\(member.displayName)的饭碗，生成第一张贴纸" : "拍下这一餐，生成第一张贴纸")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color.ink3)
                        .frame(width: W).position(x: W / 2, y: H * 0.56)
                        .allowsHitTesting(false)
                }

                ForEach(decos.filter { $0.kind != "tape" }) { d in decoItem(d, W: W, H: H) }

                ForEach(meals) { m in
                    sticker(m, W: W, H: H)
                }

                ForEach(decos.filter { $0.kind == "tape" }) { d in decoItem(d, W: W, H: H).zIndex(2000) }

                if let c = log.caption, !c.isEmpty {
                    Text(c).font(.system(size: 12.5, design: .serif)).italic().foregroundStyle(Color.ink2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(paper == .custom ? Color.white.opacity(0.7) : Color.clear).clipShape(Capsule())
                        .frame(width: W - 28).position(x: W / 2, y: H - 34)
                        .allowsHitTesting(false)
                }

                HStack {
                    Text(meals.isEmpty ? "" : "\(meals.count) 餐")
                    Spacer()
                    let k = meals.reduce(0) { $0 + $1.kcal }
                    Text(k > 0 ? "约 \(Int(k)) 千卡" : "食贴")
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink3)
                .padding(.horizontal, 14)
                .frame(width: W)
                .position(x: W / 2, y: H - 14)
                .allowsHitTesting(false)
            }
            .simultaneousGesture(pinchRotate(meals: meals, W: W, H: H), including: interactive ? .all : .subviews)
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 装饰物：拖动挪位置，长按删除
    private func decoItem(_ d: Deco, W: CGFloat, H: CGFloat) -> some View {
        let isDrag = decoDrag == d.id
        return DecoView(deco: d, W: W)
            .position(x: CGFloat(d.x) * W + (isDrag ? decoOffset.width : 0), y: CGFloat(d.y) * H + (isDrag ? decoOffset.height : 0))
            .allowsHitTesting(interactive)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in decoDrag = d.id; decoOffset = v.translation }
                    .onEnded { v in
                        store.setDay(date) { log in
                            guard var list = log.decos, let i = list.firstIndex(where: { $0.id == d.id }) else { return }
                            list[i].x = min(0.97, max(0.03, d.x + v.translation.width / W))
                            list[i].y = min(0.97, max(0.03, d.y + v.translation.height / H))
                            log.decos = list
                        }
                        decoDrag = nil
                        decoOffset = .zero
                    }
            )
            .contextMenu {
                Button(role: .destructive) {
                    store.setDay(date) { log in log.decos?.removeAll { $0.id == d.id } }
                } label: { Label("删除这个装饰", systemImage: "trash") }
                Button(role: .destructive) {
                    store.setDay(date) { log in log.decos = nil; log.title = nil; log.caption = nil; log.paper = nil }
                } label: { Label("清空全部装饰", systemImage: "eraser") }
            }
    }

    /// 双指：捏合缩放 + 拧动旋转，作用在选中的贴纸上；没选中时自动选手指附近的那张
    private func pinchRotate(meals: [Meal], W: CGFloat, H: CGFloat) -> some Gesture {
        MagnifyGesture()
            .simultaneously(with: RotateGesture())
            .onChanged { v in
                if selected == nil, let loc = v.first?.startLocation {
                    func dist(_ m: Meal) -> CGFloat { hypot(CGFloat(m.x) * W - loc.x, CGFloat(m.y) * H - loc.y) }
                    if let n = meals.min(by: { dist($0) < dist($1) }), dist(n) < CGFloat(n.scale) * W * 0.8 { selected = n.id }
                }
                guard selected != nil else { return }
                onPinch(true)
                liveScale = v.first?.magnification ?? 1
                liveAngle = v.second?.rotation ?? .zero
            }
            .onEnded { _ in
                if let id = selected, let m = store.meal(id) {
                    let ns: Double = min(0.8, max(0.14, m.scale * Double(liveScale)))
                    let nr = m.rot + liveAngle.degrees
                    store.update(id) { $0.scale = ns; $0.rot = nr }
                }
                liveScale = 1
                liveAngle = .zero
                onPinch(false)
            }
    }

    @ViewBuilder
    private func sticker(_ m: Meal, W: CGFloat, H: CGFloat) -> some View {
        let isDrag = dragID == m.id
        let isSel = selected == m.id
        let x = CGFloat(m.x) * W + (isDrag ? dragOffset.width : 0)
        let y = CGFloat(m.y) * H + (isDrag ? dragOffset.height : 0)
        let scale = CGFloat(m.scale) * (isSel ? liveScale : 1)
        let rot = m.rot + (isSel ? liveAngle.degrees : 0)
        let caption = m.status == .pending ? "识别中…" : (m.title.isEmpty ? store.kind.slotName(m.slot) : m.title)
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let img = store.image(m.sticker) {
                    Image(uiImage: img).resizable().scaledToFit()
                        .shadow(color: Color(red: 0.31, green: 0.2, blue: 0.08).opacity(0.25), radius: 3, y: 3)
                } else {
                    Text(m.emoji.isEmpty ? "🍽️" : m.emoji).font(.system(size: 50))
                }
                if m.status == .pending { ProgressView().controlSize(.mini).padding(4).background(.regularMaterial).clipShape(Circle()).offset(x: 4, y: -4) }
                if !(m.danger ?? "").isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Color.tomato).offset(x: 6, y: -6) }
            }
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink2)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(store.member.paper == .custom ? Color.white.opacity(0.75) : Color.clear)
                .clipShape(Capsule())
        }
        .padding(6)
        .overlay {
            if isSel {
                RoundedRectangle(cornerRadius: 10).stroke(Color.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
        }
        .frame(width: W * scale + 12)
        .scaleEffect(isDrag ? 1.05 : 1)
        .rotationEffect(.degrees(rot))
        .position(x: x, y: y)
        .zIndex(isSel || isDrag ? 1000 : Double(m.z))
        .allowsHitTesting(interactive)
        .onTapGesture {
            if selected == m.id { onOpen(m.id) } else { withAnimation(.easeOut(duration: 0.15)) { selected = m.id } }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if selected != m.id { selected = m.id }
                    dragID = m.id
                    dragOffset = v.translation
                }
                .onEnded { v in
                    let nx = min(0.94, max(0.06, m.x + v.translation.width / W))
                    let ny = min(0.95, max(0.14, m.y + v.translation.height / H))
                    let z = (store.meals(on: date).map(\.z).max() ?? 0) + 1
                    store.update(m.id) { $0.x = nx; $0.y = ny; $0.z = z }
                    dragID = nil
                    dragOffset = .zero
                }
        )
    }
}

// MARK: - 选手账背景

struct PaperPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(PaperStyle.presets) { p in
                            Button {
                                store.updateMember(store.currentID) { $0.paper = p }
                            } label: { swatch(p) }
                            .buttonStyle(.plain)
                        }
                        if let img = store.member.paperImage, store.image(img) != nil {
                            Button { store.updateMember(store.currentID) { $0.paper = .custom } } label: { swatch(.custom) }
                                .buttonStyle(.plain)
                        }
                    }
                    PhotosPicker(selection: $item, matching: .images) {
                        Label("从相册选择背景", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(SoftButton())
                    Text("背景只对「\(store.member.displayName)」的手账生效。").font(.caption).foregroundStyle(Color.ink2)
                }
                .padding(18)
            }
            .background(PageBackground())
            .navigationTitle("手账背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    store.setPaperImage(img, for: store.currentID)
                }
            }
        }
    }

    private func swatch(_ p: PaperStyle) -> some View {
        let on = store.member.paper == p
        return VStack(spacing: 6) {
            PaperBackground(style: p, imageName: store.member.paperImage)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Color.ink : Color.line, lineWidth: on ? 2 : 0.5))
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.ink : Color.ink2)
        }
    }
}
