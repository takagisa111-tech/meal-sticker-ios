import SwiftUI
import WebKit
import UIKit

/// 支持网页加购的平台配置
struct WebShop {
    let name: String
    let loginURL: String
    let searchPrefix: String        // 拼上关键词
    let searchHost: String          // 用于判断当前在搜索页
    let itemHosts: [String]         // 用于判断当前在商品页
    let itemURL: (String) -> String
    let cartURL: String
    let appScheme: String
    let loginCookies: [String]      // 任一存在且非空即视为已登录
    let loginHosts: [String]        // 出现在这些地址说明需要登录
    let findJS: String

    static let jd = WebShop(
        name: "京东",
        loginURL: "https://plogin.m.jd.com/login/login?appid=300&returnurl=https%3A%2F%2Fm.jd.com%2F",
        searchPrefix: "https://so.m.jd.com/ware/search.action?keyword=",
        searchHost: "so.m.jd.com",
        itemHosts: ["item.m.jd.com", "/product/"],
        itemURL: { "https://item.m.jd.com/product/\($0).html" },
        cartURL: "https://p.m.jd.com/cart/cart.action",
        appScheme: "openjd://",
        loginCookies: ["pt_key"],
        loginHosts: ["plogin.m.jd.com", "passport.jd.com"],
        findJS: """
        (function(){
          var as = Array.prototype.slice.call(document.querySelectorAll('a[href]'));
          for (var i = 0; i < as.length; i++) {
            var h = as[i].href || '';
            var m = h.match(/item\\.m\\.jd\\.com\\/(?:product\\/|ware\\/view\\.action\\?wareId=)?(\\d{5,})/) || h.match(/\\/product\\/(\\d{5,})\\.html/);
            if (m) return m[1];
          }
          var d = document.querySelector('[data-sku]');
          if (d) return d.getAttribute('data-sku');
          var html = document.documentElement.innerHTML;
          var m2 = html.match(/"(?:wareId|skuId)"\\s*:\\s*"?(\\d{5,})/);
          return m2 ? m2[1] : '';
        })()
        """)

    static let taobao = WebShop(
        name: "淘宝",
        loginURL: "https://login.m.taobao.com/login.htm?redirectURL=https%3A%2F%2Fmain.m.taobao.com%2F",
        searchPrefix: "https://main.m.taobao.com/search/index.html?q=",
        searchHost: "search",
        itemHosts: ["detail", "item.htm", "item.taobao.com", "detail.tmall.com"],
        itemURL: { "https://h5.m.taobao.com/awp/core/detail.htm?id=\($0)" },
        cartURL: "https://main.m.taobao.com/cart/index.html",
        appScheme: "taobao://",
        loginCookies: ["unb", "_nk_", "tracknick"],
        loginHosts: ["login.m.taobao.com", "login.taobao.com", "havanaone"],
        findJS: """
        (function(){
          var as = Array.prototype.slice.call(document.querySelectorAll('a[href]'));
          for (var i = 0; i < as.length; i++) {
            var h = as[i].href || '';
            if (/detail|item\\.htm|item\\.taobao|tmall/.test(h)) {
              var m = h.match(/[?&](?:id|itemId|item_id)=(\\d{8,})/);
              if (m) return m[1];
            }
          }
          var d = document.querySelector('[data-itemid],[data-item-id],[data-nid]');
          if (d) return d.getAttribute('data-itemid') || d.getAttribute('data-item-id') || d.getAttribute('data-nid');
          var html = document.documentElement.innerHTML;
          var m2 = html.match(/"(?:item_id|itemId|nid)"\\s*:\\s*"?(\\d{8,})/);
          return m2 ? m2[1] : '';
        })()
        """)
}

/// 网页版加购（京东 / 淘宝）：App 内嵌京东手机网页，登录一次后保存在 App 里，
/// 按清单逐项搜索 → 打开第一个商品 → 尝试点击「加入购物车」。自动失败时用户可在同一页面手动点。
final class ShopSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Stage { case login, search, item, done, finished }

    let web: WKWebView
    @Published var loggedIn = false
    @Published var stage: Stage = .login
    @Published var index = 0
    @Published var status = ""
    @Published var auto = true
    @Published var results: [Int: Bool] = [:]   // 每项是否已加购
    let items: [String]
    let shop: WebShop
    private var token = 0
    private var manual = false

    init(items: [String], shop: WebShop) {
        self.items = items
        self.shop = shop
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 持久化：登录状态保存在 App 里
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.allowsBackForwardNavigationGestures = true
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    var current: String { index < items.count ? items[index] : "" }

    func start() {
        checkLogin { ok in
            if ok { self.go(to: 0) } else { self.showLogin() }
        }
    }

    func showLogin() {
        stage = .login
        status = "请先登录\(shop.name)账号，只需登录一次"
        load(shop.loginURL)
    }

    func go(to i: Int, manual m: Bool = false) {
        guard i < items.count else { finish(); return }
        manual = m
        index = i
        stage = .search
        token += 1
        status = auto && !m ? "正在搜索「\(items[i])」…" : "选一个商品，点「加入购物车」"
        let q = items[i].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? items[i]
        load(shop.searchPrefix + q)
    }

    func next() { go(to: index + 1) }
    func prev() { go(to: max(0, index - 1)) }

    /// 不自动选，回到这一项的搜索结果自己挑
    func chooseManually() {
        go(to: index, manual: true)
        status = "选一个商品，点「加入购物车」，然后点「已加入，下一项」"
        stage = .done
    }

    func markDone() {
        results[index] = true
        next()
    }

    func openCart() {
        stage = .finished
        status = "这是你的\(shop.name)购物车，可在\(shop.name) App 中结算"
        load(shop.cartURL)
    }

    private func finish() {
        let n = results.values.filter { $0 }.count
        openCart()
        status = "清单已处理完，\(n) 项已加入购物车"
    }

    private func load(_ s: String) {
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
    }

    func checkLogin(_ done: @escaping (Bool) -> Void) {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cs in
            let names = Set(self.shop.loginCookies)
            let ok = cs.contains { names.contains($0.name) && !$0.value.isEmpty && ($0.expiresDate ?? .distantFuture) > Date() }
            DispatchQueue.main.async {
                self.loggedIn = ok
                done(ok)
            }
        }
    }

    // MARK: 导航

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 拦截「打开京东 App」之类的跳转，留在本页面
        if let s = action.request.url?.scheme?.lowercased(), s != "http", s != "https", s != "about", s != "blob", s != "data" {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let u = action.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        if stage == .login {
            checkLogin { ok in
                if ok { self.status = "登录成功"; self.go(to: self.index) }
            }
            return
        }
        if shop.loginHosts.contains(where: { url.contains($0) }) {
            stage = .login
            loggedIn = false
            status = "登录已失效，请重新登录"
            return
        }
        if url.contains("cfe.m.jd.com") || url.contains("verify") || url.contains("punish") || url.contains("captcha") {
            status = "\(shop.name)需要安全验证，请在页面中完成"
            return
        }
        guard auto, !manual else { return }
        let t = token
        if stage == .search, url.contains(shop.searchHost) {
            findFirstItem(attempt: 0, token: t)
        } else if stage == .item, shop.itemHosts.contains(where: { url.contains($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.clickAddCart(attempt: 0, token: t) }
        }
    }

    // MARK: 自动操作

    private func findFirstItem(attempt: Int, token t: Int) {
        guard t == token, stage == .search else { return }
        web.evaluateJavaScript(shop.findJS) { r, _ in
            guard t == self.token, self.stage == .search else { return }
            if let sku = (r as? String) ?? (r as? NSNumber)?.stringValue, !sku.isEmpty {
                self.stage = .item
                self.status = "打开第一个商品，准备加入购物车…"
                self.load(self.shop.itemURL(sku))
            } else if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.findFirstItem(attempt: attempt + 1, token: t) }
            } else {
                self.stage = .done
                self.status = "没能自动选中商品，请在页面中挑一个，加入购物车后点「下一项」"
            }
        }
    }

    private static let clickJS = """
    (function(){
      function vis(e){ var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
      var all = Array.prototype.slice.call(document.querySelectorAll('a,button,div,span'));
      var btn = all.filter(function(e){ var t = (e.innerText || '').trim(); return t === '加入购物车' && vis(e); }).pop();
      if (!btn) return 'none';
      btn.click();
      return 'clicked';
    })()
    """

    private static let confirmJS = """
    (function(){
      function vis(e){ var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
      var all = Array.prototype.slice.call(document.querySelectorAll('a,button,div,span'));
      var ok = all.filter(function(e){ var t = (e.innerText || '').trim(); return (t === '确定' || t === '加入购物车') && vis(e); }).pop();
      if (ok) ok.click();
      var body = document.body ? document.body.innerText : '';
      return /加入购物车成功|已加入购物车|添加成功|成功加入/.test(body) ? 'ok' : (ok ? 'confirmed' : 'unknown');
    })()
    """

    private func clickAddCart(attempt: Int, token t: Int) {
        guard t == token, stage == .item else { return }
        web.evaluateJavaScript(Self.clickJS) { r, _ in
            guard t == self.token, self.stage == .item else { return }
            if (r as? String) == "clicked" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.web.evaluateJavaScript(Self.confirmJS) { r2, _ in
                        guard t == self.token else { return }
                        self.stage = .done
                        if (r2 as? String) == "ok" {
                            self.results[self.index] = true
                            self.status = "「\(self.current)」已加入购物车"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if t == self.token, self.auto { self.next() }
                            }
                        } else {
                            self.status = "已点击加入购物车，请确认页面提示（需要选规格的请选好再点）"
                        }
                    }
                }
            } else if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.clickAddCart(attempt: attempt + 1, token: t) }
            } else {
                self.stage = .done
                self.status = "没找到「加入购物车」按钮，请在页面中手动点，然后点「下一项」"
            }
        }
    }
}

struct ShopWebView: UIViewRepresentable {
    let session: ShopSession
    func makeUIView(context: Context) -> WKWebView { session.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ShopCartView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var s: ShopSession

    init(items: [String], shop: WebShop) { _s = StateObject(wrappedValue: ShopSession(items: items, shop: shop)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ShopWebView(session: s)
                    .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 0.5) }
                controls
            }
            .background(Color.card)
            .navigationTitle("加入\(s.shop.name)购物车")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("购物车") { s.openCart() }.disabled(!s.loggedIn)
                }
            }
        }
        .tint(Color.brand)
        .onAppear { s.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if s.stage == .login {
                    Label("登录\(s.shop.name)", systemImage: "person.crop.circle").font(.system(size: 15, weight: .semibold))
                } else if s.stage == .finished {
                    Label("已完成", systemImage: "checkmark.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand)
                } else {
                    Text("第 \(s.index + 1)/\(s.items.count) 项").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink2)
                    Text(s.current).font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                Toggle("自动", isOn: $s.auto).labelsHidden().controlSize(.mini)
                Text("自动选第一个").font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
            HStack(spacing: 3) {
                ForEach(s.items.indices, id: \.self) { i in
                    Capsule().fill(s.results[i] == true ? Color.brand : (i == s.index && s.stage != .finished ? Color.ink : Color.fill))
                        .frame(height: 4)
                        .overlay(Capsule().strokeBorder(Color.line, lineWidth: 0.5))
                }
            }
            Text(s.status).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.paper)
    }

    @ViewBuilder private var controls: some View {
        if s.stage != .login && s.stage != .finished {
            HStack(spacing: 8) {
                Button { s.prev() } label: { Image(systemName: "chevron.left").frame(width: 20) }
                    .buttonStyle(SoftButton()).frame(width: 56)
                    .disabled(s.index == 0)
                Button("换一个") { s.chooseManually() }.buttonStyle(SoftButton())
                Button(s.results[s.index] == true ? "下一项" : "已加入，下一项") { s.markDone() }.buttonStyle(PrimaryButton())
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            .background(Color.paper)
        } else if s.stage == .finished {
            Button { if let u = URL(string: s.shop.appScheme) { UIApplication.shared.open(u) } } label: {
                Label("打开\(s.shop.name) App 结算", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(PrimaryButton())
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            .background(Color.paper)
        }
    }
}
