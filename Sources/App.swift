import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum GameStore { static var data: Data? }

// MARK: - Local server for Ruffle
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path == "/" || path.isEmpty { path = "/index.html" }
        var data: Data?
        if path == "/game.swf" {
            data = GameStore.data
        } else if let base = Bundle.main.resourceURL?.appendingPathComponent("www") {
            data = try? Data(contentsOf: base.appendingPathComponent(path))
        }
        guard let body = data else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = ["html": "text/html", "js": "text/javascript", "wasm": "application/wasm",
                    "json": "application/json", "swf": "application/x-shockwave-flash"][ext] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(body.count)",
                           "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp); task.didReceive(body); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - SWF Metadata
struct SWFInfo: Codable {
    var title: String
    var width: Int
    var height: Int
    var version: Int
}

enum SWFMeta {
    static func cleanName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "[_\\-+]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? raw : s.capitalized
    }
    static func readInfo(_ url: URL) -> SWFInfo {
        return SWFInfo(title: cleanName(url.deletingPathExtension().lastPathComponent), width: 800, height: 600, version: 0)
    }
}

// MARK: - Player
final class WebHolder {
    weak var web: WKWebView?
    func key(_ type: String, code: String, key: String) {
        let js = "(function(){var e=new KeyboardEvent('\(type)',{key:'\(key)',code:'\(code)',bubbles:true,cancelable:true});var t=document.querySelector('ruffle-player')||document;t.dispatchEvent(e);})();"
        web?.evaluateJavaScript(js)
    }
}

struct GameView: UIViewRepresentable {
    let holder: WebHolder
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "app")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false; wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        holder.web = wv
        wv.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {}
}

struct KeyButton: View {
    var label: String = ""; var icon: String? = nil
    let code: String; let key: String; var size: CGFloat = 58
    let holder: WebHolder; @State private var down = false
    var body: some View {
        Group { if let icon = icon { Image(systemName: icon).font(.system(size: size * 0.38)) } else { Text(label).font(.system(size: size * 0.30, weight: .bold)) } }
        .foregroundColor(.white).frame(width: size, height: size)
        .background(Circle().fill(down ? Color.orange : Color.white.opacity(0.2)))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; holder.key("keydown", code: code, key: key) } }
            .onEnded { _ in down = false; holder.key("keyup", code: code, key: key) })
    }
}

struct PlayerScreen: View {
    let name: String; let onClose: () -> Void
    @State private var holder = WebHolder()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GameView(holder: holder).ignoresSafeArea()
            VStack {
                HStack {
                    Button(action: onClose) { Image(systemName: "xmark").foregroundColor(.white).padding(12).background(Color.black.opacity(0.6)).clipShape(Circle()) }
                    Spacer()
                }.padding()
                Spacer()
                HStack {
                    VStack(spacing: 5) {
                        KeyButton(icon: "arrowtriangle.up.fill", code: "ArrowUp", key: "ArrowUp", holder: holder)
                        HStack(spacing: 5) {
                            KeyButton(icon: "arrowtriangle.left.fill", code: "ArrowLeft", key: "ArrowLeft", holder: holder)
                            KeyButton(icon: "arrowtriangle.right.fill", code: "ArrowRight", key: "ArrowRight", holder: holder)
                        }
                        KeyButton(icon: "arrowtriangle.down.fill", code: "ArrowDown", key: "ArrowDown", holder: holder)
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        KeyButton(label: "Z", code: "KeyZ", key: "z", holder: holder)
                        KeyButton(label: "X", code: "KeyX", key: "x", holder: holder)
                    }
                }.padding(30)
            }
        }.statusBarHidden(true)
    }
}

// MARK: - Document Picker
struct DocPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = true; p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

// MARK: - Library & Downloader
final class Library: ObservableObject {
    @Published var files: [URL] = []
    @Published var isDownloading = false
    
    let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    init() { refresh() }
    
    func refresh() { files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension.lowercased() == "swf" } ?? [] }
    func title(_ url: URL) -> String { SWFMeta.cleanName(url.deletingPathExtension().lastPathComponent) }
    
    func add(_ urls: [URL]) {
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        refresh()
    }
    
    func downloadGame(from url: URL) {
        isDownloading = true
        URLSession.shared.downloadTask(with: url) { localUrl, response, error in
            DispatchQueue.main.async {
                self.isDownloading = false
                if let localUrl = localUrl {
                    let filename = url.lastPathComponent.contains(".swf") ? url.lastPathComponent : "\(UUID().uuidString).swf"
                    let dest = self.dir.appendingPathComponent(filename)
                    try? FileManager.default.moveItem(at: localUrl, to: dest)
                    self.refresh()
                }
            }
        }.resume()
    }
    
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url); refresh() }
}

// MARK: - Archive Browser (WebView)
struct ArchiveBrowser: UIViewRepresentable {
    @ObservedObject var lib: Library
    @Binding var showAlert: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        // OldSWF is a great archive for retro games
        wv.load(URLRequest(url: URL(string: "https://oldswf.com")!))
        return wv
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ArchiveBrowser
        init(_ parent: ArchiveBrowser) { self.parent = parent }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.pathExtension.lowercased() == "swf" {
                // Intercept .swf download
                parent.lib.downloadGame(from: url)
                parent.showAlert = true
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Main UI
struct ContentView: View {
    @StateObject private var lib = Library()
    @State private var picking = false
    @State private var query = ""
    @State private var playing: URL?
    @State private var selectedGame: URL?
    @State private var selectedTab = 0 // 0 = Library, 1 = Archive
    @State private var showDownloadAlert = false
    
    var filtered: [URL] {
        query.isEmpty ? lib.files : lib.files.filter { lib.title($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.05, green: 0.03, blue: 0.09).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Header
                HStack {
                    Text("Flash").foregroundColor(.white) + Text("Kit").foregroundColor(.orange)
                }
                .font(.system(size: 34, weight: .black))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 10)
                
                if selectedTab == 0 {
                    // --- LIBRARY VIEW ---
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.gray)
                        TextField("Search games...", text: $query).foregroundColor(.white)
                        Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(.orange)
                    }
                    .padding(12).background(Color.white.opacity(0.08)).cornerRadius(14)
                    .padding(.horizontal, 20).padding(.top, 10)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            CategoryChip(title: "All Games", isSelected: true)
                            CategoryChip(title: "Arcade", isSelected: false)
                            CategoryChip(title: "Action", isSelected: false)
                        }.padding(.horizontal, 20).padding(.vertical, 15)
                    }

                    if lib.files.isEmpty {
                        Spacer()
                        Text("Library is empty. Import or Download games!").foregroundColor(.gray)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 15)], spacing: 20) {
                                ForEach(filtered) { url in
                                    Button { selectedGame = url } label: {
                                        VStack {
                                            RoundedRectangle(cornerRadius: 16)
                                                .fill(LinearGradient(colors: [.orange.opacity(0.8), .red.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(height: 110)
                                                .overlay(Text(String(lib.title(url).prefix(1))).font(.system(size: 40, weight: .bold)).foregroundColor(.white))
                                            
                                            Text(lib.title(url)).font(.caption.bold()).foregroundColor(.white).lineLimit(1)
                                        }
                                    }
                                }
                            }.padding(.horizontal, 20).padding(.bottom, 120)
                        }
                    }
                } else {
                    // --- ARCHIVE EXPLORER VIEW ---
                    ZStack {
                        ArchiveBrowser(lib: lib, showAlert: $showDownloadAlert)
                            .cornerRadius(20)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                        
                        if lib.isDownloading {
                            VStack {
                                ProgressView().scaleEffect(1.5).padding()
                                Text("Downloading Game...").foregroundColor(.white).font(.headline)
                            }
                            .padding(30)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(20)
                        }
                    }
                }
            }
            
            // Bottom Navigation Bar
            HStack {
                Spacer()
                Button(action: { selectedTab = 0 }) {
                    VStack(spacing: 4) {
                        Image(systemName: "gamecontroller.fill")
                        Text("My Library").font(.caption2.bold())
                    }.foregroundColor(selectedTab == 0 ? .orange : .gray)
                }
                
                Spacer()
                
                // Plus Button (Only on Library Tab)
                if selectedTab == 0 {
                    Button(action: { picking = true }) {
                        Image(systemName: "plus").font(.title.bold()).foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(Circle()).shadow(color: .orange.opacity(0.5), radius: 10)
                    }.offset(y: -20)
                } else {
                    Color.clear.frame(width: 60, height: 60).offset(y: -20)
                }
                
                Spacer()
                
                Button(action: { selectedTab = 1 }) {
                    VStack(spacing: 4) {
                        Image(systemName: "safari.fill")
                        Text("Archive").font(.caption2.bold())
                    }.foregroundColor(selectedTab == 1 ? .orange : .gray)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .background(Color(red: 0.1, green: 0.08, blue: 0.15))
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $picking) { DocPicker(onPick: { urls in picking = false; lib.add(urls) }) }
        .sheet(item: $selectedGame) { url in
            VStack(spacing: 20) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 60)).foregroundColor(.orange).padding(.top, 40)
                Text(lib.title(url)).font(.largeTitle.bold()).foregroundColor(.white)
                Text("Platform: Flash\nSource: Local").foregroundColor(.gray).multilineTextAlignment(.center)
                
                Button {
                    GameStore.data = try? Data(contentsOf: url)
                    selectedGame = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { playing = url }
                } label: {
                    Text("PLAY NOW").font(.headline.bold()).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.orange).cornerRadius(16).padding(.horizontal, 40)
                }
                
                Button(role: .destructive) {
                    lib.remove(url)
                    selectedGame = nil
                } label: {
                    Text("Delete Game").foregroundColor(.red)
                }
                Spacer()
            }.background(Color(red: 0.05, green: 0.03, blue: 0.09).ignoresSafeArea())
        }
        .fullScreenCover(item: $playing) { url in PlayerScreen(name: lib.title(url)) { playing = nil } }
        .alert("Download Started!", isPresented: $showDownloadAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The game is downloading in the background. It will appear in your library shortly.")
        }
    }
}

struct CategoryChip: View {
    var title: String; var isSelected: Bool
    var body: some View {
        Text(title).font(.caption.bold())
            .foregroundColor(isSelected ? .black : .gray)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(isSelected ? Color.orange : Color.white.opacity(0.08))
            .clipShape(Capsule())
    }
}

@main struct FlashKitApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
