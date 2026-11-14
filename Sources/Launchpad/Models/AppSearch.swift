import Foundation

enum AppSearch {
    static func results(for query: String, in apps: [AppEntry]) -> [AppEntry] {
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let alternate = switchKeyboardLayout(query)
        return apps.compactMap { app -> (AppEntry, Int)? in
            let name = fold(app.name)
            let score = min(rank(query, in: name), rank(alternate, in: name) + 10)
            return score < 1000 ? (app, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let order = $0.0.name.localizedCaseInsensitiveCompare($1.0.name)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }.map { $0.0 }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func rank(_ query: String, in name: String) -> Int {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 20 }
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let tokens = query.split(whereSeparator: \.isWhitespace)
        if tokens.count > 1, tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { return 30 }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(query) { return 40 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 50 }
        if name.contains(query) { return 60 }
        // Упорядоченная подпоследовательность: "vsc" → Visual Studio Code.
        guard query.count >= 2 else { return 1000 }
        var cursor = name.startIndex
        for character in query {
            guard let match = name[cursor...].firstIndex(of: character) else { return 1000 }
            cursor = name.index(after: match)
        }
        return 100 + min(name.count - query.count, 100)
    }

    private static func switchKeyboardLayout(_ text: String) -> String {
        let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
        let russian = Array("йцукенгшщзхъфывапролджэячсмитьбю")
        let toRussian = Dictionary(uniqueKeysWithValues: zip(latin, russian))
        let toLatin = Dictionary(uniqueKeysWithValues: zip(russian, latin))
        let mapping = text.contains(where: { toLatin[$0] != nil }) ? toLatin : toRussian
        return String(text.map { mapping[$0] ?? $0 })
    }
}
