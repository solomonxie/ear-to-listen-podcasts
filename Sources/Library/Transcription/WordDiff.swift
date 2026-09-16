import Foundation

/// Word-level diff between what a recognizer produced and what the user typed instead —
/// what "see my edits" renders. Word-level rather than character-level because a
/// transcript correction is nearly always a wrong word or name, not a typo.
enum WordDiff {
    enum Kind: Sendable { case same, removed, added }

    struct Token: Hashable, Identifiable, Sendable {
        let text: String
        let kind: Kind
        let id = UUID()

        static func == (lhs: Token, rhs: Token) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static func tokens(from original: String, to edited: String) -> [Token] {
        let before = original.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let after = edited.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var lengths = Array(repeating: Array(repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = before[i] == after[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var tokens: [Token] = []
        var i = 0, j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                tokens.append(Token(text: before[i], kind: .same)); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                tokens.append(Token(text: before[i], kind: .removed)); i += 1
            } else {
                tokens.append(Token(text: after[j], kind: .added)); j += 1
            }
        }
        tokens += before[i...].map { Token(text: $0, kind: .removed) }
        tokens += after[j...].map { Token(text: $0, kind: .added) }
        return tokens
    }
}
