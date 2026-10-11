import Foundation

enum SharePayload {
    static func body(from values: [String]) -> String {
        var parts: [String] = []
        for value in values {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !parts.contains(value) { parts.append(value) }
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return parts.filter { part in
            guard let url = URL(string: part), ["https", "http"].contains(url.scheme),
                  url.absoluteString == part else { return true }
            return !parts.contains { other in
                guard other != part else { return false }
                return detector?.matches(in: other, range: NSRange(other.startIndex..., in: other))
                    .contains(where: { $0.url == url }) == true
            }
        }.joined(separator: "\n\n")
    }
}
