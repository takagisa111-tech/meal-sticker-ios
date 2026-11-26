import SwiftUI
import Charts

struct NutritionView: View {
    @EnvironmentObject var store: Store
    @State private var offset = 0
    @State private var generating = false

    private var dates: [String] { D.weekDates(offset: offset) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(D.month(dates[0]))月\(D.day(dates[0]))日 – \(D.month(dates[6]))月\(D.day(dates[6]))日").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2).lineLimit(1)
                            Text(store.kind.isPet ? "喂养分析" : "膳食分析").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
                        }
                        Spacer()
                        MemberMenu(compact: true)
                    }
                    .padding(.top, 8)
                    weekNav.padding(.top, 16)
                    let ms = store.meals(in: dates)
                    if ms.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 30, weight: .light)).foregroundStyle(Color.ink3)
                            Text("本周暂无记录").font(.system(size: 16, weight: .semibold))
                            Text(store.kind.isPet ? "记录几餐后，这里会评估\(store.member.displayName)的热量是否合适、零食是否过量，以及有无误食危险食物。" : "记录几餐后，这里会评估膳食结构是否均衡、缺少哪些食物、哪些摄入偏多。")
                                .font(.system(size: 12)).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 20)
                        .surface()
                        .padding(.top, 16)
                    } else {
                        let a = Nutrition.aggregate(ms)
                        tiles(a, ms).padding(.top, 16)
                        if a.count > a.analyzed {
                            Label("\(a.count - a.analyzed) 餐尚未完成识别，未计入统计", systemImage: "hourglass")
                                .font(.system(size: 12)).foregroundStyle(Color.ink2).padding(.top, 10).padding(.horizontal, 4)
                        }
                        if store.kind.isPet {
                            SectionHeader(title: "喂养概况")
                            petCard(ms).padding(.top, 8)
                        } else {
                            SectionHeader(title: "膳食结构")
                            groupsCard(a).padding(.top, 8)
                        }
                        SectionHeader(title: store.kind.isPet ? "每日热量" : "能量与宏量营养素")
                        energyCard(a).padding(.top, 8)
                        SectionHeader(title: store.kind.isPet ? "喂养评估报告" : "膳食评估报告")
                        reportCard(ms.count).padding(.top, 8)
                    }
                    Text(store.kind.isPet ? "数据由照片估算，仅供参考；如有异常请及时就医。" : "营养数据由照片估算，仅供参考，不能替代医生或注册营养师的建议。")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(PageBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var weekNav: some View {
        let label = offset == 0 ? "本周" : (offset == -1 ? "上周" : "\(-offset) 周前")
        return HStack(spacing: 0) {
            Button { offset -= 1 } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 36).contentShape(Rectangle())
            }
            Rectangle().fill(Color.line).frame(width: 0.5, height: 18)
            Text(label).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
            Rectangle().fill(Color.line).frame(width: 0.5, height: 18)
            Button { offset = min(0, offset + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 36).contentShape(Rectangle())
            }
            .opacity(offset >= 0 ? 0.3 : 1).disabled(offset >= 0)
        }
        .foregroundStyle(Color.ink)
        .background(Color.card).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    private func tiles(_ a: Aggregate, _ ms: [Meal]) -> some View {
        let otr = Nutrition.onTimeRate(ms, reminders: store.member.reminders)
        let isPet = store.kind.isPet
        let rows = Nutrition.rows(for: store.kind)
        let good = rows.filter { Nutrition.status(avg: a.value($0) / a.dayCount, row: $0).isGood }.count
        let balance = rows.isEmpty ? 0 : Int(Double(good) / Double(rows.count) * 100)
        return HStack(spacing: 0) {
            if isPet {
                tile("\(Int(a.kcal / a.dayCount))", "日均千卡")
            } else {
                tile("\(balance)", "均衡指数", tint: balance >= 70 ? .brand : (balance >= 40 ? .ink : .tomato))
            }
            Rectangle().fill(Color.line).frame(width: 0.5, height: 34)
            tile("\(a.count)", "记录 \(a.days.count) 天 · 餐")
            Rectangle().fill(Color.line).frame(width: 0.5, height: 34)
            if isPet {
                tile(otr.map { "\($0)%" } ?? "—", "按时喂食")
            } else {
                tile("\(a.names.count)", "食物种类（目标 25）")
            }
        }
        .padding(.vertical, 14)
        .surface()
    }

    private func tile(_ v: String, _ label: String, tint: Color = .ink) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(v).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
    }

    // MARK: 宠物

    private func petCard(_ ms: [Meal]) -> some View {
        let st = Nutrition.petStats(ms, member: store.member)
        let name = store.member.displayName
        let ratio = st.kcalPerDay / Double(max(1, st.target))
        return CardBox {
            CardTitle(text: "\(name) · 本周")
            row("日均热量", "\(Int(st.kcalPerDay)) / \(st.target) kcal", ratio, ok: ratio >= 0.8 && ratio <= 1.15)
            row("零食占比", "\(Int(st.treatShare * 100))%（建议 ≤10%）", st.treatShare / 0.2, ok: st.treatShare <= 0.1)
            row("人吃的饭", "\(st.humanFoodMeals) 次", Double(st.humanFoodMeals) / 5, ok: st.humanFoodMeals < 3)
            if st.dangers.isEmpty {
                Label("本周未记录到危险食物", systemImage: "checkmark.shield").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.brand)
            } else {
                ForEach(Array(st.dangers.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tomato)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(D.month(d.0))月\(D.day(d.0))日").font(.caption.bold())
                            Text(d.1).font(.subheadline)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tomatoSoft).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, _ progress: Double, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 13)).monospacedDigit().foregroundStyle(ok ? Color.ink2 : Color.tomato)
            }
            ProgressBar(value: progress, color: ok ? .brand : .tomato)
        }
    }

    // MARK: 食物分组

    private func groupsCard(_ a: Aggregate) -> some View {
        let dn = a.dayCount
        let rows = Nutrition.rows(for: store.kind)
        let missing = rows.filter { $0.id != "grains" && a.value($0) == 0 }
        let tooMuch = rows.filter { Nutrition.status(avg: a.value($0) / dn, row: $0).isHigh }
        return CardBox {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color.brand.opacity(0.18)).frame(width: 14, height: 8)
                Text("推荐区间 · 参考《中国\(store.kind == .elder ? "老年人" : "居民")膳食指南》，日均摄入量").font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
            ForEach(rows) { r in
                GroupRowView(row: r, avg: a.value(r) / dn)
            }
            if !missing.isEmpty {
                Rectangle().fill(Color.line).frame(height: 0.5).padding(.top, 4)
                Text("本周缺少").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink2)
                FlowLayout { ForEach(missing) { r in Pill(text: "\(r.emoji) \(r.name)", style: .yellow) } }
            }
            if !tooMuch.isEmpty || !a.flags.isEmpty {
                Text("摄入偏多").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink2).padding(.top, 4)
                FlowLayout {
                    ForEach(tooMuch) { r in Pill(text: "\(r.emoji) \(r.name)", style: .red) }
                    ForEach(a.flags.sorted(by: { $0.key < $1.key }), id: \.key) { kv in Pill(text: "\(flagNames[kv.key] ?? kv.key) ×\(kv.value)", style: .red) }
                }
            }
        }
    }

    // MARK: 能量

    private func energyCard(_ a: Aggregate) -> some View {
        let target = Double(store.kcalTarget)
        let perDay = dates.map { d in (d, Nutrition.aggregate(store.meals(on: d)).kcal) }
        let eP = a.protein * 4, eC = a.carbs * 4, eF = a.fat * 9
        let eT = max(1, eP + eC + eF)
        return CardBox {
            Chart {
                ForEach(perDay, id: \.0) { item in
                    BarMark(x: .value("日", "周" + D.weekday(item.0)), y: .value("kcal", item.1))
                        .foregroundStyle(item.1 > target * 1.1 ? Color.tomato : Color.brand.opacity(item.0 == D.today ? 1 : 0.75))
                        .cornerRadius(4)
                }
                RuleMark(y: .value("目标", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.ink.opacity(0.35))
                    .annotation(position: .top, alignment: .trailing) { Text("推荐 \(Int(target)) 千卡").font(.system(size: 10)).foregroundStyle(Color.ink2) }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.line); AxisValueLabel().font(.system(size: 10)).foregroundStyle(Color.ink3) } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 10)).foregroundStyle(Color.ink2) } }
            .frame(height: 160)
            if !store.kind.isPet {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.butter).frame(width: g.size.width * eC / eT)
                    Rectangle().fill(Color.berry).frame(width: g.size.width * eP / eT)
                    Rectangle().fill(Color.sky).frame(width: g.size.width * eF / eT)
                }
            }
            .frame(height: 8).clipShape(Capsule())
            FlowLayout(spacing: 10) {
                legend(.butter, "碳水化合物 \(Int(eC / eT * 100))%（推荐 50–65）")
                legend(.berry, "蛋白质 \(Int(eP / eT * 100))%（10–20）")
                legend(.sky, "脂肪 \(Int(eF / eT * 100))%（20–30）")
            }
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 11)).foregroundStyle(Color.ink2)
        }
    }

    // MARK: AI 周报

    private func reportCard(_ mealCount: Int) -> some View {
        let key = dates[0]
        let rep = store.report(key)
        return CardBox {
            if let r = rep {
                ReportView(report: r, stale: r.mealCount != mealCount)
            } else {
                Text(store.kind.isPet ? "基于本周每一餐的记录，评估热量与零食是否合适、有无误食风险，并给出后续喂养建议。" : "基于本周每一餐的记录，评估膳食是否均衡、缺少与偏多的食物，并给出后续几餐的搭配建议和采购清单。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2)
            }
            Button {
                Task { await generate(key: key) }
            } label: {
                HStack {
                    if generating { ProgressView().tint(rep == nil ? .white : .ink) }
                    Text(generating ? "正在分析…" : (rep == nil ? "生成评估报告" : "重新生成"))
                }
            }
            .buttonStyle(ReportButton(primary: rep == nil))
            .disabled(generating)
        }
    }

    private func generate(key: String) async {
        generating = true
        let (ctx, n) = Nutrition.weekContext(store: store, dates: dates)
        let rk = store.reportKey(key)
        do {
            let r = try await AI.weeklyReport(context: ctx, member: store.member, key: store.apiKey, mealCount: n)
            store.reports[rk] = r
        } catch {
            store.flash((error as? AIError)?.message ?? error.localizedDescription)
        }
        generating = false
    }
}

struct GroupRowView: View {
    let row: GuideRow
    let avg: Double
    var body: some View {
        let st = Nutrition.status(avg: avg, row: row)
        let scale = row.max * 1.6
        let color: Color = st.isGood ? .brand : (st.isWarn ? .butter : .tomato)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.ink)
                Text("\(Int(avg)) g").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.ink3)
            }
            .frame(width: 78, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.fill)
                    Rectangle().fill(Color.brand.opacity(0.14))
                        .frame(width: g.size.width * (row.max - row.min) / scale)
                        .offset(x: g.size.width * row.min / scale)
                    Capsule().fill(color)
                        .frame(width: max(0, min(1, avg / scale)) * g.size.width)
                        .padding(.vertical, 1.5)
                }
                .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
            }
            .frame(height: 8)
            Text(st.text).font(.system(size: 12, weight: .medium)).foregroundStyle(color == .brand ? Color.ink2 : color)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// 打开「去买菜」页（选平台、逐项搜索、或加到提醒事项）
struct ShoppingButton: View {
    let items: [String]
    var label: String = "去买菜"
    var prominent = false
    @State private var show = false
    var body: some View {
        Group {
            if prominent {
                Button { show = true } label: { Label(label, systemImage: "cart") }.buttonStyle(PrimaryButton())
            } else {
                Button { show = true } label: {
                    Label(label, systemImage: "cart").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.brand)
            }
        }
        .sheet(isPresented: $show) { GroceryView(items: items) }
    }
}

struct ReportView: View {
    let report: WeekReport
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text("\(report.score)").font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(Color.ink)
                    Text("综合评分").font(.system(size: 10)).foregroundStyle(Color.ink3)
                }
                .padding(.trailing, 14)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 0.5) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.headline).font(.system(size: 15, weight: .semibold))
                    Text(report.at.formatted(date: .abbreviated, time: .shortened) + " 生成" + (stale ? " · 之后又记了新的餐，可以重新生成" : ""))
                        .font(.caption2).foregroundStyle(Color.ink2)
                }
            }
            if !report.good.isEmpty {
                section("做得好的")
                ForEach(report.good, id: \.self) { TipRow(emoji: "✓", title: $0, detail: "") }
            }
            if !report.missing.isEmpty {
                section("建议补充")
                ForEach(report.missing, id: \.self) { TipRow(emoji: "＋", title: $0.item, detail: $0.advice) }
            }
            if !report.tooMuch.isEmpty {
                section("建议减少")
                ForEach(report.tooMuch, id: \.self) { TipRow(emoji: "－", title: $0.item, detail: $0.advice) }
            }
            if !report.plan.isEmpty {
                section("后续搭配建议")
                ForEach(report.plan, id: \.self) { p in
                    TipRow(emoji: p.emoji.isEmpty ? "🍽️" : p.emoji, title: "\(p.when)：\(p.dish)", detail: p.why)
                }
            }
            if !report.shopping.isEmpty {
                section("采购清单")
                FlowLayout { ForEach(report.shopping, id: \.self) { Pill(text: $0, style: .green) } }
                ShoppingButton(items: report.shopping)
            }
            if !report.habit.isEmpty {
                section("饮食规律")
                Text(report.habit).font(.system(size: 13)).foregroundStyle(Color.ink)
            }
        }
    }

    private func section(_ t: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.line).frame(height: 0.5)
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink2)
        }
        .padding(.top, 4)
    }
}

struct ReportButton: ButtonStyle {
    let primary: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if primary {
            PrimaryButton().makeBody(configuration: configuration)
        } else {
            SoftButton().makeBody(configuration: configuration)
        }
    }
}
