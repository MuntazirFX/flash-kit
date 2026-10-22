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
        if path == "/game.swf" { data = GameStore.data } 
        else if let base = Bundle.main.resourceURL?.appendingPathComponent("www") {
            data = try? Data(contentsOf: base.appendingPathComponent(path))
        }
        guard let body = data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = ["html": "text/html", "js": "text/javascript", "wasm": "application/wasm", "swf": "application/x-shockwave-flash"][ext] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(body.count)", "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp); task.didReceive(body); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - SWF Data & Library
struct SWFInfo: Codable { var title: String; var width: Int; var height: Int; var version: Int }
enum SWFMeta {
    static func cleanName(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "[_\\-+]+", with: " ", options: .regularExpression)
        return s.isEmpty ? raw : s.capitalized
    }
}

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
        wv.isOpaque = false; wv.backgroundColor = .black; wv.scrollView.isScrollEnabled = false
        holder.web = wv
        wv.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {}
}

// MARK: - Controls
struct KeyButton: View {
    var label: String = ""; var icon: String? = nil
    let code: String; let key: String; var size: CGFloat = 50
    let holder: WebHolder; @State private var down = false
    var body: some View {
        Group { if let icon = icon { Image(systemName: icon).font(.system(size: size * 0.35)) } else { Text(label).font(.system(size: size * 0.30, weight: .bold)) } }
        .foregroundColor(.white).frame(width: size, height: size)
        .background(Circle().fill(down ? Color.orange.opacity(0.8) : Color.white.opacity(0.15)))
        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
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
                    Button(action: onClose) { Image(systemName: "xmark").foregroundColor(.white).padding(12).background(Color.black.opacity(0.5)).clipShape(Circle()) }
                    Spacer()
                }.padding()
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(spacing: 4) {
                        KeyButton(icon: "arrowtriangle.up.fill", code: "ArrowUp", key: "ArrowUp", holder: holder)
                        HStack(spacing: 4) {
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
                }.padding(.horizontal, 25).padding(.bottom, 30)
            }
        }.statusBarHidden(true)
    }
}

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

struct ArchiveGame: Identifiable {
    let id = UUID()
    let title: String
    let genre: String
    let urlString: String
    let imageName: String
}

let sampleGames = [
    ArchiveGame(title: "Age of War", genre: "Strategy", urlString: "https://www.museumofplay.org/files/2020-10/age-of-war.swf", imageName: "shield.fill"),
    ArchiveGame(title: "Bloons TD", genre: "Tower Defense", urlString: "https://archive.org/download/flash_game_bloons_td/Bloons%20Tower%20Defense.swf", imageName: "balloon.fill"),
    ArchiveGame(title: "Alien Hominid", genre: "Action", urlString: "https://archive.org/download/flash_game_alien_hominid/Alien%20Hominid.swf", imageName: "alien.fill"),
    ArchiveGame(title: "Papa's Pizzeria", genre: "Simulation", urlString: "https://archive.org/download/flash_game_papas_pizzeria/Papas%20Pizzeria.swf", imageName: "pizza.fill")
]

final class Library: ObservableObject {
    @Published var files: [URL] = []
    @Published var isDownloading = false
    @Published var downloadedArchiveGame: String? = nil
    
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
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        refresh()
    }
    
    func downloadGame(from urlString: String, title: String) {
        guard let url = URL(string: urlString) else { return }
        isDownloading = true; downloadedArchiveGame = nil
        
        URLSession.shared.downloadTask(with: url) { localUrl, response, error in
            DispatchQueue.main.async {
                self.isDownloading = false
                if let localUrl = localUrl {
                    let filename = "\(title.replacingOccurrences(of: " ", with: "_")).swf"
                    let dest = self.dir.appendingPathComponent(filename)
                    try? FileManager.default.moveItem(at: localUrl, to: dest)
                    self.refresh()
                    self.downloadedArchiveGame = title
                }
            }
        }.resume()
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url); refresh() }
}

// MARK: - Main UI
struct ContentView: View {
    @StateObject private var lib = Library()
    @State private var picking = false
    @State private var query = ""
    @State private var archiveQuery = ""
    @State private var playing: URL?
    @State private var selectedGame: URL?
    @State private var selectedTab = 0
    
    var filtered: [URL] { query.isEmpty ? lib.files : lib.files.filter { lib.title($0).localizedCaseInsensitiveContains(query) } }
    var filteredArchive: [ArchiveGame] { archiveQuery.isEmpty ? sampleGames : sampleGames.filter { $0.title.localizedCaseInsensitiveContains(archiveQuery) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.05, green: 0.03, blue: 0.09).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack { Text("Flash").foregroundColor(.white) + Text("Kit").foregroundColor(.orange) }
                    .font(.system(size: 32, weight: .black)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 10)
                
                if selectedTab == 0 {
                    // MARK: LIBRARY
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.gray)
                        TextField("Search games...", text: $query).foregroundColor(.white)
                    }
                    .padding(10).background(Color.white.opacity(0.08)).cornerRadius(12).padding(.horizontal, 20).padding(.top, 10)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            Text("All Games").font(.caption.bold()).foregroundColor(.black).padding(.horizontal, 16).padding(.vertical, 8).background(Color.orange).clipShape(Capsule())
                            Text("Arcade").font(.caption.bold()).foregroundColor(.gray).padding(.horizontal, 16).padding(.vertical, 8).background(Color.white.opacity(0.08)).clipShape(Capsule())
                            Text("Action").font(.caption.bold()).foregroundColor(.gray).padding(.horizontal, 16).padding(.vertical, 8).background(Color.white.opacity(0.08)).clipShape(Capsule())
                        }.padding(.horizontal, 20).padding(.vertical, 15)
                    }

                    if lib.files.isEmpty {
                        Spacer(); Text("Library is empty. Import or Download games!").foregroundColor(.gray); Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 15)], spacing: 15) {
                                ForEach(filtered) { url in
                                    Button { selectedGame = url } label: {
                                        VStack {
                                            RoundedRectangle(cornerRadius: 16)
                                                .fill(LinearGradient(colors: [.orange.opacity(0.8), .red.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(height: 100)
                                                .overlay(Text(String(lib.title(url).prefix(1))).font(.system(size: 35, weight: .bold)).foregroundColor(.white))
                                            Text(lib.title(url)).font(.caption.bold()).foregroundColor(.white).lineLimit(1)
                                        }
                                    }
                                }
                            }.padding(.horizontal, 20).padding(.bottom, 100)
                        }
                    }
                } else {
                    // MARK: ARCHIVE EXPLORER
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.gray)
                        TextField("Search Archive...", text: $archiveQuery).foregroundColor(.white)
                    }
                    .padding(10).background(Color.white.opacity(0.08)).cornerRadius(12).padding(.horizontal, 20).padding(.top, 10)
                    
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(filteredArchive) { game in
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)).frame(width: 60, height: 60)
                                        .overlay(Image(systemName: game.imageName).font(.title2).foregroundColor(.orange))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.title).font(.subheadline.bold()).foregroundColor(.white)
                                        Text(game.genre).font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Button {
                                        lib.downloadGame(from: game.urlString, title: game.title)
                                    } label: {
                                        if lib.isDownloading {
                                            ProgressView().tint(.white).padding(8).background(Color.orange.opacity(0.5)).cornerRadius(8)
                                        } else {
                                            Text("Get").font(.subheadline.bold()).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 8).background(Color.orange).cornerRadius(8)
                                        }
                                    }
                                }
                                .padding(10).background(Color.white.opacity(0.05)).cornerRadius(14)
                            }
                        }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 100)
                    }
                }
            }
            
            // MARK: BOTTOM NAV (FIXED SIZE)
            HStack {
                Button(action: { selectedTab = 0 }) {
                    VStack(spacing: 4) { Image(systemName: "gamecontroller.fill").font(.system(size: 20)); Text("Library").font(.caption2.bold()) }
                        .foregroundColor(selectedTab == 0 ? .orange : .gray)
                }
                Spacer()
                
                // Plus Button (Center)
                Button(action: { picking = true }) {
                    Image(systemName: "plus").font(.title2.bold()).foregroundColor(.white)
                        .frame(width: 55, height: 55)
                        .background(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(Circle()).shadow(color: .orange.opacity(0.4), radius: 8)
                }.offset(y: -15)
                
                Spacer()
                Button(action: { selectedTab = 1 }) {
                    VStack(spacing: 4) { Image(systemName: "safari.fill").font(.system(size: 20)); Text("Archive").font(.caption2.bold()) }
                        .foregroundColor(selectedTab == 1 ? .orange : .gray)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            .background(Color(red: 0.1, green: 0.08, blue: 0.15))
            .clipShape(Capsule()).padding(.horizontal, 20).padding(.bottom, 10)
        }
        .sheet(isPresented: $picking) { DocPicker(onPick: { urls in picking = false; lib.add(urls) }) }
        .sheet(item: $selectedGame) { url in
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: { selectedGame = nil }) { Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.gray) }
                }.padding(.top, 20).padding(.trailing, 20)
                
                Image(systemName: "gamecontroller.fill").font(.system(size: 60)).foregroundColor(.orange)
                Text(lib.title(url)).font(.largeTitle.bold()).foregroundColor(.white)
                Text("Platform: Flash\nSource: Local").foregroundColor(.gray).multilineTextAlignment(.center)
                
                Button {
                    GameStore.data = try? Data(contentsOf: url)
                    selectedGame = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { playing = url }
                } label: {
                    Text("PLAY NOW").font(.headline.bold()).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding().background(Color.orange).cornerRadius(14).padding(.horizontal, 30)
                }
                
                Button(role: .destructive) {
                    lib.remove(url); selectedGame = nil
                } label: {
                    Text("Delete Game").font(.subheadline.bold()).foregroundColor(.red).padding(.top, 10)
                }
                Spacer()
            }.background(Color(red: 0.05, green: 0.03, blue: 0.09).ignoresSafeArea())
        }
        .fullScreenCover(item: $playing) { url in PlayerScreen(name: lib.title(url)) { playing = nil } }
        .alert("Download Complete!", isPresented: Binding(get: { lib.downloadedArchiveGame != nil }, set: { _ in lib.downloadedArchiveGame = nil })) {
            Button("Go to Library") { selectedTab = 0 }
        } message: { Text("The game has been added to your library.") }
    }
}

@main struct FlashKitApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
