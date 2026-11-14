# Launchpad — заметки для агентов

Менюбар-агент на Swift/SwiftUI+AppKit, SwiftPM, macOS 13+. Описание — `README.md`.

## Сборка и проверка

- `swift build -Xswiftc -warnings-as-errors` — как в CI (`.github/workflows/ci.yml`).
- `./scripts/build_app.sh release` — универсальный `.app` (arm64+x86_64) в `build/`.
  Для быстрой локальной сборки: `ARCHS=arm64 ./scripts/build_app.sh release`.
- `swift test` требует Xcode: на машине только с Command Line Tools XCTest нет.
  Без Xcode тесты можно лишь типизировать против заглушки XCTest
  (`swiftc -typecheck -I <stub> -I .build/debug Tests/LaunchpadTests/*.swift`).
- `xcrun: error: unable to lookup item 'PlatformPath'` при сборке под CLT — безвредно.

## Инварианты, которые легко сломать

- **Автообновление ставит код всем пользователям без подтверждения.** Любая правка
  `Services/Updater.swift` и скрипта установки в нём — только с проверкой подписи
  Ed25519 до распаковки, `codesign --verify` и откатом на прежнюю версию.
  Публичные ключи — список в Info.plist (ротация); приватный ключ лежит вне
  репозитория (`~/Library/Application Support/Launchpad/update-signing-key.pem`)
  и не читается и не выводится агентами.
- **Автозапуск:** login item и LaunchAgent взаимоисключающие — менять только через
  `StartupManager`. `launchctl bootout` убивает процесс задания: из процесса,
  запущенного агентом (`KeepAliveService.isManagedProcess`), выгружать нельзя.
  Передача управления между экземплярами — `AppDelegate` (handover).
- **Место установки** (`InstallLocation`): из DMG, translocation и read-only томов
  не включать автозапуск и не ставить обновления.
- **Раскладка** пишется через журнал `LayoutStore` (`Services/Services.swift`); формат `layout.json` — обратно
  совместим (новые поля только опциональные).
- `MultitouchManager` использует приватный фреймворк MultitouchSupport: только
  `dlopen`, без линковки.

## Локализация

Ключ перевода — русский текст в коде; английский — `Resources/en.lproj/Localizable.strings`.
Литералы SwiftUI (`Text("…")`, `Button("…")`…) переводятся сами; строки, уходящие в UI
как `String` (AppKit, ошибки, интерполяция), — через `L("…")` / `L("… %@", x)`.
Каждый новый текст интерфейса — сразу с ключом в en.lproj. Логи и диагностика не переводятся.
В тестах таблиц нет, `L()` возвращает русский ключ — тесты сравнивают русский текст.

## Стиль

Комментарии, сообщения коммитов и исходные тексты интерфейса — на русском.
Коммиты: `тип(область): описание`.
