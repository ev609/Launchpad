import Foundation

/// Перевод строки интерфейса. Ключ — русский текст из исходников; перевод на
/// английский лежит в Resources/en.lproj/Localizable.strings. Без перевода
/// (русская система, тесты) возвращается сам ключ.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Перевод строки-шаблона с подстановкой (`%@`) — для текста с переменными частями.
func L(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: L(format), arguments: arguments)
}
