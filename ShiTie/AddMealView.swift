import SwiftUI
import PhotosUI
import UIKit

/// 记录方式：从今日页的快捷入口直接进入对应流程
enum AddMode: String, Identifiable { case menu, camera, library, takeout, reuse, text; var id: String { rawValue } }

/// 打开记录页的请求（餐次 + 方式）
struct AddRequest: Identifiable {
    let slot: MealSlot
    var mode: AddMode = .menu
    var id: String { slot.rawValue + mode.rawValue }
}

struct AddMealView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let date: String
    @State var slot: MealSlot
    let mode: AddMode
    @State private var started = false
    @State private var showLibrary = false
    @State private var showTakeout = false

    init(date: String, slot: MealSlot, mode: AddMode = .menu) {
        self.date = date
        self.mode = mode
        _slot = State(initialValue: slot)
    }

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var base: UIImage?
    @State private var lifted: UIImage?
    @State private var shape: StickerShape = .lift
    @State private var transparent = false
    @State private var processing = false
    @State private var memo = ""
    @State private var textMode = false
    @State private var text = ""
    @State private var saving = false
    @State private var preview: UIImage?
    @State private var takeoutItem: PhotosPickerItem?
    @State private var reuseMode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("餐次", selection: $slot) {
                        ForEach(MealSlot.allCases) { s in Text(store.kind.slotName(s)).tag(s) }
                    }
                    .pickerStyle(.segmented)

                    if base != nil || processing {
                        editor
                    } else if reuseMode {
                        reuseList
                    } else if textMode {
                        textEditor
                    } else {
                        sources
                    }
                }
                .padding(18)
            }
            .background(PageBackground())
            .navigationTitle(store.kind.isPet ? "记录进食" : "记录一餐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(store.kind.isPet ? "记录进食" : "记录一餐").font(.system(size: 16, weight: .semibold))
                        Text("\(store.member.displayName) · \(D.month(date))月\(D.day(date))日").font(.system(size: 11)).foregroundStyle(Color.ink2)
                    }
                }
            }
        }
        .tint(Color.brand)
        .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
        .photosPicker(isPresented: $showTakeout, selection: $takeoutItem, matching: .images)
        .onAppear {
            guard !started else { return }
            started = true
            if mode == .reuse { reuseMode = true }
            if mode == .text { textMode = true }
            // 等 sheet 完全弹出后再打开相机/相册，避免两层弹窗冲突
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            switch mode {
            case .camera:
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true } else { showLibrary = true }
            case .library: showLibrary = true
            case .takeout: showTakeout = true
            default: break
            }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await load(img) } }.ignoresSafeArea()
        }
        .onChange(of: takeoutItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                    store.flash("截图读不出来，换一张试试"); return
                }
                let shot = StickerMaker.normalized(img, maxSide: 1600)
                let m = store.addMeal(date: date, slot: slot, sticker: StickerMaker.emojiSticker("🛵"), title: "外卖")
                store.update(m.id) { $0.source = "takeout" }
                dismiss()
                await store.analyze(m.id, image: shot, takeout: true)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                processing = true
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await load(img)
                } else {
                    processing = false
                    store.flash("这张图片读不出来，换一张试试")
                }
            }
        }
    }

    // MARK: 选择来源

    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("拍照记录").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2).padding(.horizontal, 4).padding(.bottom, 8).padding(.top, 6)
            VStack(spacing: 0) {
                Button { showCamera = true } label: {
                    option("camera", "拍照", "自动识别主体，生成贴纸")
                }
                hairline
                Button { showLibrary = true } label: {
                    option("photo.on.rectangle", "从相册选择", "选取这一餐的照片")
                }
                hairline
                Button {
                    if let img = UIPasteboard.general.image { Task { await load(img) } }
                    else { store.flash("剪贴板里没有图片") }
                } label: {
                    option("doc.on.clipboard", "粘贴已抠好的图片", "在相册中长按主体 → 拷贝，再回到这里")
                }
            }
            .surface()

            Text("其他方式").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2).padding(.horizontal, 4).padding(.bottom, 8).padding(.top, 20)
            VStack(spacing: 0) {
                if !store.kind.isPet {
                    Button { showTakeout = true } label: {
                        option("bag", "外卖订单截图", "读取美团、饿了么订单中的菜品与份量")
                    }
                    hairline
                }
                Button { reuseMode = true } label: {
                    option("arrow.counterclockwise", "常吃的", "一键复用以往的记录和营养数据")
                }
                hairline
                Button { textMode = true } label: {
                    option("text.alignleft", "文字描述", "描述吃了什么，自动估算营养")
                }
            }
            .surface()
        }
        .foregroundStyle(Color.ink)
    }

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: 0.5).padding(.leading, 62)
    }

    private func option(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.brand)
                .frame(width: 34, height: 34).background(Color.brandSoft).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(sub).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: 贴纸编辑

    @MainActor
    private func load(_ img: UIImage) async {
        processing = true
        let b = StickerMaker.normalized(img)
        base = b
        transparent = StickerMaker.hasTransparency(b)
        if transparent {
            shape = .original
        } else {
            lifted = await StickerMaker.liftSubject(b)
            shape = lifted == nil ? .circle : .lift
            if lifted == nil { store.flash("没找到明显的主体，先用圆形贴纸") }
        }
        updatePreview()
        processing = false
    }

    private func updatePreview() {
        guard let b = base else { preview = nil; return }
        preview = StickerMaker.make(b, shape: shape, lifted: lifted)
    }

    private var shapes: [StickerShape] {
        transparent ? [.original, .circle, .rounded] : [.lift, .circle, .rounded]
    }

    @ViewBuilder private var editor: some View {
        if processing || base == nil {
            HStack(spacing: 10) { ProgressView(); Text("正在抠图…").foregroundStyle(Color.ink2) }
                .frame(maxWidth: .infinity, minHeight: 260)
        } else if let b = base, let preview {
            Picker("样式", selection: $shape) {
                ForEach(shapes) { s in Text(s.name).tag(s) }
            }
            .pickerStyle(.segmented)
            .onChange(of: shape) { _, _ in updatePreview() }
            ZStack {
                Checkerboard()
                Image(uiImage: preview).resizable().scaledToFit().padding(24)
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 4)
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("备注（选填，可提高识别准确度）").font(.caption).foregroundStyle(Color.ink2)
            TextField("比如：饭只吃了一半、少油", text: $memo)
                .padding(10).surface(radius: 12)

            Button {
                saving = true
                let m = store.addMeal(date: date, slot: slot, sticker: preview, note: memo)
                store.update(m.id) { $0.source = "photo" }
                if store.settings.autoAI {
                    let img = b
                    Task { await store.analyze(m.id, image: img) }
                }
                dismiss()
            } label: {
                Text("贴到手账")
            }
            .buttonStyle(PrimaryButton())
            .disabled(saving)

            Button("换一张") { base = nil; lifted = nil; pickerItem = nil }
                .font(.subheadline).foregroundStyle(Color.ink2).frame(maxWidth: .infinity)
        }
    }

    // MARK: 常吃的

    @ViewBuilder private var reuseList: some View {
        let list = store.reuseCandidates
        if list.isEmpty {
            Text("还没有识别过的餐。多记几餐之后，常吃的会出现在这里。").font(.subheadline).foregroundStyle(Color.ink2)
                .padding(.vertical, 30)
        } else {
            VStack(spacing: 8) {
                ForEach(list) { item in
                    Button {
                        if store.duplicate(item.meal, date: date, slot: slot) != nil { dismiss() } else { store.flash("这张贴纸的图片找不到了") }
                    } label: {
                        HStack(spacing: 12) {
                            if let img = store.image(item.meal.sticker) {
                                Image(uiImage: img).resizable().scaledToFit().frame(width: 52, height: 52)
                            } else {
                                Text(item.meal.emoji.isEmpty ? "🍽️" : item.meal.emoji).font(.system(size: 34)).frame(width: 52, height: 52)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.meal.title).font(.system(size: 15, weight: .semibold))
                                Text("吃过 \(item.count) 次 · \(Int(item.meal.kcal)) kcal\(item.meal.shop.map { " · " + $0 } ?? "")")
                                    .font(.caption).foregroundStyle(Color.ink2).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.brand)
                        }
                        .padding(10).surface(radius: 14)
                    }
                    .foregroundStyle(Color.ink)
                }
            }
        }
        Button("返回") { reuseMode = false }.font(.subheadline).foregroundStyle(Color.ink2).frame(maxWidth: .infinity)
    }

    // MARK: 文字记录

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("比如：一碗牛肉面，加了个卤蛋，喝了半碗汤", text: $text, axis: .vertical)
                .lineLimit(4...8)
                .padding(12).surface(radius: 12)
            Button {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { store.flash("先写点什么吧"); return }
                saving = true
                Task {
                    let (emoji, title) = await AI.emojiTitle(for: t, key: store.apiKey)
                    let m = store.addMeal(date: date, slot: slot, sticker: StickerMaker.emojiSticker(emoji), note: t, title: title, emoji: emoji, fromText: true)
                    store.update(m.id) { $0.source = "text" }
                    dismiss()
                    await store.analyze(m.id, image: nil, text: t)
                }
            } label: {
                HStack {
                    if saving { ProgressView().tint(.white) }
                    Text(saving ? "识别中…" : "识别并记录")
                }
            }
            .buttonStyle(PrimaryButton())
            .disabled(saving)
            Button("返回") { textMode = false }.font(.subheadline).foregroundStyle(Color.ink2).frame(maxWidth: .infinity)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(red: 0.953, green: 0.929, blue: 0.89)))
                    x += s * 2
                }
                y += s
                row += 1
            }
        }
        .background(Color.white)
    }
}
