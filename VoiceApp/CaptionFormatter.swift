import Foundation

// Zipformer emits uppercase tokens. Format the display without changing words.
// Proper names cannot reliably be recovered from case-free model output.
enum CaptionFormatter {
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var beginsSentence = true
        for character in text.lowercased() {
            if character.isLetter {
                result += beginsSentence ? String(character).uppercased() : String(character)
                beginsSentence = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { beginsSentence = true }
            }
        }
        result = result.replacingOccurrences(of: "\\bi(?=\\b|['’])", with: "I", options: .regularExpression)
        for (word, spelling) in [("ios", "iOS"), ("iphone", "iPhone"), ("usb", "USB"), ("api", "API"), ("ai", "AI"), ("ok", "OK")] {
            result = result.replacingOccurrences(of: "\\b\(word)\\b", with: spelling, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}
