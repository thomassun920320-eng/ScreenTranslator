import Cocoa
import SwiftUI
import Vision
import CoreGraphics
import Carbon
import ScreenCaptureKit
import Security

// MARK: - 1. 設定與翻譯引擎模型
enum TranslationEngine: String, CaseIterable, Identifiable {
    case smartFallback = "智慧優先 (AI 優先 -> 失敗或無額度轉免費 Google)"
    case googleFree = "免費公開介面 (Google 翻譯)"
    case gemini = "Google Gemini API"
    case openai = "OpenAI API (GPT-4o-mini)"
    case ollama = "本地離線模型 (Ollama)"

    var id: String { self.rawValue }

    var shortName: String {
        switch self {
        case .smartFallback: return "智慧優先"
        case .googleFree: return "Google 免費"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    var subtitle: String {
        switch self {
        case .smartFallback: return "先用 AI 引擎，失敗自動改用 Google"
        case .googleFree: return "免金鑰、速度快"
        case .gemini: return "需 Gemini API Key"
        case .openai: return "需 OpenAI API Key"
        case .ollama: return "本機離線模型，資料不外流"
        }
    }

    var symbol: String {
        switch self {
        case .smartFallback: return "wand.and.stars"
        case .googleFree: return "globe"
        case .gemini: return "sparkles"
        case .openai: return "brain.head.profile"
        case .ollama: return "desktopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .smartFallback: return .purple
        case .googleFree: return .blue
        case .gemini: return .indigo
        case .openai: return .teal
        case .ollama: return .orange
        }
    }

    static var aiEngines: [TranslationEngine] { [.gemini, .openai, .ollama] }
}

enum HotkeyPreset: String, CaseIterable, Identifiable {
    case fnC = "Fn + C"
    case optC = "Option (⌥) + C"
    case cmdShiftX = "Command (⌘) + Shift + X"
    case ctrlC = "Control (⌃) + C"

    var id: String { self.rawValue }
}

// MARK: 1.1.0 曾把金鑰存進鑰匙圈，但沒有開發者簽章的 App 每次更新後簽章都會改變，
// 讀寫鑰匙圈每次要等 10 秒以上，甚至跳出授權視窗。因此改回存在設定檔，這裡只用來把舊資料搬回來。
enum Keychain {
    private static let service = "com.sunchangxin.screentranslator"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @AppStorage("selectedEngine_v4") var selectedEngine: String = TranslationEngine.smartFallback.rawValue
    @AppStorage("primaryAIEngine_v4") var primaryAIEngine: String = TranslationEngine.gemini.rawValue
    @AppStorage("targetLanguage_v4") var targetLanguage: String = "繁體中文 (zh-TW)"
    @AppStorage("hotkeyPreset_v4") var hotkeyPreset: String = HotkeyPreset.fnC.rawValue

    @AppStorage("geminiApiKey_v4") var geminiApiKey: String = ""
    @AppStorage("geminiModel_v4") var geminiModel: String = "gemini-flash-lite-latest"

    @AppStorage("openAIApiKey_v4") var openAIApiKey: String = ""
    @AppStorage("openAIModel_v4") var openAIModel: String = "gpt-4o-mini"

    @AppStorage("ollamaEndpoint_v4") var ollamaEndpoint: String = "http://localhost:11434"
    @AppStorage("ollamaModel_v4") var ollamaModel: String = "qwen2.5:7b"

    @AppStorage("overlayOpacity_v4") var overlayOpacity: Double = 0.88
    @AppStorage("minTextConfidence_v4") var minTextConfidence: Double = 0.5

    @Published var testStatus: String = "貼上金鑰後，點擊「測試連線」確認是否可用"
    @Published var isTesting = false

    // 在背景把 1.1.0 存進鑰匙圈的金鑰搬回設定檔，只執行一次
    func migrateKeychainKeysIfNeeded() {
        let flag = "keychainMigratedBack_v5"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        DispatchQueue.global(qos: .utility).async {
            let gemini = Keychain.read("geminiApiKey"), openAI = Keychain.read("openAIApiKey")
            DispatchQueue.main.async {
                if self.geminiApiKey.isEmpty && !gemini.isEmpty { self.geminiApiKey = gemini }
                if self.openAIApiKey.isEmpty && !openAI.isEmpty { self.openAIApiKey = openAI }
                UserDefaults.standard.set(true, forKey: flag)
                appLog("已將鑰匙圈中的金鑰搬回設定檔")
                DispatchQueue.global(qos: .utility).async { Keychain.write("", for: "geminiApiKey"); Keychain.write("", for: "openAIApiKey") }
            }
        }
    }

    var targetLangCode: String {
        if targetLanguage.contains("zh-TW") { return "zh-TW" }
        if targetLanguage.contains("zh-CN") { return "zh-CN" }
        if targetLanguage.contains("en") { return "en" }
        if targetLanguage.contains("ja") { return "ja" }
        if targetLanguage.contains("ko") { return "ko" }
        return "zh-TW"
    }
}

// MARK: - 2. 辨識與翻譯資料結構
struct OCRTextBox: Identifiable, Sendable {
    let id = UUID()
    let originalText: String
    var translatedText: String
    let normalizedRect: CGRect
}

// MARK: - 3. 翻譯服務 (含 503 自動重試與智慧降級)
class TranslationService {
    static let shared = TranslationService()

    func translateBatch(texts: [String]) async -> (results: [String], usedEngineName: String) {
        guard !texts.isEmpty else { return ([], "無") }
        let settings = SettingsManager.shared
        let engine = TranslationEngine(rawValue: settings.selectedEngine) ?? .smartFallback

        let aiEngine: TranslationEngine
        switch engine {
        case .googleFree:
            return (await translateWithGoogleFree(texts: texts, targetLang: settings.targetLangCode), "Google 免費翻譯")
        case .smartFallback:
            aiEngine = TranslationEngine(rawValue: settings.primaryAIEngine) ?? .gemini
            // 智慧模式下未填金鑰就直接走 Google，不浪費一次失敗請求
            if (aiEngine == .gemini && settings.geminiApiKey.trimmingCharacters(in: .whitespaces).isEmpty) ||
               (aiEngine == .openai && settings.openAIApiKey.trimmingCharacters(in: .whitespaces).isEmpty) {
                return (await translateWithGoogleFree(texts: texts, targetLang: settings.targetLangCode), "Google 免費翻譯 (未設定 \(aiEngine.shortName) 金鑰)")
            }
        default:
            aiEngine = engine
        }

        do {
            let res: [String]
            switch aiEngine {
            case .openai: res = try await translateWithOpenAI(texts: texts, targetLang: settings.targetLanguage)
            case .ollama: res = try await translateWithOllama(texts: texts, targetLang: settings.targetLanguage)
            default: res = try await translateWithGemini(texts: texts, targetLang: settings.targetLanguage)
            }
            return (res, aiEngine.shortName)
        } catch {
            let fallback = await translateWithGoogleFree(texts: texts, targetLang: settings.targetLangCode)
            return (fallback, "Google 免費翻譯 (\(aiEngine.shortName) 失敗: \(error.localizedDescription))")
        }
    }

    // 只保留未保留字元，避免文字中的 & + = # 等符號破壞查詢字串
    private static let queryValueAllowed: CharacterSet = {
        // 不能用 .alphanumerics：它包含中文等 Unicode 字母，未編碼會讓網址無效
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()

    private func translateWithGoogleFree(texts: [String], targetLang: String) async -> [String] {
        // 依網址長度分批，避免一次塞太多文字導致請求失敗
        var chunks: [[String]] = [[]]; var length = 0
        for text in texts {
            let encodedLength = (text.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? text).count + 30
            if length + encodedLength > 5000 && !chunks[chunks.count - 1].isEmpty { chunks.append([]); length = 0 }
            chunks[chunks.count - 1].append(text); length += encodedLength
        }
        var output: [String] = []
        for chunk in chunks {
            // 每句一行送出；Google 會保留換行，回傳後依行拆回
            let lines = chunk.map { $0.replacingOccurrences(of: "\n", with: " ") }
            if let joined = await googleRequest(lines.joined(separator: "\n"), targetLang: targetLang) {
                let parts = joined.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == chunk.count { output += parts; continue }
                appLog("Google 分行數不符（\(parts.count)/\(chunk.count)），改為逐句翻譯")
            }
            // 分隔符號被翻譯引擎吃掉時，改成逐句平行翻譯
            output += await withTaskGroup(of: (Int, String).self) { group in
                for (i, text) in chunk.enumerated() {
                    group.addTask { (i, await self.googleRequest(text, targetLang: targetLang) ?? text) }
                }
                var results = chunk
                for await (i, text) in group { results[i] = text }
                return results
            }
        }
        return output
    }

    private func googleRequest(_ text: String, targetLang: String) async -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(targetLang)&dt=t&q=\(encoded)") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            appLog("Google 請求失敗（\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）"); return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { appLog("Google 回應 HTTP \(status)"); return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = json.first as? [[Any]] else { return nil }
        return sentences.compactMap { $0.first as? String }.joined()
    }

    private func translationPrompt(_ texts: [String], targetLang: String) throws -> String {
        let inputJson = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8) ?? "[]"
        return """
        You are a professional UI and document translator. Translate each string in the following JSON array into \(targetLang).
        Keep the exact same number of elements and order. Respond with JSON only, in the form {"translations": ["...", "..."]}.
        Input:
        \(inputJson)
        """
    }

    // 接受 {"translations": [...]} 或純陣列，並去除 markdown 程式碼框
    private func parseTranslations(_ raw: String, expectedCount: Int) throws -> [String] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: .newlines).dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = cleaned.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            throw TranslationError("回傳內容不是有效的 JSON")
        }
        let arr = (json as? [String]) ?? ((json as? [String: Any])?["translations"] as? [String])
        guard let arr, arr.count == expectedCount else { throw TranslationError("回傳句數與原文不符") }
        return arr
    }

    private func apiErrorMessage(_ data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return "HTTP \(status): \(msg)" }
            if let msg = json["error"] as? String { return "HTTP \(status): \(msg)" }
        }
        return "HTTP \(status)"
    }

    // MARK: Gemini API (若遇 503 伺服器繁忙，自動切換至輕量模型重試)
    private func translateWithGemini(texts: [String], targetLang: String) async throws -> [String] {
        let apiKey = SettingsManager.shared.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let userModel = SettingsManager.shared.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError("未設定 Gemini API Key") }

        var seen = Set<String>()
        let candidateModels = [userModel, "gemini-flash-lite-latest", "gemini-flash-latest"].filter { !$0.isEmpty && seen.insert($0).inserted }

        let body: [String: Any] = [
            "contents": [["parts": [["text": try translationPrompt(texts, targetLang: targetLang)]]]],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var lastError = "連線失敗"

        for model in candidateModels {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key") // 金鑰放在標頭，不出現在網址中
            request.timeoutInterval = 15
            request.httpBody = bodyData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else { continue }

            if httpResp.statusCode == 200 {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let textOut = parts.first?["text"] as? String else { throw TranslationError("Gemini 回傳格式異常") }
                return try parseTranslations(textOut, expectedCount: texts.count)
            }
            lastError = apiErrorMessage(data, status: httpResp.statusCode)
            // 若為 503 塞車或 404 模型名稱不對，自動嘗試下一個備用模型
            if httpResp.statusCode != 503 && httpResp.statusCode != 404 { break }
        }
        throw TranslationError(lastError)
    }

    private func translateWithOpenAI(texts: [String], targetLang: String) async throws -> [String] {
        let settings = SettingsManager.shared
        let apiKey = settings.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError("未設定 OpenAI API Key") }
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.isEmpty ? "gpt-4o-mini" : model,
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": try translationPrompt(texts, targetLang: targetLang)]]
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TranslationError(apiErrorMessage(data, status: status)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw TranslationError("OpenAI 回傳格式異常") }
        return try parseTranslations(content, expectedCount: texts.count)
    }

    private func translateWithOllama(texts: [String], targetLang: String) async throws -> [String] {
        let settings = SettingsManager.shared
        let endpoint = settings.ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/api/chat") else { throw TranslationError("Ollama 位址格式錯誤") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.ollamaModel,
            "stream": false,
            "format": "json",
            "messages": [["role": "user", "content": try translationPrompt(texts, targetLang: targetLang)]]
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TranslationError(apiErrorMessage(data, status: status)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else { throw TranslationError("Ollama 回傳格式異常") }
        return try parseTranslations(content, expectedCount: texts.count)
    }
}

struct TranslationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 3.5 文字辨識 (Vision)
func appLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTranslator.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
    else { try? Data(line.utf8).write(to: url) }
}

enum OCRError: Error { case busy, timeout }

// Vision 第一次辨識需要 30～40 秒準備模型，而且同時跑多個請求時可能互相卡死。
// 因此所有辨識都排在同一條專用佇列上一次只跑一個，啟動時先暖機，並設定逾時避免畫面永遠轉圈。
final class OCREngine: @unchecked Sendable { // 狀態皆由 lock 保護
    static let shared = OCREngine()
    private let queue = DispatchQueue(label: "com.sunchangxin.screentranslator.ocr", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private(set) var isWarm = false

    func warmUp() {
        guard let image = Self.sampleImage() else { return }
        let start = Date()
        lock.lock(); busy = true; lock.unlock()
        queue.async {
            _ = Self.recognize(image, minConfidence: 0)
            self.lock.lock(); self.busy = false; self.isWarm = true; self.lock.unlock()
            appLog("OCR 暖機完成，耗時 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
        }
    }

    func recognize(_ image: CGImage, minConfidence: Float, timeout: TimeInterval) async -> Result<[OCRTextBox], OCRError> {
        let acquired = lock.withLock { () -> Bool in if busy { return false }; busy = true; return true }
        guard acquired else { return .failure(.busy) }
        let plain = Self.plainCopy(of: image) ?? image
        return await withCheckedContinuation { continuation in
            let once = NSLock(); var resumed = false
            let finish: (Result<[OCRTextBox], OCRError>) -> Void = { result in
                once.lock(); defer { once.unlock() }
                guard !resumed else { return }; resumed = true; continuation.resume(returning: result)
            }
            queue.async {
                let boxes = Self.recognize(plain, minConfidence: minConfidence)
                self.lock.lock(); self.busy = false; self.isWarm = true; self.lock.unlock()
                finish(.success(boxes))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(.timeout)) }
        }
    }

    private static func recognize(_ cgImage: CGImage, minConfidence: Float) -> [OCRTextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "ja-JP", "zh-Hant", "zh-Hans", "ko-KR"]
        do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
        catch { appLog("OCR 失敗：\(error.localizedDescription)"); return [] }
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1, text.rangeOfCharacter(from: .letters) != nil else { return nil }
            return OCRTextBox(originalText: text, translatedText: text, normalizedRect: obs.boundingBox)
        }
    }

    // 螢幕擷取的影像由 IOSurface 支撐，先複製成一般點陣圖再交給 Vision
    private static func plainCopy(of image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func sampleImage() -> CGImage? {
        let size = NSSize(width: 480, height: 120)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Hello 你好 こんにちは" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - 4. 視窗介面與系統底層
class TransparentOverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.isOpaque = false; self.backgroundColor = .clear; self.level = .statusBar
        self.ignoresMouseEvents = true; self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; self.isReleasedWhenClosed = false
    }
}

let brandGradient = LinearGradient(colors: [Color(red: 0.36, green: 0.33, blue: 0.98), Color(red: 0.62, green: 0.30, blue: 0.96), Color(red: 0.13, green: 0.74, blue: 0.93)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

struct OverlayContentView: View {
    let boxes: [OCRTextBox]; let windowSize: CGSize; let engineBadge: String; let isLoading: Bool
    var loadingText = "正在辨識與翻譯…"
    @ObservedObject var settings = SettingsManager.shared

    private var shortBadge: String { engineBadge.count > 56 ? String(engineBadge.prefix(55)) + "…" : engineBadge }
    private var isFallback: Bool { ["失敗", "未設定", "逾時", "仍在", "未偵測"].contains { engineBadge.contains($0) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(boxes) { box in
                let rect = convertVisionRect(box.normalizedRect, in: windowSize)
                Text(box.translatedText)
                    .font(.system(size: max(11, min(rect.height * 0.78, 26)), weight: .medium, design: .rounded))
                    .foregroundColor(.white).minimumScaleFactor(0.45)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .frame(minWidth: max(rect.width + 10, 36), maxWidth: max(rect.width * 1.35, 120), minHeight: max(rect.height + 6, 20), alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.12).opacity(settings.overlayOpacity))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    )
                    .position(x: rect.midX, y: rect.midY)
            }

            statusBadge
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(isLoading ? AnyShapeStyle(brandGradient) : AnyShapeStyle(isFallback ? Color.orange.gradient : Color.green.gradient))
                    .frame(width: 22, height: 22)
                if isLoading { ProgressView().controlSize(.small).scaleEffect(0.6).tint(.white) }
                else { Image(systemName: isFallback ? "exclamationmark" : "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(isLoading ? loadingText : (boxes.isEmpty ? shortBadge : "已翻譯 · \(shortBadge)"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                if !isLoading {
                    Text("再按 \(settings.hotkeyPreset) 或 Esc 關閉").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
        .fixedSize()
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func convertVisionRect(_ norm: CGRect, in size: CGSize) -> CGRect {
        return CGRect(x: norm.minX * size.width, y: (1.0 - norm.maxY) * size.height, width: norm.width * size.width, height: norm.height * size.height)
    }
}

// MARK: - 5. 偏好設定介面
struct IconBadge: View {
    let symbol: String; let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

struct SettingRow<Content: View>: View {
    let symbol: String; let color: Color; let title: String
    @ViewBuilder let content: Content
    var body: some View {
        LabeledContent {
            content
        } label: {
            HStack(spacing: 10) { IconBadge(symbol: symbol, color: color); Text(title) }
        }
    }
}

// 僅安裝 Command Line Tools 時 @State 巨集無法使用，改以 ObservableObject 保存顯示狀態
final class RevealState: ObservableObject { @Published var revealed = false }

struct SecretField: View {
    let placeholder: String; @Binding var text: String
    @StateObject private var state = RevealState()
    private var revealed: Bool { state.revealed }
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed { TextField("", text: $text, prompt: Text(placeholder)) } else { SecureField("", text: $text, prompt: Text(placeholder)) }
            }
            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).multilineTextAlignment(.leading).labelsHidden()
            Button { state.revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless).help(revealed ? "隱藏金鑰" : "顯示金鑰")
        }
    }
}

struct EngineCard: View {
    let engine: TranslationEngine; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    IconBadge(symbol: engine.symbol, color: engine.tint)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(engine.tint) : AnyShapeStyle(.tertiary))
                }
                Text(engine.shortName).font(.system(size: 13, weight: .semibold))
                Text(engine.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? engine.tint.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? engine.tint.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct PreferencesHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("ScreenTranslator").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("一鍵辨識並翻譯目前視窗中的文字").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 2)
    }
}

enum PrefTab: String, CaseIterable, Identifiable {
    case general = "一般", engine = "翻譯引擎", api = "API 金鑰"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: return "gearshape"; case .engine: return "cpu"; case .api: return "key.horizontal" }
    }
}
final class PrefTabState: ObservableObject { @Published var selected: PrefTab = .general }

struct PreferencesView: View {
    @ObservedObject var settings = SettingsManager.shared
    @StateObject private var tabState = PrefTabState()
    let languages = ["繁體中文 (zh-TW)", "簡體中文 (zh-CN)", "English (en)", "日本語 (ja)", "한국어 (ko)"]

    var body: some View {
        VStack(spacing: 0) {
            PreferencesHeader()
            HStack(spacing: 4) {
                ForEach(PrefTab.allCases) { tab in
                    Button { tabState.selected = tab } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                            Text(tab.rawValue).font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(tabState.selected == tab ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 92, height: 54)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tabState.selected == tab ? Color.accentColor.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            Divider().padding(.top, 10)
            Group {
                switch tabState.selected {
                case .general: generalTab
                case .engine: engineTab
                case .api: apiTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 660, idealWidth: 680, maxWidth: .infinity, minHeight: 520, idealHeight: 560, maxHeight: .infinity)
    }

    private var generalTab: some View {
        Form {
            Section("觸發") {
                SettingRow(symbol: "command", color: .gray, title: "全域快捷鍵") {
                    Picker("", selection: $settings.hotkeyPreset) { ForEach(HotkeyPreset.allCases) { p in Text(p.rawValue).tag(p.rawValue) } }.labelsHidden().fixedSize()
                }
                SettingRow(symbol: "character.book.closed", color: .blue, title: "目標語言") {
                    Picker("", selection: $settings.targetLanguage) { ForEach(languages, id: \.self) { l in Text(l).tag(l) } }.labelsHidden().fixedSize()
                }
            }
            Section("顯示") {
                SettingRow(symbol: "circle.lefthalf.filled", color: .indigo, title: "譯文底色不透明度") {
                    HStack {
                        Slider(value: $settings.overlayOpacity, in: 0.4...1.0, step: 0.05).frame(width: 200)
                        Text("\(Int(settings.overlayOpacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                SettingRow(symbol: "text.viewfinder", color: .green, title: "文字辨識信心門檻") {
                    HStack {
                        Slider(value: $settings.minTextConfidence, in: 0.0...0.9, step: 0.05).frame(width: 200)
                        Text("\(Int(settings.minTextConfidence * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section {
                Text("首次使用需在「系統設定 → 隱私權與安全性」中開啟「螢幕錄製」與「輔助使用」權限。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("開啟螢幕錄製設定") { openPrivacyPane("Privacy_ScreenCapture") }
                    Button("開啟輔助使用設定") { openPrivacyPane("Privacy_Accessibility") }
                }
            } header: { Text("權限") }
        }
        .formStyle(.grouped)
    }

    private var engineTab: some View {
        Form {
            Section("運作模式") {
                VStack(spacing: 10) {
                    // 上排：兩種免設定即可用的模式；下排：三個 AI 引擎
                    engineRow([.smartFallback, .googleFree])
                    engineRow(TranslationEngine.aiEngines)
                }
                .padding(.vertical, 4)
            }
            if settings.selectedEngine == TranslationEngine.smartFallback.rawValue {
                Section("智慧優先模式") {
                    SettingRow(symbol: "star.fill", color: .yellow, title: "優先使用的 AI 引擎") {
                        Picker("", selection: $settings.primaryAIEngine) {
                            ForEach(TranslationEngine.aiEngines) { e in Text(e.shortName).tag(e.rawValue) }
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                }
            }
            Section("測試") { testRow }
        }
        .formStyle(.grouped)
    }

    private var apiTab: some View {
        Form {
            Section {
                SettingRow(symbol: "key.fill", color: TranslationEngine.gemini.tint, title: "API Key") {
                    SecretField(placeholder: "AIzaSy…", text: $settings.geminiApiKey).frame(width: 300)
                }
                SettingRow(symbol: "cube", color: TranslationEngine.gemini.tint, title: "模型名稱") {
                    TextField("", text: $settings.geminiModel, prompt: Text("gemini-flash-lite-latest")).textFieldStyle(.roundedBorder).frame(width: 300)
                }
            } header: { Label("Google Gemini", systemImage: TranslationEngine.gemini.symbol) }

            Section {
                SettingRow(symbol: "key.fill", color: TranslationEngine.openai.tint, title: "API Key") {
                    SecretField(placeholder: "sk-…", text: $settings.openAIApiKey).frame(width: 300)
                }
                SettingRow(symbol: "cube", color: TranslationEngine.openai.tint, title: "模型名稱") {
                    TextField("", text: $settings.openAIModel, prompt: Text("gpt-4o-mini")).textFieldStyle(.roundedBorder).frame(width: 300)
                }
            } header: { Label("OpenAI", systemImage: TranslationEngine.openai.symbol) }

            Section {
                SettingRow(symbol: "link", color: TranslationEngine.ollama.tint, title: "伺服器位址") {
                    TextField("", text: $settings.ollamaEndpoint, prompt: Text("http://localhost:11434")).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingRow(symbol: "cube", color: TranslationEngine.ollama.tint, title: "模型名稱") {
                    TextField("", text: $settings.ollamaModel, prompt: Text("qwen2.5:7b")).textFieldStyle(.roundedBorder).frame(width: 300)
                }
            } header: { Label("Ollama（本機）", systemImage: TranslationEngine.ollama.symbol) }

            Section { testRow } footer: {
                Text("金鑰只存在這台 Mac 的設定檔中，只有你的使用者帳號可以讀取。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func engineRow(_ engines: [TranslationEngine]) -> some View {
        HStack(spacing: 10) {
            ForEach(engines) { engine in
                EngineCard(engine: engine, isSelected: settings.selectedEngine == engine.rawValue) { settings.selectedEngine = engine.rawValue }
            }
        }
    }

    private var testRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                settings.isTesting = true
                settings.testStatus = "測試連線中…"
                Task {
                    let res = await TranslationService.shared.translateBatch(texts: ["Hello World"])
                    await MainActor.run {
                        let ok = !res.usedEngineName.contains("失敗") && !res.usedEngineName.contains("未設定")
                        settings.testStatus = "\(ok ? "✅" : "⚠️") 譯文：「\(res.results.first ?? "")」\n使用：\(res.usedEngineName)"
                        settings.isTesting = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if settings.isTesting { ProgressView().controlSize(.small) } else { Image(systemName: "bolt.horizontal.fill") }
                    Text("測試連線")
                }
            }
            .buttonStyle(.borderedProminent).disabled(settings.isTesting)
            Text(settings.testStatus)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 6. 應用程式主體
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!; var overlayWindow: TransparentOverlayWindow?; var preferencesWindow: NSWindow?
    var globalKeyMonitor: Any?; var localKeyMonitor: Any?; var eventTap: CFMachPort?; var runLoopSource: CFRunLoopSource?
    var carbonHotKeyRef: EventHotKeyRef?; var carbonEventHandler: EventHandlerRef?; var registeredPreset: String?
    var toggleMenuItem: NSMenuItem?
    var isOverlayShowing = false; var isProcessing = false; var isFnDown = false; var lastFnPressTime: Date = .distantPast; var lastTriggerTime: Date = .distantPast
    var captureGeneration = 0 // 每次觸發遞增，避免舊的翻譯結果覆蓋新畫面

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupApplicationEditMenu() // 啟用 ⌘+C, ⌘+V, ⌘+A, ⌘+X 等鍵盤編輯快捷鍵
        setupMenuBar()
        setupGlobalHotkeyMonitors()
        OCREngine.shared.warmUp()
        SettingsManager.shared.migrateKeychainKeysIfNeeded()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    // MARK: 關鍵修正：為無邊框/常駐程式掛載系統 Edit 選單，讓 ⌘+C / ⌘+V / ⌘+A 生效
    private func setupApplicationEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "偏好設定...", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "結束 ScreenTranslator", action: #selector(quitApp), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "視窗翻譯")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: "ScreenTranslator", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let toggleItem = menuItem("", symbol: "text.viewfinder", action: #selector(toggleTranslationOverlay))
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("偏好設定…", symbol: "gearshape", action: #selector(openPreferences), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("結束翻譯小工具", symbol: "power", action: #selector(quitApp), key: "q"))
        statusItem.menu = menu
        updateToggleMenuTitle()
    }

    private func updateToggleMenuTitle() {
        toggleMenuItem?.title = "翻譯 / 關閉目前視窗 (\(SettingsManager.shared.hotkeyPreset))"
    }

    private func setupGlobalHotkeyMonitors() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(eventMask), callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let mySelf = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = mySelf.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if mySelf.handleHardwareCGEvent(type: type, event: event) { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) {
            self.eventTap = tap; let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        }
        setupCarbonHotKey()
        // 只在快捷鍵設定真的改變時才重新註冊（原本每次任何設定變動都會重新註冊）
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.registeredPreset != SettingsManager.shared.hotkeyPreset else { return }
            self.setupCarbonHotKey(); self.updateToggleMenuTitle()
        }
        let fallbackHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }; if let tap = self.eventTap, CGEvent.tapIsEnabled(tap: tap) { return }; self.handleFallbackNSEvent(event)
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: fallbackHandler)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in fallbackHandler(event); return event }
    }

    private func handleHardwareCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode); let flags = event.flags
        if type == .flagsChanged {
            let fnPressed = flags.contains(.maskSecondaryFn) || (keyCode == 63 && !isFnDown)
            if flags.contains(.maskSecondaryFn) { isFnDown = true; lastFnPressTime = Date() }
            else if keyCode == 63 { isFnDown = fnPressed; if isFnDown { lastFnPressTime = Date() } }
            else { isFnDown = false }; return false
        }
        guard type == .keyDown else { return false }
        if keyCode == 53 && isOverlayShowing { DispatchQueue.main.async { self.hideOverlay() }; return true }
        let preset = HotkeyPreset(rawValue: SettingsManager.shared.hotkeyPreset) ?? .fnC
        let hasCmd = flags.contains(.maskCommand); let hasOpt = flags.contains(.maskAlternate); let hasCtrl = flags.contains(.maskControl); let hasShift = flags.contains(.maskShift); let hasFn = flags.contains(.maskSecondaryFn) || isFnDown || Date().timeIntervalSince(lastFnPressTime) < 0.55
        var matched = false
        switch preset {
        case .fnC: if keyCode == 8 && hasFn && !hasCmd && !hasOpt && !hasCtrl { matched = true }
        case .optC: if keyCode == 8 && hasOpt && !hasCmd && !hasCtrl && !hasShift { matched = true }
        case .cmdShiftX: if keyCode == 7 && hasCmd && hasShift && !hasOpt && !hasCtrl { matched = true }
        case .ctrlC: if keyCode == 8 && hasCtrl && !hasCmd && !hasOpt && !hasShift { matched = true }
        }
        if matched { triggerDebouncedToggle(); return true }; return false
    }

    private func setupCarbonHotKey() {
        if let ref = carbonHotKeyRef { UnregisterEventHotKey(ref); carbonHotKeyRef = nil }
        if carbonEventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }; let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                appDelegate.triggerDebouncedToggle(); return noErr
            }, 1, &eventType, selfPtr, &carbonEventHandler)
        }
        registeredPreset = SettingsManager.shared.hotkeyPreset
        let preset = HotkeyPreset(rawValue: SettingsManager.shared.hotkeyPreset) ?? .fnC; let hotKeyID = EventHotKeyID(signature: OSType(0x534F5452), id: 1)
        switch preset {
        case .fnC: break
        case .optC: RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
        case .cmdShiftX: RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
        case .ctrlC: RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey), hotKeyID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
        }
    }

    private func handleFallbackNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 && isOverlayShowing { DispatchQueue.main.async { self.hideOverlay() }; return }
        if event.type == .flagsChanged { if event.modifierFlags.contains(.function) { lastFnPressTime = Date() }; return }
        guard event.type == .keyDown else { return }
        let preset = HotkeyPreset(rawValue: SettingsManager.shared.hotkeyPreset) ?? .fnC; let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if preset == .fnC {
            if event.keyCode == 8 && (flags.contains(.function) || Date().timeIntervalSince(lastFnPressTime) < 0.55) && flags.intersection([.command, .option, .control]).isEmpty { triggerDebouncedToggle() }
        }
    }

    private func triggerDebouncedToggle() {
        let now = Date(); guard now.timeIntervalSince(lastTriggerTime) > 0.25 else { return }; lastTriggerTime = now; DispatchQueue.main.async { self.toggleTranslationOverlay() }
    }
    @objc func toggleTranslationOverlay() {
        if isOverlayShowing { hideOverlay(); return }; guard !isProcessing else { return }; captureAndTranslateActiveWindow()
    }
    func hideOverlay() { captureGeneration += 1; overlayWindow?.orderOut(nil); overlayWindow = nil; isOverlayShowing = false; isProcessing = false }

    private func captureAndTranslateActiveWindow() {
        guard !isProcessing else { return }; guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }; let pid = activeApp.processIdentifier
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        isProcessing = true; isOverlayShowing = true
        captureGeneration += 1; let generation = captureGeneration
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let targetWindow = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 120 }) else { await MainActor.run { self.hideOverlay() }; return }
                let cgBounds = targetWindow.frame; let filter = SCContentFilter(desktopIndependentWindow: targetWindow); let config = SCStreamConfiguration()
                let cocoaFrame = NSRect(x: cgBounds.origin.x, y: primaryScreenHeight - cgBounds.origin.y - cgBounds.height, width: cgBounds.width, height: cgBounds.height)
                // 以實際像素擷取 (Retina 為 2 倍)，文字辨識準確度大幅提升
                let scale = await MainActor.run { NSScreen.screens.first(where: { $0.frame.intersects(cocoaFrame) })?.backingScaleFactor ?? 2.0 }
                config.width = Int(cgBounds.width * scale); config.height = Int(cgBounds.height * scale); config.showsCursor = false
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let loadingText = OCREngine.shared.isWarm ? "正在辨識與翻譯…" : "首次使用，正在準備文字辨識模型（約 30 秒）…"
                await MainActor.run { guard generation == self.captureGeneration else { return }; self.showOverlayWindow(frame: cocoaFrame, boxes: [], engineName: "", isLoading: true, loadingText: loadingText) }
                appLog("開始辨識 \(cgImage.width)x\(cgImage.height)")
                let ocrStart = Date()
                let recognizedBoxes: [OCRTextBox]
                switch await OCREngine.shared.recognize(cgImage, minConfidence: Float(SettingsManager.shared.minTextConfidence), timeout: OCREngine.shared.isWarm ? 20 : 75) {
                case .success(let boxes): recognizedBoxes = boxes
                case .failure(let error):
                    appLog("辨識未完成：\(error)")
                    let message = error == .busy ? "文字辨識模型仍在準備中，請稍後再試" : "文字辨識逾時，請再按一次快捷鍵重試"
                    await MainActor.run { guard generation == self.captureGeneration else { return }; self.showOverlayWindow(frame: cocoaFrame, boxes: [], engineName: message, isLoading: false); self.isProcessing = false }
                    return
                }
                appLog("辨識完成：\(recognizedBoxes.count) 段文字，耗時 \(String(format: "%.1f", Date().timeIntervalSince(ocrStart))) 秒")
                if recognizedBoxes.isEmpty {
                    await MainActor.run { guard generation == self.captureGeneration else { return }; self.showOverlayWindow(frame: cocoaFrame, boxes: [], engineName: "未偵測到文字", isLoading: false); self.isProcessing = false }
                    return
                }
                let sourceTexts = recognizedBoxes.map { $0.originalText }; let translateStart = Date(); let (translatedTexts, usedEngine) = await TranslationService.shared.translateBatch(texts: sourceTexts)
                appLog("翻譯完成：\(usedEngine)，耗時 \(String(format: "%.1f", Date().timeIntervalSince(translateStart))) 秒")
                let finalBoxes: [OCRTextBox] = recognizedBoxes.enumerated().map { (idx, box) in var newBox = box; if idx < translatedTexts.count { newBox.translatedText = translatedTexts[idx] }; return newBox }
                await MainActor.run { guard generation == self.captureGeneration else { return }; self.showOverlayWindow(frame: cocoaFrame, boxes: finalBoxes, engineName: usedEngine, isLoading: false); self.isProcessing = false }
            } catch { appLog("擷取失敗：\(error.localizedDescription)"); await MainActor.run { guard generation == self.captureGeneration else { return }; self.hideOverlay() } }
        }
    }

    private func showOverlayWindow(frame: NSRect, boxes: [OCRTextBox], engineName: String, isLoading: Bool, loadingText: String = "正在辨識與翻譯…") {
        if overlayWindow == nil { overlayWindow = TransparentOverlayWindow(frame: frame) } else { overlayWindow?.setFrame(frame, display: true) }
        overlayWindow?.contentView = NSHostingView(rootView: OverlayContentView(boxes: boxes, windowSize: frame.size, engineBadge: engineName, isLoading: isLoading, loadingText: loadingText)); overlayWindow?.orderFrontRegardless()
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ScreenTranslator 偏好設定"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: PreferencesView()); window.center(); window.isReleasedWhenClosed = false; preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

// MARK: - 7. 應用程式入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
