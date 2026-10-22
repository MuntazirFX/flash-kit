import SwiftUI
import WebKit
import UniformTypeIdentifiers
import GameController

// MARK: - App theme and SWF validation

enum FlashKitTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.05)
}

enum SWFFileError: LocalizedError {
    case invalidFile
    case badHTTPStatus(Int)
    case missingURL
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This file does not appear to be a valid SWF file."
        case .badHTTPStatus(let code): return "The website returned HTTP \(code)."
        case .missingURL: return "Enter a valid website or direct .swf URL."
        case .cannotSave: return "The downloaded game could not be saved."
        }
    }
}

enum SWFValidator {
    static func isSWF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 3), bytes.count == 3 else { return false }
        let signature = String(bytes: bytes, encoding: .ascii)
        return signature == "FWS" || signature == "CWS" || signature == "ZWS"
    }
}

// MARK: - Local library

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var games: [URL] = []
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        games = urls
            .filter { $0.pathExtension.lowercased() == "swf" && SWFValidator.isSWF(at: $0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[_\\-+]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func importFiles(_ urls: [URL]) {
        var imported = 0
        var failures: [String] = []
        for source in urls {
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
            guard source.pathExtension.lowercased() == "swf", SWFValidator.isSWF(at: source) else {
                failures.append("\(source.lastPathComponent): not a valid SWF")
                continue
            }
            do {
                let destination = uniqueDestination(for: source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                imported += 1
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refresh()
        if imported > 0 {
            statusMessage = "Imported \(imported) game\(imported == 1 ? "" : "s") into My Library."
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func downloadSWF(from rawURL: String, suggestedTitle: String? = nil) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            errorMessage = SWFFileError.missingURL.localizedDescription
            return
        }
        if components.scheme == nil { components.scheme = "https" }
        guard let url = components.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = SWFFileError.missingURL.localizedDescription
            return
        }

        isBusy = true
        statusMessage = "Downloading…"
        errorMessage = nil

        URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = nil
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.errorMessage = SWFFileError.badHTTPStatus(http.statusCode).localizedDescription
                    self.statusMessage = nil
                    return
                }
                guard let temporaryURL, SWFValidator.isSWF(at: temporaryURL) else {
                    self.errorMessage = SWFFileError.invalidFile.localizedDescription +
                        "\nThis website may require a login, use a blocked redirect, or provide HTML instead of a SWF."
                    self.statusMessage = nil
                    return
                }
                let responseName = response?.suggestedFilename ?? url.lastPathComponent
                let sourceName = (suggestedTitle?.isEmpty == false ? suggestedTitle! : responseName)
                let cleanBase = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "[^A-Za-z0-9 _.-]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = (cleanBase.isEmpty ? "Downloaded Game" : cleanBase) + ".swf"
                do {
                    let destination = self.uniqueDestination(for: filename)
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    self.refresh()
                    self.statusMessage = "Added \(destination.deletingPathExtension().lastPathComponent) to My Library."
                } catch {
                    self.errorMessage = SWFFileError.cannotSave.localizedDescription + "\n" + error.localizedDescription
                    self.statusMessage = nil
                }
            }
        }.resume()
    }

    func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            refresh()
            statusMessage = "Game deleted."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uniqueDestination(for filename: String) -> URL {
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        var destination = directory.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension.isEmpty ? "swf" : destination.pathExtension
        var number = 2
        repeat {
            destination = directory.appendingPathComponent("\(base) (\(number)).\(ext)")
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        return destination
    }
}

// MARK: - Document picker

struct SWFDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.filter { $0.pathExtension.lowercased() == "swf" })
        }
    }
}

// MARK: - Browser / archive explorer

struct ArchiveBrowser: UIViewRepresentable {
    @Binding var address: String
    let onSWFLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSWFLink: onSWFLink) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(FlashKitTheme.background)
        view.scrollView.backgroundColor = UIColor(FlashKitTheme.background)
        context.coordinator.webView = view
        context.coordinator.load(address)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onSWFLink = onSWFLink
        if context.coordinator.lastAddress != address {
            context.coordinator.load(address)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onSWFLink: (URL) -> Void
        var lastAddress = ""

        init(onSWFLink: @escaping (URL) -> Void) { self.onSWFLink = onSWFLink }

        func load(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            lastAddress = raw
            webView?.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.pathExtension.lowercased() == "swf" {
                onSWFLink(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        }
}

// MARK: - Local Ruffle player scheme

final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    private let gameData: Data
    private let webRoot: URL

    init(gameData: Data) {
        self.gameData = gameData
        self.webRoot = (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/"))
            .appendingPathComponent("www", isDirectory: true)
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        if path == "/game.swf" {
            respond(to: task, url: url, data: gameData, mime: "application/x-shockwave-flash")
            return
        }

        let relative = String(path.drop(while: { $0 == "/" }))
        let fileURL = webRoot.appendingPathComponent(relative).standardizedFileURL
        guard fileURL.path.hasPrefix(webRoot.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let ext = fileURL.pathExtension.lowercased()
        let mimeTypes = [
            "html": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "mjs": "text/javascript; charset=utf-8",
            "wasm": "application/wasm",
            "css": "text/css; charset=utf-8",
            "json": "application/json"
        ]
        respond(to: task, url: url, data: data, mime: mimeTypes[ext] ?? "application/octet-stream")
    }

    private func respond(to task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class PlayerBridge {
    weak var webView: WKWebView?

    func sendKey(_ key: String, code: String, type: String) {
        guard let keyData = try? JSONSerialization.data(withJSONObject: [key, code, type]),
              let json = String(data: keyData, encoding: .utf8) else { return }
        let script = """
        (() => {
          const [key, code, type] = \(json);
          const player = document.querySelector('ruffle-player');
          if (player) {
            player.focus();
            player.dispatchEvent(new KeyboardEvent(type, {key, code, bubbles:true, cancelable:true}));
          }
          window.dispatchEvent(new KeyboardEvent(type, {key, code, bubbles:true, cancelable:true}));
        })();
        """
        webView?.evaluateJavaScript(script)
    }

    func perform(_ action: String) {
        let script: String
        switch action {
        case "reload":
            script = "window.flashKitReload && window.flashKitReload();"
        case "pause":
            script = "window.flashKitPause && window.flashKitPause();"
        case "resume":
            script = "window.flashKitResume && window.flashKitResume();"
        default:
            return
        }
        webView?.evaluateJavaScript(script)
    }
}

struct GameWebView: UIViewRepresentable {
    let data: Data
    let quality: String
    let bridge: PlayerBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(gameData: data), forURLScheme: "app")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        bridge.webView = view
        let encodedQuality = quality.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "high"
        if let url = URL(string: "app://localhost/index.html?quality=\(encodedQuality)") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let safeQuality = (try? JSONSerialization.data(withJSONObject: [quality]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"high\"]"
        view.evaluateJavaScript("window.flashKitSetQuality && window.flashKitSetQuality(\(safeQuality).slice(1, -1));")
    }
}

// MARK: - Touch buttons

struct TouchKey: View {
    let label: String
    let key: String
    let code: String
    let bridge: PlayerBridge
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(pressed ? FlashKitTheme.accent.opacity(0.8) : Color.white.opacity(0.16))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        bridge.sendKey(key, code: code, type: "keydown")
                    }
                }
                .onEnded { _ in
                    if pressed {
                        pressed = false
                        bridge.sendKey(key, code: code, type: "keyup")
                    }
                })
    }
}

struct PlayerScreen: View {
    let gameURL: URL
    @Binding var quality: String
    let onClose: () -> Void

    @State private var bridge = PlayerBridge()
    @State private var showQuickSettings = false
    @State private var showControls = true
    @State private var isPaused = false
    @State private var showKeyboard = false
    @State private var showAnnotation = false
    @State private var annotationPoints: [CGPoint] = []

    private var gameData: Data { (try? Data(contentsOf: gameURL)) ?? Data() }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GameWebView(data: gameData, quality: quality, bridge: bridge).ignoresSafeArea()

            if showAnnotation {
                Canvas { context, _ in
                    var path = Path()
                    for (index, point) in annotationPoints.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(FlashKitTheme.accent), lineWidth: 3)
                }
                .ignoresSafeArea()
                .gesture(DragGesture(minimumDistance: 0).onChanged { annotationPoints.append($0.location) })
            }

            VStack {
                HStack(spacing: 10) {
                    toolbarButton("xmark", title: "Exit") { onClose() }
                    toolbarButton("arrow.clockwise", title: "Restart") { bridge.perform("reload") }
                    toolbarButton(isPaused ? "play.fill" : "pause.fill", title: isPaused ? "Resume" : "Pause") {
                        isPaused.toggle()
                        bridge.perform(isPaused ? "pause" : "resume")
                    }
                    toolbarButton("slider.horizontal.3", title: "Quick Settings") { showQuickSettings.toggle() }
                    Spacer()
                    toolbarButton("gamecontroller.fill", title: "Controls") { showControls.toggle() }
                    toolbarButton("keyboard", title: "Keyboard") { showKeyboard.toggle() }
                    toolbarButton("pencil.tip", title: "Draw") { showAnnotation.toggle(); annotationPoints.removeAll() }
                }
                .padding(.horizontal, 12).padding(.top, 10)

                if showQuickSettings {
                    HStack {
                        Text("Quality").foregroundStyle(.white)
                        Picker("Quality", selection: $quality) {
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                            Text("Default").tag("high")
                        }
                        .pickerStyle(.menu)
                        .tint(FlashKitTheme.accent)
                        Spacer()
                        Button("Done") { showQuickSettings = false }
                            .foregroundStyle(FlashKitTheme.accent)
                    }
                    .padding(12).background(FlashKitTheme.panel.opacity(0.95)).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                }

                Spacer()

                if showControls {
                    HStack(alignment: .bottom) {
                        VStack(spacing: 3) {
                            TouchKey(label: "▲", key: "ArrowUp", code: "ArrowUp", bridge: bridge)
                            HStack(spacing: 3) {
                                TouchKey(label: "◀", key: "ArrowLeft", code: "ArrowLeft", bridge: bridge)
                                TouchKey(label: "▼", key: "ArrowDown", code: "ArrowDown", bridge: bridge)
                                TouchKey(label: "▶", key: "ArrowRight", code: "ArrowRight", bridge: bridge)
                            }
                        }
                        Spacer()
                        HStack(spacing: 10) {
                            TouchKey(label: "Z", key: "z", code: "KeyZ", bridge: bridge)
                            TouchKey(label: "X", key: "x", code: "KeyX", bridge: bridge)
                            TouchKey(label: "Enter", key: "Enter", code: "Enter", bridge: bridge)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 22)
                }

                if showKeyboard {
                    HStack(spacing: 8) {
                        ForEach([("A","a","KeyA"),("S","s","KeyS"),("D","d","KeyD"),("W","w","KeyW"),("Space"," ","Space"),("Esc","Escape","Escape")], id: \.0) { item in
                            TouchKey(label: item.0, key: item.1, code: item.2, bridge: bridge)
                        }
                    }
                    .padding(10).background(FlashKitTheme.panel.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 12)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear { GameControllerManager.shared.connect(bridge: bridge) }
        .onDisappear { GameControllerManager.shared.disconnect() }
    }

    private func toolbarButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.65))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .accessibilityLabel(title)
    }
}

// MARK: - Bluetooth / console gamepad support

final class GameControllerManager {
    static let shared = GameControllerManager()
    private weak var bridge: PlayerBridge?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    private init() {}

    func connect(bridge: PlayerBridge) {
        self.bridge = bridge
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in self?.configureControllers() }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in self?.configureControllers() }
        configureControllers()
    }

    func disconnect() {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        connectObserver = nil
        disconnectObserver = nil
        bridge = nil
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
    }

    private func configureControllers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] _, element in
                guard let self, let bridge = self.bridge else { return }
                let key: String?
                let code: String
                switch element {
                case let button as GCControllerButtonInput:
                    if button === controller.extendedGamepad?.buttonA { key = "z"; code = "KeyZ" }
                    else if button === controller.extendedGamepad?.buttonB { key = "x"; code = "KeyX" }
                    else if button === controller.extendedGamepad?.dpad.up { key = "ArrowUp"; code = "ArrowUp" }
                    else if button === controller.extendedGamepad?.dpad.down { key = "ArrowDown"; code = "ArrowDown" }
                    else if button === controller.extendedGamepad?.dpad.left { key = "ArrowLeft"; code = "ArrowLeft" }
                    else if button === controller.extendedGamepad?.dpad.right { key = "ArrowRight"; code = "ArrowRight" }
                    else { key = "Enter"; code = "Enter" }
                case let dpad as GCControllerDirectionPad:
                    if dpad.yAxis > 0.5 { key = "ArrowUp"; code = "ArrowUp" }
                    else if dpad.yAxis < -0.5 { key = "ArrowDown"; code = "ArrowDown" }
                    else if dpad.xAxis < -0.5 { key = "ArrowLeft"; code = "ArrowLeft" }
                    else if dpad.xAxis > 0.5 { key = "ArrowRight"; code = "ArrowRight" }
                    else { return }
                default: return
                }
                if let key {
                    let type: String
                    if let button = element as? GCControllerButtonInput { type = button.isPressed ? "keydown" : "keyup" }
                    else { type = "keydown" }
                    bridge.sendKey(key, code: code, type: type)
                }
            }
        }
    }
}

// MARK: - Main screens

struct ContentView: View {
    @StateObject private var library = LibraryStore()
    @AppStorage("flashkit.quality") private var quality = "high"
    @AppStorage("flashkit.fps") private var fpsCap = "default"
    @AppStorage("flashkit.orientation") private var orientation = "auto"
    @AppStorage("flashkit.engine") private var engine = "bundled"
    @AppStorage("flashkit.touchControls") private var touchControls = true
    @AppStorage("flashkit.keyboardLayout") private var keyboardLayout = "Simple"

    @State private var selectedTab = 0
    @State private var showImporter = false
    @State private var selectedGame: URL?
    @State private var playingGame: URL?
    @State private var archiveAddress = "https://ruffle.rs"
    @State private var browserLocation = "https://ruffle.rs"
    @State private var directSWFURL = ""
    @State private var showDownloadField = false
    @State private var showSettingsAlert = false

    var body: some View {
        ZStack {
            FlashKitTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Group {
                    switch selectedTab {
                    case 0: libraryScreen
                    case 1: archiveScreen
                    default: settingsScreen
                    }
                }
                bottomNavigation
            }
        }
        .preferredColorScheme(.dark)
        .tint(FlashKitTheme.accent)
        .sheet(isPresented: $showImporter) {
            SWFDocumentPicker { urls in
                showImporter = false
                library.importFiles(urls)
            }
        }
        .sheet(item: $selectedGame) { url in gameDetails(url) }
        .fullScreenCover(item: $playingGame) { url in
            PlayerScreen(gameURL: url, quality: $quality) { playingGame = nil }
        }
        .alert("FlashKit", isPresented: Binding(
            get: { library.errorMessage != nil || library.statusMessage != nil },
            set: { if !$0 { library.errorMessage = nil; library.statusMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil; library.statusMessage = nil }
            if library.statusMessage != nil {
                Button("Open My Library") { selectedTab = 0; library.statusMessage = nil }
            }
        } message: {
            Text(library.errorMessage ?? library.statusMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                (Text("Flash").foregroundColor(.white) + Text("Kit").foregroundColor(FlashKitTheme.accent))
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text(["MY LIBRARY", "ARCHIVE EXPLORER", "SETTINGS"][selectedTab])
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.2).foregroundStyle(.gray)
            }
            Spacer()
            Button { showImporter = true } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .black))
                    .foregroundStyle(.black).frame(width: 42, height: 42)
                    .background(FlashKitTheme.accent).clipShape(Circle())
            }
            .accessibilityLabel("Import SWF game")
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
    }

    private var libraryScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "internaldrive.fill").foregroundStyle(FlashKitTheme.accent)
                Text("Offline games").font(.headline).foregroundStyle(.white)
                Spacer()
                Text("\(library.games.count) GAMES").font(.caption2.bold()).foregroundStyle(.gray)
                Button { library.refresh() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(FlashKitTheme.accent)
                }
                .accessibilityLabel("Refresh library")
            }
            .padding(.horizontal, 20)

            if library.games.isEmpty {
                Spacer()
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 58)).foregroundStyle(FlashKitTheme.accent.opacity(0.85))
                    .frame(maxWidth: .infinity)
                Text("Your library is empty")
                    .font(.title3.bold()).foregroundStyle(.white).frame(maxWidth: .infinity)
                Text("Tap + to import a local .swf file, or open Archive Explorer to download one.")
                    .font(.subheadline).foregroundStyle(.gray).multilineTextAlignment(.center)
                    .padding(.horizontal, 35)
                Button { showImporter = true } label: {
                    Label("Import SWF Game", systemImage: "plus")
                        .font(.headline).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding()
                        .background(FlashKitTheme.accent).clipShape(RoundedRectangle(cornerRadius: 14))
                }.padding(.horizontal, 30).padding(.top, 10)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                        ForEach(library.games, id: \.absoluteString) { url in
                            Button { selectedGame = url } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(LinearGradient(colors: [FlashKitTheme.accent.opacity(0.9), Color.orange.opacity(0.55)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                        Image(systemName: "gamecontroller.fill")
                                            .font(.system(size: 38, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                                        VStack { HStack { Spacer(); Image(systemName: "checkmark.icloud.fill").foregroundStyle(.black.opacity(0.7)) }; Spacer() }
                                            .padding(10)
                                    }.frame(height: 112)
                                    Text(library.title(for: url)).font(.subheadline.bold())
                                        .foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("SWF • OFFLINE").font(.system(size: 9, weight: .bold))
                                        .tracking(1).foregroundStyle(FlashKitTheme.accent)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(FlashKitTheme.panel).clipShape(RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }
            }
        }.padding(.top, 8)
    }

    private var archiveScreen: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "globe").foregroundStyle(FlashKitTheme.accent)
                TextField("Enter website or direct .swf URL", text: $archiveAddress)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .foregroundStyle(.white)
                Button("Go") {
                    archiveAddress = normalizedAddress(archiveAddress)
                    browserLocation = archiveAddress
                }
                    .font(.subheadline.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(FlashKitTheme.accent).clipShape(Capsule())
            }
            .padding(10).background(FlashKitTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)

            HStack(spacing: 8) {
                TextField("Paste a direct .swf download link (optional)", text: $directSWFURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.caption).padding(10).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    library.downloadSWF(from: directSWFURL)
                } label: {
                    if library.isBusy { ProgressView().tint(.black) }
                    else { Label("Download", systemImage: "arrow.down.to.line").font(.caption.bold()) }
                }
                .disabled(library.isBusy || directSWFURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(.black).padding(10).background(FlashKitTheme.accent).clipShape(RoundedRectangle(cornerRadius: 10))
            }.padding(.horizontal, 14)

            HStack {
                Image(systemName: "sparkles").foregroundStyle(FlashKitTheme.accent)
                Text("Browse the web; tap a direct .swf link to add it to My Library.")
                    .font(.caption).foregroundStyle(.gray)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16)

            ArchiveBrowser(address: $browserLocation) { url in
                library.downloadSWF(from: url.absoluteString, suggestedTitle: url.deletingPathExtension().lastPathComponent)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }.padding(.top, 4)
    }

    private var settingsScreen: some View {
        Form {
            Section("Player engine") {
                Picker("Engine", selection: $engine) {
                    Text("Bundled Ruffle").tag("bundled")
                    Text("Experimental Web Player").tag("experimental")
                }
                Text("Bundled Ruffle is the offline option. Experimental mode is a preference placeholder until a compatible alternate engine is packaged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Performance") {
                Picker("Frame-rate target", selection: $fpsCap) {
                    Text("Default").tag("default")
                    Text("30 FPS").tag("30")
                    Text("40 FPS").tag("40")
                    Text("50 FPS").tag("50")
                }
                Picker("Game quality", selection: $quality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Default").tag("high")
                }
                Text("Ruffle's web API does not expose a universal hard FPS cap; the selected target is saved for future engine integration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display and controls") {
                Picker("Orientation preference", selection: $orientation) {
                    Text("Auto").tag("auto")
                    Text("Landscape").tag("landscape")
                    Text("Portrait").tag("portrait")
                }
                Toggle("On-screen controls", isOn: $touchControls)
                Picker("Keyboard layout", selection: $keyboardLayout) {
                    Text("Simple").tag("Simple")
                    Text("Focus").tag("Focus")
                    Text("Double").tag("Double")
                    Text("Quadra").tag("Quadra")
                }
                Text("iOS orientation is controlled by the app's supported-orientation settings. This preference is saved, but per-screen rotation needs device-level testing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library and configuration") {
                Button("Refresh My Library") { library.refresh() }
                Button("Reset settings to default", role: .destructive) {
                    quality = "high"; fpsCap = "default"; orientation = "auto"
                    engine = "bundled"; touchControls = true; keyboardLayout = "Simple"
                }
                Button("Save and reload settings") { showSettingsAlert = true }
                Text("Settings save automatically on this device. Save and reload confirms the current saved configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "FlashKit")
                LabeledContent("Library", value: "Local / offline")
                LabeledContent("Player", value: "Ruffle")
                Text("Only download games you have permission to use. Some sites block downloads or require sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlashKitTheme.background)
        .alert("Settings saved", isPresented: $showSettingsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your preferences are stored on this device and will be restored when FlashKit opens again.")
        }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            navButton("gamecontroller.fill", title: "My Library", tab: 0)
            navButton("safari.fill", title: "Explore", tab: 1)
            navButton("gearshape.fill", title: "Settings", tab: 2)
        }
        .padding(.top, 10).padding(.bottom, 8)
        .background(FlashKitTheme.panel)
    }

    private func navButton(_ symbol: String, title: String, tab: Int) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(selectedTab == tab ? FlashKitTheme.accent : Color.gray)
            .frame(maxWidth: .infinity)
        }
    }

    private func gameDetails(_ url: URL) -> some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button { selectedGame = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.gray)
                }
            }
            Image(systemName: "gamecontroller.fill").font(.system(size: 58)).foregroundStyle(FlashKitTheme.accent)
            Text(library.title(for: url)).font(.title2.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
            Label("Stored on this iPhone", systemImage: "checkmark.icloud.fill")
                .font(.subheadline).foregroundStyle(.green)
            Button {
                selectedGame = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { playingGame = url }
            } label: {
                Label("PLAY GAME", systemImage: "play.fill")
                    .font(.headline.bold()).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding()
                    .background(FlashKitTheme.accent).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Button(role: .destructive) {
                library.delete(url); selectedGame = nil
            } label: {
                Label("Delete game", systemImage: "trash")
                    .font(.subheadline.bold()).foregroundStyle(.red).padding(.top, 8)
            }
            Spacer()
        }
        .padding(24).background(FlashKitTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func normalizedAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://ruffle.rs" }
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }
}

@main
struct FlashKitApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
