import Foundation

/// One of DiPo's opening notes in Ask DiPo: its headline and the line under
/// it. They come in as one message, the headline on the first line.
enum DiPoChatNote {
    static func split(_ text: String) -> (title: String, body: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.firstIndex(of: "\n") else { return (trimmed, nil) }
        let title = trimmed[..<cut].trimmingCharacters(in: .whitespaces)
        let body = trimmed[trimmed.index(after: cut)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body.isEmpty ? nil : body)
    }
}
