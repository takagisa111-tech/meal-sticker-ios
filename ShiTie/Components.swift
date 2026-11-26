import SwiftUI
import UIKit

struct CardBox<Content: View>: View {
    var tint: Color = .card
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(tint)
    }
}

extension View {
    /// 卡片质感：细边框 + 两层柔和阴影
    func surface(_ tint: Color = .card, radius: CGFloat = 16) -> some View {
        self
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.03), radius: 1, x: 0, y: 1)
            .shadow(color: Color(red: 0.16, green: 0.12, blue: 0.04).opacity(0.07), radius: 12, x: 0, y: 6)
    }
}

/// 卡片外面的分区标题
struct SectionHeader: View {
    let title: String
    var action: String = ""
    var onAction: () -> Void = {}
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink2)
            Spacer()
            if !action.isEmpty {
                Button(action, action: onAction).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }
}

struct CardTitle: View {
    let text: String
    var trailing: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
            Spacer()
            if !trailing.isEmpty { Text(trailing).font(.system(size: 12)).foregroundStyle(Color.ink2) }
        }
    }
}

/// 纸张颗粒质感（生成一次后平铺）
struct Grain: View {
    var opacity: Double = 1
    private static let tile: UIImage = {
        let size = 128
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt).image { ctx in
            var rng = SeededRandom(seed: 42)
            for _ in 0..<2600 {
                let x = CGFloat(rng.next()) * CGFloat(size), y = CGFloat(rng.next()) * CGFloat(size)
                let a = CGFloat(rng.next()) * 0.06
                let dark = rng.next() > 0.45
                (dark ? UIColor(white: 0, alpha: a) : UIColor(white: 1, alpha: a * 1.2)).setFill()
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }()
    var body: some View {
        Image(uiImage: Grain.tile).resizable(resizingMode: .tile).opacity(opacity).allowsHitTesting(false)
    }
}

/// 页面背景：石灰白 + 颗粒
struct PageBackground: View {
    var body: some View {
        ZStack { Color.paper; Grain() }.ignoresSafeArea()
    }
}

/// 统一的按钮样式
struct PrimaryButton: ButtonStyle {
    var color: Color = .brand
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: color.opacity(0.25), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButton: ButtonStyle {
    var color: Color = .ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.fill.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
    }
}

/// 圆形小图标按钮
struct IconButton: View {
    let symbol: String
    var label: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
                .frame(width: 36, height: 36)
                .background(Color.card).clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - 成员

struct MemberAvatar: View {
    let member: Member
    var size: CGFloat = 40
    var body: some View {
        Text(member.emoji)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Color.card)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

/// 左上角的成员下拉菜单：切换、添加、修改、删除
struct MemberMenu: View {
    @EnvironmentObject var store: Store
    var compact = false
    @State private var adding = false
    @State private var editing: IDBox?
    @State private var deleting: Member?

    var body: some View {
        Menu {
            Section("切换成员") {
                ForEach(store.members) { m in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.switchTo(m.id) }
                    } label: {
                        if m.id == store.currentID { Label("\(m.emoji) \(m.displayName)", systemImage: "checkmark") }
                        else { Text("\(m.emoji) \(m.displayName)") }
                    }
                }
            }
            Section {
                Button { adding = true } label: { Label("添加家人或宠物", systemImage: "plus") }
                Button { editing = IDBox(id: store.currentID) } label: { Label("修改\(store.member.displayName)的资料", systemImage: "pencil") }
                if store.currentID != "me" {
                    Button(role: .destructive) { deleting = store.member } label: { Label("删除\(store.member.displayName)", systemImage: "trash") }
                }
            }
        } label: {
            if compact {
                HStack(spacing: 6) {
                    Text(store.member.emoji).font(.system(size: 17))
                    Text(store.member.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.ink3)
                }
                .padding(.leading, 8).padding(.trailing, 12).frame(height: 36)
                .background(Color.card).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                .contentShape(Capsule())
            } else {
                HStack(spacing: 8) {
                    MemberAvatar(member: store.member, size: 32)
                    Text(store.member.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                }
                .contentShape(Rectangle())
            }
        }
        .sheet(isPresented: $adding) { MemberEditView(memberID: nil) }
        .sheet(item: $editing) { b in MemberEditView(memberID: b.id) }
        .confirmationDialog("删除「\(deleting?.displayName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let d = deleting { withAnimation { store.removeMember(d.id) } }
                deleting = nil
            }
        } message: { Text("会一起删除 TA 的所有记录和贴纸，不能恢复。") }
    }
}

/// 其他页面顶部用的成员栏（左边成员菜单，右边可放按钮）
struct MemberBar: View {
    var body: some View {
        HStack { MemberMenu(); Spacer() }
    }
}

// MARK: - 手账背景

struct PaperBackground: View {
    @EnvironmentObject var store: Store
    let style: PaperStyle
    var imageName: String? = nil

    var body: some View {
        switch style {
        case .dots: DotBackground()
        case .grid: GridPaper(lineColor: Color(red: 0.86, green: 0.89, blue: 0.93), base: Color(red: 0.995, green: 0.997, blue: 1.0))
        case .lines: LinedPaper()
        case .blank: Color(red: 1.0, green: 0.985, blue: 0.955)
        case .kraft: KraftPaper()
        case .paws: PawPaper()
        case .custom:
            if let n = imageName, let img = store.image(n) {
                GeometryReader { g in
                    Image(uiImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .overlay(Color.white.opacity(0.12))
                }
            } else {
                DotBackground()
            }
        }
    }
}

struct GridPaper: View {
    var lineColor: Color
    var base: Color
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 20
            var p = Path()
            var x: CGFloat = step
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = step
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(lineColor), lineWidth: 0.7)
        }
        .background(base)
    }
}

struct LinedPaper: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var y: CGFloat = 64
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += 26 }
            ctx.stroke(p, with: .color(Color(red: 0.78, green: 0.85, blue: 0.93)), lineWidth: 0.8)
            var m = Path()
            m.move(to: CGPoint(x: 34, y: 0)); m.addLine(to: CGPoint(x: 34, y: size.height))
            ctx.stroke(m, with: .color(Color(red: 0.95, green: 0.62, blue: 0.6).opacity(0.7)), lineWidth: 1)
        }
        .background(Color(red: 1.0, green: 0.995, blue: 0.98))
    }
}

struct KraftPaper: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<Int(size.width * size.height / 90) {
                let x = CGFloat(rng.next()) * size.width, y = CGFloat(rng.next()) * size.height
                let r = CGFloat(rng.next()) * 1.4 + 0.3
                let dark = rng.next() > 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(dark ? Color(red: 0.55, green: 0.40, blue: 0.25).opacity(0.18) : Color.white.opacity(0.22)))
            }
        }
        .background(Color(red: 0.84, green: 0.73, blue: 0.58))
    }
}

struct PawPaper: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 70
            var row = 0
            var y: CGFloat = 30
            while y < size.height + step {
                var x: CGFloat = row % 2 == 0 ? 24 : 24 + step / 2
                while x < size.width + step {
                    ctx.drawLayer { l in
                        l.translateBy(x: x, y: y)
                        l.rotate(by: .degrees(row % 2 == 0 ? -18 : 14))
                        let c = GraphicsContext.Shading.color(Color(red: 0.86, green: 0.80, blue: 0.72).opacity(0.55))
                        l.fill(Path(ellipseIn: CGRect(x: -7, y: -2, width: 14, height: 12)), with: c)
                        for (dx, dy) in [(-9.0, -9.0), (-3.0, -13.0), (3.0, -13.0), (9.0, -9.0)] {
                            l.fill(Path(ellipseIn: CGRect(x: dx - 2.6, y: dy - 2.6, width: 5.2, height: 5.6)), with: c)
                        }
                    }
                    x += step
                }
                y += step * 0.8
                row += 1
            }
        }
        .background(Color(red: 1.0, green: 0.985, blue: 0.96))
    }
}

/// 固定种子的随机数，保证牛皮纸纹理每次一样
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

enum PillStyle { case plain, red, green, yellow, blue }

struct Pill: View {
    let text: String
    var style: PillStyle = .plain
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(Capsule())
    }
    private var bg: Color {
        switch style {
        case .plain: return .fill
        case .red: return .tomatoSoft
        case .green: return .brandSoft
        case .yellow: return .butterSoft
        case .blue: return Color(red: 0.902, green: 0.925, blue: 0.953)
        }
    }
    private var fg: Color {
        switch style {
        case .plain: return .ink2
        case .red: return .tomato
        case .green: return .brand
        case .yellow: return Color(red: 0.55, green: 0.40, blue: 0.10)
        case .blue: return .sky
        }
    }
}

struct TipRow: View {
    let emoji: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(emoji).font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(Color.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.line, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.fill).overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

/// 自动换行的标签布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct IDBox: Identifiable { let id: String }

struct DotBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var y: CGFloat = 9
            while y < size.height {
                var x: CGFloat = 9
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2)), with: .color(.dot))
                    x += step
                }
                y += step
            }
        }
        .background(Color(red: 1.0, green: 0.996, blue: 0.98))
    }
}

struct Tape: View {
    let color: Color
    var body: some View {
        Rectangle()
            .fill(color.opacity(0.85))
            .overlay(
                Canvas { ctx, size in
                    var x: CGFloat = -size.height
                    while x < size.width {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: size.height))
                        p.addLine(to: CGPoint(x: x + size.height, y: 0))
                        p.addLine(to: CGPoint(x: x + size.height + 6, y: 0))
                        p.addLine(to: CGPoint(x: x + 6, y: size.height))
                        ctx.fill(p, with: .color(.white.opacity(0.3)))
                        x += 12
                    }
                }
            )
            .frame(width: 90, height: 24)
    }
}
