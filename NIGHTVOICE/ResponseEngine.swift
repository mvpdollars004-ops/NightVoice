import Foundation

struct SpiritReply: Codable {
    let words: String
    let source: String
}

actor ResponseEngine {
    private var rememberedName: String?
    private var recent: [(String, String)] = []
    private let names = ["William", "Mary", "Eleanor", "Thomas", "Rose", "James"]

    func respond(to question: String, endpoint: String) async -> SpiritReply {
        if let url = URL(string: endpoint), ["https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            do {
                var request = URLRequest(url: url.appendingPathComponent("respond"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 7
                let context = recent.suffix(6).map { ["question": $0.0, "answer": $0.1] }
                request.httpBody = try JSONSerialization.data(withJSONObject: ["question": question, "history": context])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let reply = try JSONDecoder().decode(SpiritReply.self, from: data)
                let sanitized = Self.clean(reply.words)
                guard !sanitized.isEmpty else { throw URLError(.cannotParseResponse) }
                remember(question, sanitized)
                return SpiritReply(words: sanitized, source: "online")
            } catch { /* Offline fallback */ }
        }
        let answer = offline(question)
        remember(question, answer)
        return SpiritReply(words: answer, source: "offline")
    }

    private func remember(_ q: String, _ a: String) {
        recent.append((q, a))
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }
    }

    private func offline(_ question: String) -> String {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.contains("your name") || q.contains("who are you") {
            if rememberedName == nil { rememberedName = names.randomElement() ?? "William" }
            return rememberedName!
        }
        if let name = rememberedName, q.contains(name.lowercased()) {
            if q.contains("still here") || q.contains("are you here") { return "Yes" }
        }
        if q.contains("how did you die") || q.contains("cause of death") { return "Unknown" }
        if q.contains("where are you") { return "Nearby" }
        if q.contains("how many") { return "One" }
        if q.contains("are you alone") { return "Not alone" }
        if q.contains("what year") || q.hasPrefix("when ") { return "Uncertain" }
        if q.hasPrefix("why ") { return "Don't know" }
        if ["are ", "can ", "do ", "did ", "is ", "have ", "was ", "were ", "will "].contains(where: q.hasPrefix) { return "Yes" }
        if ["what ", "who ", "where ", "how "].contains(where: q.hasPrefix) { return "Not sure" }
        return "Listening"
    }

    static func clean(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "[^\\p{L}\\p{N}' -]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).prefix(2)
        return words.joined(separator: " ").prefix(40).description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
