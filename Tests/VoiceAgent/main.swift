import Foundation

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    checks += 1
    guard (try? condition()) == true else { fatalError(message) }
}

// Sentence splitting: one request per sentence, tiny fragments merged into the previous one.
check(SpeechText.sentences("設定アプリを開きました。Wi-Fi の画面です！ほかに何かしますか？")
      == ["設定アプリを開きました。", "Wi-Fi の画面です！", "ほかに何かしますか？"], "split on sentence ends")
check(SpeechText.sentences("了解です。送信しますか？ OK") == ["了解です。", "送信しますか？OK"], "short tail merged")
check(SpeechText.sentences("  \n ") == [], "blank text")

// Readings: English words become kana for the on-device voice; longer keys win, word edges only.
let readings = ["App Store": "アップストア", "Apple": "アップル", "Safari": "サファリ", "LINE": "ライン"]
check(SpeechText.applyReadings("Safariで検索します。", readings) == "サファリで検索します。", "replace word")
check(SpeechText.applyReadings("App Storeを開きます", readings) == "アップストアを開きます", "longer key first")
check(SpeechText.applyReadings("line で送ります", readings) == "ライン で送ります", "case-insensitive")
check(SpeechText.applyReadings("Pineapple と Safaris", readings) == "Pineapple と Safaris", "inside a word is kept")
let bundled = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
check(SpeechText.applyReadings("Bluetoothをオンにして、YouTubeを開きます。", bundled) == "ブルートゥースをオンにして、ユーチューブを開きます。", "bundled dictionary")

// PCM: 16-bit little-endian, odd-length chunks carried over without shifting samples.
var decoder = PCMDecoder()
let samples: [Int16] = [0, 16384, -16384, 32767, -32768]
var bytes = Data()
for value in samples { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
let first = decoder.samples(bytes.prefix(3))
let rest = decoder.samples(bytes.dropFirst(3))
let decoded = first + rest
check(decoded.count == samples.count, "odd split keeps every sample")
check(decoded == samples.map { Float($0) / 32768 }, "odd split keeps sample values")

// Upsampling 24 kHz to 48 kHz: midpoints between samples, continuous across chunk edges.
var upsampler = Upsampler2x()
let up = upsampler.process([0, 1]) + upsampler.process([0.5])
check(up == [0, 0, 0.5, 1, 0.75, 0.5], "upsample with midpoints across chunks")

// SSE: audio deltas, a JSON split over two data lines, other events ignored, error events thrown.
var parser = SSEAudioParser()
let audio = Data([1, 2, 3, 4]).base64EncodedString()
check(try parser.feed("event: step.delta") == [], "event line")
check(try parser.feed("data: {\"event_type\":\"step.delta\",\"delta\":{\"type\":\"audio\",") == [], "partial json waits")
check(try parser.feed("data: \"data\":\"\(audio)\"}}") == [Data([1, 2, 3, 4])], "json over two data lines")
check(try parser.feed("data:{\"event_type\":\"step.delta\",\"delta\":{\"type\":\"text\",\"text\":\"x\"}}") == [], "non-audio delta")
check(try parser.feed("data: {\"event_type\":\"interaction.status_update\",\"status\":\"in_progress\"}") == [], "status update")
check(parser.receivedAudio, "audio seen")
var failed = false
do { _ = try parser.feed("data: {\"error\":{\"message\":\"quota\"}}") } catch { failed = true }
check(failed, "error event throws")
failed = false
var fresh = SSEAudioParser()
do { _ = try fresh.feed("data: {\"event_type\":\"interaction.status_update\",\"status\":\"failed\"}") } catch { failed = true }
check(failed, "failed status throws")

// Confirmation answers: any negation rejects, only short affirmations approve.
for (text, expected) in [("はい", true), ("はい、お願いします", true), ("OK", true), ("実行しないで", false),
                         ("お願いだから送らないで", false), ("ちょっと待って", false), ("いいえ", false)] as [(String, Bool?)] {
    check(ConfirmationAnswer.interpret(text) == expected, "answer \(text)")
}
check(ConfirmationAnswer.interpret("今日は天気がいいので公園に行きたいと思います") == nil, "long answer asks again")

// Risky labels: whole English words, Japanese substrings.
for label in ["送信", "Send", "Pay", "Save", "Sign Out", "アカウントを削除", "写真を保存"] {
    check(RiskGuard.isRiskyLabel(label), "risky \(label)")
}
for label in ["Posts", "Orders", "Display", "Wi-Fi", "Settings"] {
    check(!RiskGuard.isRiskyLabel(label), "not risky \(label)")
}

// Approval modes: the middle mode asks only for payments and deletions.
check(ApprovalMode.ask.needsUser("メッセージを送信します"), "ask always asks")
check(!ApprovalMode.automatic.needsUser("商品を購入します"), "automatic never asks")
check(ApprovalMode.askForPaymentsAndDeletes.needsUser("Amazon で商品を購入します"), "purchase asks")
check(ApprovalMode.askForPaymentsAndDeletes.needsUser("写真を削除します"), "delete asks")
check(!ApprovalMode.askForPaymentsAndDeletes.needsUser("母に LINE でメッセージを送信します"), "send is automatic")
check(AgentMemory.promptSection("").contains("(empty)"), "empty memory section")

print("VoiceAgent: \(checks) checks passed")
