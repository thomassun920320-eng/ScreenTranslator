import Cocoa
import SwiftUI
import Vision
import CoreGraphics
import Carbon
import ScreenCaptureKit
import Security
import ServiceManagement

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

enum OverlayStyle: String, CaseIterable, Identifiable {
    case inPlace = "原地取代"
    case label = "深色標籤"
    var id: String { rawValue }
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

    // 1.1.3 改為原地取代樣式，預設完全不透明才能蓋住原文，因此換新的設定鍵
    @AppStorage("overlayOpacity_v5") var overlayOpacity: Double = 1.0
    @AppStorage("overlayStyle_v5") var overlayStyle: String = OverlayStyle.inPlace.rawValue
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
struct RGB: Sendable, Equatable {
    var r: Double, g: Double, b: Double
    static let white = RGB(r: 1, g: 1, b: 1), black = RGB(r: 0, g: 0, b: 0)
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var color: Color { Color(red: r, green: g, blue: b) }
}

struct OCRTextBox: Identifiable, Sendable {
    let id = UUID()
    let originalText: String
    var translatedText: String
    let normalizedRect: CGRect
    var background: RGB = .black // 原文周圍的背景色
    var foreground: RGB = .white // 原文的文字顏色
}

// 螢幕截圖的 RGBA 像素，用來取樣原文的背景色與文字色，讓譯文能「原地取代」
struct PixelBuffer {
    let data: [UInt8]; let width: Int; let height: Int; let bytesPerRow: Int

    init?(_ image: CGImage) {
        let w = image.width, h = image.height, rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return nil }
        data = bytes; width = w; height = h; bytesPerRow = rowBytes
    }

    // 以左上為原點的像素座標
    func pixel(_ x: Int, _ y: Int) -> RGB {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let i = cy * bytesPerRow + cx * 4
        return RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255)
    }

    /// Vision 的正規化座標（原點在左下）→ 取樣背景色與文字色
    func colors(for norm: CGRect) -> (background: RGB, foreground: RGB) {
        let x0 = Int(norm.minX * Double(width)), x1 = Int(norm.maxX * Double(width))
        let y0 = Int((1 - norm.maxY) * Double(height)), y1 = Int((1 - norm.minY) * Double(height))
        guard x1 > x0, y1 > y0 else { return (.black, .white) }
        let pad = max(2, (y1 - y0) / 6)

        // 背景：取框外一圈像素的中位數
        var ring: [RGB] = []
        let stepX = max(1, (x1 - x0) / 60), stepY = max(1, (y1 - y0) / 12)
        for x in stride(from: x0 - pad, through: x1 + pad, by: stepX) { ring.append(pixel(x, y0 - pad)); ring.append(pixel(x, y1 + pad)) }
        for y in stride(from: y0, through: y1, by: stepY) { ring.append(pixel(x0 - pad, y)); ring.append(pixel(x1 + pad, y)) }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let bg = RGB(r: median(ring.map(\.r)), g: median(ring.map(\.g)), b: median(ring.map(\.b)))

        // 文字：框內與背景差異最大的前 15% 像素平均
        var inside: [(RGB, Double)] = []
        let sx = max(1, (x1 - x0) / 80), sy = max(1, (y1 - y0) / 16)
        for y in stride(from: y0, to: y1, by: sy) {
            for x in stride(from: x0, to: x1, by: sx) {
                let p = pixel(x, y)
                inside.append((p, abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b)))
            }
        }
        inside.sort { $0.1 > $1.1 }
        let top = inside.prefix(max(1, inside.count * 15 / 100))
        var fg = RGB(r: top.map(\.0.r).reduce(0, +) / Double(top.count), g: top.map(\.0.g).reduce(0, +) / Double(top.count), b: top.map(\.0.b).reduce(0, +) / Double(top.count))
        // 對比太低（例如反鋸齒或取樣失敗）時，改用黑或白確保看得清楚
        if abs(fg.luminance - bg.luminance) < 0.35 { fg = bg.luminance > 0.5 ? RGB(r: 0.1, g: 0.1, b: 0.12) : .white }
        return (bg, fg)
    }
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
        let plain = image
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

    private static func describe(_ image: CGImage) -> String {
        "\(image.width)x\(image.height) bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) info=\(image.bitmapInfo.rawValue) cs=\((image.colorSpace?.name as String?) ?? "nil")"
    }

    private static func perform(_ image: CGImage) -> Result<[VNRecognizedTextObservation], Error> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "ja-JP", "zh-Hant", "zh-Hans", "ko-KR"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]); return .success(request.results ?? []) }
        catch { return .failure(error) }
    }

    private static func recognize(_ input: CGImage, minConfidence: Float) -> [OCRTextBox] {
        // 有些 App（例如 FreeShow 等 Electron 程式）擷取到的影像格式 Vision 讀不了，依序換格式重試
        var cgImage = input
        var observations: [VNRecognizedTextObservation] = []
        var attempts: [(String, () -> CGImage?)] = [("原圖", { input })]
        attempts.append(("sRGB 不透明", { plainCopy(of: input, scale: 1) }))
        attempts.append(("縮小一半", { plainCopy(of: input, scale: 0.5) }))
        for (index, (name, make)) in attempts.enumerated() {
            guard let candidate = make() else { appLog("OCR 轉換失敗（\(name)）"); continue }
            switch perform(candidate) {
            case .success(let result):
                if index > 0 { appLog("OCR 改用「\(name)」格式後成功") }
                cgImage = candidate; observations = result
            case .failure(let error):
                appLog("OCR 失敗（\(name)，\(describe(candidate))）：\(error.localizedDescription)")
                continue
            }
            break
        }
        let pixels = PixelBuffer(cgImage)
        return observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1, text.rangeOfCharacter(from: .letters) != nil else { return nil }
            var box = OCRTextBox(originalText: text, translatedText: text, normalizedRect: obs.boundingBox)
            if let colors = pixels?.colors(for: obs.boundingBox) { box.background = colors.background; box.foreground = colors.foreground }
            return box
        }
    }

    // 複製成 8 位元 sRGB、不透明的一般點陣圖（螢幕擷取的影像由 IOSurface 支撐，格式可能是 HDR 或廣色域）
    private static func plainCopy(of image: CGImage, scale: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
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
            ForEach(layouts, id: \.box.id) { item in
                translatedLabel(item)
            }

            statusBadge
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    // MARK: 譯文框排版
    struct BoxLayout { let box: OCRTextBox; let frame: CGRect; let fontSize: CGFloat }

    private var isInPlace: Bool { settings.overlayStyle == OverlayStyle.inPlace.rawValue }

    /// 框剛好蓋住原文；譯文比原文長時往右延伸，但不蓋到同一行右邊的下一段文字
    private var layouts: [BoxLayout] {
        let rects = boxes.map { convertVisionRect($0.normalizedRect, in: windowSize) }
        return boxes.enumerated().map { i, box in
            let r = rects[i]
            let fontSize = min(max(r.height * 0.82, 9), 40)
            let padX: CGFloat = isInPlace ? 3 : 6, padY: CGFloat = isInPlace ? 1.5 : 3
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let needed = (box.translatedText as NSString).size(withAttributes: [.font: font]).width + padX * 2
            // 同一行（垂直重疊）且位於右側的下一個框
            let nextX = rects.enumerated().filter { j, o in
                j != i && o.minX > r.minX + r.width * 0.5 && o.maxY > r.minY + r.height * 0.3 && o.minY < r.maxY - r.height * 0.3
            }.map(\.1.minX).min() ?? windowSize.width
            let maxWidth = max(r.width + padX * 2, min(nextX - r.minX - 4 + padX, windowSize.width - r.minX))
            let width = min(max(needed, r.width + padX * 2), maxWidth)
            let frame = CGRect(x: r.minX - padX, y: r.minY - padY, width: width, height: r.height + padY * 2)
            return BoxLayout(box: box, frame: frame, fontSize: fontSize)
        }
    }

    @ViewBuilder
    private func translatedLabel(_ item: BoxLayout) -> some View {
        let box = item.box
        let bg = isInPlace ? box.background.color : Color(red: 0.09, green: 0.09, blue: 0.13)
        let fg = isInPlace ? box.foreground.color : Color.white
        Text(box.translatedText)
            .font(.system(size: item.fontSize, weight: .medium))
            .foregroundColor(fg)
            .lineLimit(1).minimumScaleFactor(0.45).allowsTightening(true)
            .padding(.horizontal, isInPlace ? 3 : 6)
            .frame(width: item.frame.width, height: item.frame.height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: isInPlace ? 3 : 6, style: .continuous)
                    .fill(bg.opacity(settings.overlayOpacity))
                    .shadow(color: .black.opacity(isInPlace ? 0 : 0.3), radius: 3, y: 1) // 原地取代不加陰影，才不會在淺色背景上出現邊框
            )
            .position(x: item.frame.midX, y: item.frame.midY)
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
            Section("啟動") {
                LaunchAtLoginRow()
            }
            Section("觸發") {
                SettingRow(symbol: "command", color: .gray, title: "全域快捷鍵") {
                    Picker("", selection: $settings.hotkeyPreset) { ForEach(HotkeyPreset.allCases) { p in Text(p.rawValue).tag(p.rawValue) } }.labelsHidden().fixedSize()
                }
                SettingRow(symbol: "character.book.closed", color: .blue, title: "目標語言") {
                    Picker("", selection: $settings.targetLanguage) { ForEach(languages, id: \.self) { l in Text(l).tag(l) } }.labelsHidden().fixedSize()
                }
            }
            Section("顯示") {
                SettingRow(symbol: "paintbrush.pointed", color: .pink, title: "譯文樣式") {
                    Picker("", selection: $settings.overlayStyle) {
                        ForEach(OverlayStyle.allCases) { style in Text(style.rawValue).tag(style.rawValue) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingRow(symbol: "circle.lefthalf.filled", color: .indigo, title: "譯文底色不透明度") {
                    HStack {
                        Slider(value: $settings.overlayOpacity, in: 0.6...1.0, step: 0.05).frame(width: 200)
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
            Section("權限") { PermissionSection() }
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
}

// MARK: - 5.4 開機自動啟動（登入時開啟）
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var needsApproval = SMAppService.mainApp.status == .requiresApproval

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { appLog("登入時啟動設定失敗：\(error.localizedDescription)") }
        refresh()
        if enabled && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled; needsApproval = status == .requiresApproval
        appLog("登入時啟動狀態：\(status.rawValue)")
    }

    // 1.1.4 第一次啟動時預設開啟，之後尊重使用者在偏好設定中的選擇
    func enableByDefaultOnce() {
        let flag = "launchAtLoginDefaulted_v6"
        guard !UserDefaults.standard.bool(forKey: flag) else { refresh(); return }
        UserDefaults.standard.set(true, forKey: flag)
        if SMAppService.mainApp.status != .enabled { set(true) } else { refresh() }
    }
}

// MARK: - 5.5 權限管理
// 每秒檢查一次權限狀態：輔助使用一允許就立即生效；螢幕錄製若仍需重開，提供一鍵重新啟動。
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    @Published var screenNeedsRelaunch = false // 已在系統設定開啟，但此程序仍無法擷取
    var onAccessibilityGranted: (() -> Void)?
    private var timer: Timer?

    var allGranted: Bool { accessibilityGranted && screenGranted }

    func startMonitoring() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax && !accessibilityGranted { appLog("已取得輔助使用權限"); onAccessibilityGranted?() }
        accessibilityGranted = ax
        if !screenGranted {
            // CGPreflight 在授權後常要重開才會變 true，改用 ScreenCaptureKit 實際試一次
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                DispatchQueue.main.async {
                    if content != nil { self.screenGranted = true; self.screenNeedsRelaunch = false; appLog("已取得螢幕錄製權限") }
                    else if self.screenRequested && CGPreflightScreenCaptureAccess() { self.screenNeedsRelaunch = true }
                }
            }
        }
        if allGranted { timer?.invalidate(); timer = nil }
    }

    private var screenRequested: Bool {
        get { UserDefaults.standard.bool(forKey: "screenCaptureRequested_v5") }
        set { UserDefaults.standard.set(newValue, forKey: "screenCaptureRequested_v5") }
    }

    func requestScreen() {
        screenRequested = true
        // 系統對同一個 App 只會跳一次詢問視窗，之後直接帶到系統設定
        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
        startMonitoring()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openPane("Privacy_Accessibility") }
        startMonitoring()
    }

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct LaunchAtLoginRow: View {
    @ObservedObject var login = LaunchAtLogin.shared
    var body: some View {
        SettingRow(symbol: "power", color: .green, title: "登入時自動啟動") {
            HStack(spacing: 8) {
                if login.needsApproval {
                    Button("到系統設定允許") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
                Toggle("", isOn: Binding(get: { login.isEnabled || login.needsApproval }, set: { login.set($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        .onAppear { login.refresh() }
    }
}

struct PermissionRow: View {
    let symbol: String; let color: Color; let title: String; let detail: String
    let granted: Bool; let actionTitle: String; let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("已允許", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

struct PermissionSection: View {
    @ObservedObject var permissions = PermissionManager.shared
    var body: some View {
        PermissionRow(symbol: "rectangle.dashed.badge.record", color: .red, title: "螢幕錄製",
                      detail: permissions.screenNeedsRelaunch ? "已在系統設定開啟，請重新啟動 App 讓權限生效" : "用來擷取目前視窗畫面",
                      granted: permissions.screenGranted,
                      actionTitle: permissions.screenNeedsRelaunch ? "重新啟動 App" : "允許") {
            permissions.screenNeedsRelaunch ? permissions.relaunch() : permissions.requestScreen()
        }
        PermissionRow(symbol: "accessibility", color: .blue, title: "輔助使用",
                      detail: "用來偵測全域快捷鍵（Fn + C），允許後立即生效",
                      granted: permissions.accessibilityGranted, actionTitle: "允許") { permissions.requestAccessibility() }
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject var permissions = PermissionManager.shared
    var onDone: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text("開始使用 ScreenTranslator").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("需要以下兩項權限。每項只要允許一次，之後更新 App 也會保留。")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Form { Section { PermissionSection() } }.formStyle(.grouped).scrollDisabled(true).frame(height: 170)
            Button(permissions.allGranted ? "完成，開始使用" : "稍後再說") { onDone() }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .buttonStyle(.borderedProminent).tint(permissions.allGranted ? .accentColor : .gray)
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 22)
        .frame(width: 500)
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
        LaunchAtLogin.shared.enableByDefaultOnce()
        SettingsManager.shared.migrateKeychainKeysIfNeeded()
        let permissions = PermissionManager.shared
        permissions.onAccessibilityGranted = { [weak self] in self?.installEventTap() }
        permissions.startMonitoring()
        appLog("啟動：輔助使用=\(permissions.accessibilityGranted) 螢幕錄製=\(permissions.screenGranted)")
        // 不再每次啟動都跳系統詢問；缺權限時才顯示引導視窗（等 ScreenCaptureKit 檢查完再判斷）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if !permissions.allGranted { self?.showPermissionWindow() }
        }
    }

    var permissionWindow: NSWindow?
    @objc func showPermissionWindow() {
        if permissionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionOnboardingView { [weak self] in self?.permissionWindow?.close() })
            window.center(); permissionWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); permissionWindow?.makeKeyAndOrderFront(nil)
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
        menu.addItem(menuItem("權限設定…", symbol: "lock.shield", action: #selector(showPermissionWindow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("結束翻譯小工具", symbol: "power", action: #selector(quitApp), key: "q"))
        statusItem.menu = menu
        updateToggleMenuTitle()
    }

    private func updateToggleMenuTitle() {
        toggleMenuItem?.title = "翻譯 / 關閉目前視窗 (\(SettingsManager.shared.hotkeyPreset))"
    }

    private func setupGlobalHotkeyMonitors() {
        installEventTap()
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

    // 需要輔助使用權限；沒權限時先跳過，取得權限後由 PermissionManager 再呼叫一次
    func installEventTap() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
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
            appLog("全域快捷鍵監聽已啟用")
        }
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
                // 固定擷取成標準 8 位元 sRGB，避免 HDR／廣色域的視窗讓 Vision 讀不了
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                if #available(macOS 15.0, *) { config.captureDynamicRange = .SDR }
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
