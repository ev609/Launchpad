import AppKit
import CryptoKit

/// Кэш иконок приложений (иконки тяжёлые — держим их в памяти).
/// Используется только из главного потока (SwiftUI).
///
/// ⚠️ Кэш инвалидируется по дате изменения бандла. Без этого сменившаяся иконка
/// приложения не появлялась НИКОГДА в пределах запуска: путь тот же → отдавалась
/// старая картинка из памяти, и помогал только перезапуск Launchpad. Ровно так и
/// вышло 12.07.2026 — иконки ярлыков поменяли, а Launchpad показывал прежние.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private final class Entry: NSObject {
        let image: NSImage
        let modified: Date?

        init(image: NSImage, modified: Date?) {
            self.image = image
            self.modified = modified
        }
    }

    /// NSImage создаётся целиком в одной фоновой операции и передаётся на main
    /// только после завершения рисования; после этого он больше не мутируется.
    private struct LoadedIcon: @unchecked Sendable {
        let image: NSImage
        let modified: Date?
    }

    /// Иконки легко восстановить с диска, поэтому не держим их бессрочно.
    /// До трёх страниц сетки 10×8 одновременно участвуют в переходе. Держим их
    /// целиком, иначе NSCache начинает вытеснять текущую страницу прямо во время
    /// свайпа и повторно растеризует те же изображения.
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.name = "Launchpad application icons"
        cache.countLimit = 280
        cache.totalCostLimit = 72 * 1024 * 1024
        return cache
    }()
    private var pendingLoads: [String: [(NSImage) -> Void]] = [:]
    private var residentPaths = Set<String>()
    private let loadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Launchpad icon loader"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private var acceptsPrefetch = false

    private let logicalSize = NSSize(width: 128, height: 128)
    private let pixelSize = 256
    private let diskCacheDirectory: URL

    private init() {
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"],
           !custom.isEmpty {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Launchpad", isDirectory: true)
        }
        diskCacheDirectory = base.appendingPathComponent("IconCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Дата изменения бандла. У .app при смене иконки обновляется mtime самого
    /// каталога (кастомная иконка пишется в атрибуты файла), поэтому этого хватает.
    nonisolated private static func modifiedAt(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        // Кэш полностью очищается при закрытии сетки, поэтому stat каждого
        // бандла на каждом SwiftUI-render не нужен. На плотной сетке это были
        // сотни синхронных файловых операций в начале анимации.
        if let hit = cache.object(forKey: key) { return hit.image }
        let loaded = Self.loadIcon(path: path, diskDirectory: diskCacheDirectory)
        let modified = loaded.modified
        let image = loaded.image
        image.size = logicalSize
        let cost = pixelSize * pixelSize * 4
        cache.setObject(Entry(image: image, modified: modified), forKey: key, cost: cost)
        residentPaths.insert(path)
        return image
    }

    /// Немедленно отдаёт кэшированную иконку либо загружает её вне главного
    /// потока. Одновременные запросы одного пути объединяются.
    func requestIcon(for path: String, completion: @escaping (NSImage) -> Void) {
        let key = path as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit.image)
            return
        }
        if pendingLoads[path] != nil {
            pendingLoads[path]?.append(completion)
            return
        }
        pendingLoads[path] = [completion]
        let diskDirectory = diskCacheDirectory
        loadQueue.addOperation {
            let loaded = autoreleasepool {
                Self.loadIcon(path: path, diskDirectory: diskDirectory)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let image = loaded.image
                image.size = self.logicalSize
                let cost = self.pixelSize * self.pixelSize * 4
                self.cache.setObject(Entry(image: image, modified: loaded.modified),
                                     forKey: path as NSString, cost: cost)
                self.residentPaths.insert(path)
                let completions = self.pendingLoads.removeValue(forKey: path) ?? []
                completions.forEach { $0(image) }
            }
        }
    }

    /// `NSImage.size` меняет размер в points, но не гарантирует уменьшение исходных
    /// bitmap-representations. Рисуем ровно одну Retina-representation 256×256,
    /// чтобы SwiftUI/Core Animation не создавали текстуры из 512–1024 px иконок.
    nonisolated private static func rasterized(_ source: NSImage) -> NSImage? {
        let pixelSize = 256
        let logicalSize = NSSize(width: 128, height: 128)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        // NSBitmapImageRep рисует в пикселях своего backing store. Если сразу
        // назначить ему logicalSize (128 pt) и рисовать в 128×128, содержимое
        // займёт только половину bitmap 256×256 и на экране иконка будет вдвое
        // меньше. Сначала заполняем весь pixel canvas, затем объявляем его
        // Retina-representation размером 128 pt.
        let pixelRect = NSRect(x: 0, y: 0,
                               width: CGFloat(pixelSize),
                               height: CGFloat(pixelSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: pixelRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = logicalSize

        let image = NSImage(size: logicalSize)
        image.addRepresentation(bitmap)
        return image
    }

    nonisolated private static func loadIcon(path: String,
                                             diskDirectory: URL) -> LoadedIcon {
        let modified = modifiedAt(path)
        let cacheURL = diskURL(for: path, modified: modified,
                               directory: diskDirectory)
        if let data = try? Data(contentsOf: cacheURL),
           let image = NSImage(data: data) {
            image.size = NSSize(width: 128, height: 128)
            return LoadedIcon(image: image, modified: modified)
        }

        let source = NSWorkspace.shared.icon(forFile: path)
        let image = rasterized(source) ?? source
        image.size = NSSize(width: 128, height: 128)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: cacheURL, options: .atomic)
        }
        return LoadedIcon(image: image, modified: modified)
    }

    nonisolated private static func diskURL(for path: String, modified: Date?,
                                            directory: URL) -> URL {
        let stamp = modified?.timeIntervalSince1970 ?? 0
        let input = Data("\(path)|\(stamp)|256".utf8)
        let name = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    /// Ограничивает рост постоянного кэша. Очистка идёт в utility-очереди и не
    /// участвует во времени открытия сетки.
    private func pruneDiskCacheIfNeeded() {
        let directory = diskCacheDirectory
        loadQueue.addOperation {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]), files.count > 600 else { return }
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
            for url in sorted.dropFirst(500) { try? fm.removeItem(at: url) }
        }
    }

    func removeAll() {
        acceptsPrefetch = false
        loadQueue.cancelAllOperations()
        pendingLoads.removeAll()
        cache.removeAllObjects()
        residentPaths.removeAll()
    }

    struct DiagnosticSnapshot {
        let residentCount: Int
        let estimatedResidentBytes: Int
        let diskCount: Int
        let diskBytes: Int
    }

    func diagnosticSnapshot() -> DiagnosticSnapshot {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        let bytes = files.reduce(into: 0) { total, url in
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let estimatedResidentCount = min(residentPaths.count, 280)
        return DiagnosticSnapshot(
            residentCount: estimatedResidentCount,
            estimatedResidentBytes: estimatedResidentCount * pixelSize * pixelSize * 4,
            diskCount: files.count,
            diskBytes: bytes)
    }

    func prepareForDisplay() {
        acceptsPrefetch = true
        pruneDiskCacheIfNeeded()
    }

    /// Загружает соседние страницы через ту же ограниченную фоновую очередь.
    /// Здесь принципиально нет синхронного `icon(for:)`: даже маленькая пачка
    /// могла попасть ровно в 180-мс анимацию и пропустить кадр.
    func prefetch(paths: [String]) {
        guard acceptsPrefetch else { return }
        let uniquePaths = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }
        for path in uniquePaths {
            requestIcon(for: path) { _ in }
        }
    }
}

/// Запуск приложений.
enum AppLauncher {
    static func launch(_ app: AppEntry, completion: ((Error?) -> Void)? = nil) {
        let url = URL(fileURLWithPath: app.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NotificationCenter.default.post(name: .launchpadLaunchFailed,
                        object: "Не удалось открыть «\(app.name)»: \(error.localizedDescription)")
                    // Команду запуска уже приняли и скрыли launcher. При редкой
                    // асинхронной ошибке возвращаем его вместе с объяснением.
                    NotificationCenter.default.post(name: .launchpadShouldShow, object: nil)
                }
                completion?(error)
            }
        }
        // Launch Services сообщает результат асинхронно. Launcher не должен
        // оставаться поверх запускаемого приложения в ожидании completion:
        // скрываем его сразу после того, как запрос принят системой.
        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
    }
}

/// Сохранение и загрузка раскладки в Application Support.
final class LayoutStore: @unchecked Sendable {
    static let shared = LayoutStore()
    let fileURL: URL
    let journalURL: URL
    private var lastBackupTimestamp = 0
    private let saveQueue = DispatchQueue(label: "Launchpad layout writer", qos: .utility)
    private var pendingLayout: Layout?
    private var pendingSave: DispatchWorkItem?
    private let saveDebounce: TimeInterval

    init(baseURL: URL? = nil, saveDebounce: TimeInterval = 0.15) {
        self.saveDebounce = saveDebounce
        // Изоляция для тестов: если задан LAUNCHPAD_SUPPORT_DIR — храним там,
        // чтобы тестовые прогоны не трогали реальную раскладку пользователя.
        let base: URL
        if let baseURL {
            base = baseURL
        } else if let custom = ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"], !custom.isEmpty {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Launchpad", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            NSLog("LayoutStore: не удалось создать каталог — \(error.localizedDescription)")
        }
        fileURL = base.appendingPathComponent("layout.json")
        journalURL = base.appendingPathComponent("layout.json.pending")
    }

    func load() -> Layout? {
        flush()
        recoverJournalIfNeeded()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let layout = try? JSONDecoder().decode(Layout.self, from: data) {
            return layout
        }
        // Файл есть, но не декодируется — сохраняем копию, чтобы не потерять молча.
        do {
            try data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
        } catch {
            NSLog("LayoutStore: не удалось сохранить повреждённую раскладку — \(error.localizedDescription)")
        }
        return nil
    }

    func save(_ layout: Layout) {
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLayout = layout
            self.pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writePendingLayout() }
            self.pendingSave = work
            self.saveQueue.asyncAfter(deadline: .now() + self.saveDebounce, execute: work)
        }
    }

    /// Гарантирует запись последнего состояния перед чтением или завершением
    /// приложения. Обычные частые изменения объединяются фоновым debounce.
    func flush() {
        saveQueue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            writePendingLayout()
        }
    }

    private func writePendingLayout() {
        guard let layout = pendingLayout else { return }
        pendingLayout = nil
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(layout)
            // Журнал всегда появляется первым. Если процесс завершится между
            // двумя записями, следующий запуск восстановит именно новую версию.
            try data.write(to: journalURL, options: .atomic)
            _ = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: journalURL))
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.removeItem(at: journalURL)
        } catch {
            NSLog("LayoutStore: не удалось сохранить раскладку — \(error.localizedDescription)")
            reportSaveFailure(error)
        }
    }

    /// Восстанавливает подтверждённый журнал после сбоя между записью journal
    /// и основного файла. Повреждённый journal сохраняется для диагностики.
    private func recoverJournalIfNeeded() {
        guard let data = try? Data(contentsOf: journalURL) else { return }
        guard (try? JSONDecoder().decode(Layout.self, from: data)) != nil else {
            let corruptURL = journalURL.appendingPathExtension("corrupt")
            do {
                try data.write(to: corruptURL, options: .atomic)
                try FileManager.default.removeItem(at: journalURL)
            } catch {
                NSLog("LayoutStore: не удалось сохранить повреждённый журнал — \(error.localizedDescription)")
            }
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            // Валидный journal оставляем на месте: следующая загрузка повторит
            // восстановление, когда причина ошибки (например, место на диске)
            // будет устранена.
            NSLog("LayoutStore: не удалось восстановить журнал — \(error.localizedDescription)")
            reportSaveFailure(error)
        }
    }

    private func reportSaveFailure(_ error: Error) {
        let message = "Не удалось сохранить раскладку: \(error.localizedDescription)"
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .launchpadLayoutSaveFailed,
                                            object: message)
        }
    }

    /// Отдельные снимки перед импортом и сбросом; старые копии не перезаписываются.
    func backup(_ layout: Layout) throws {
        flush()
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lastBackupTimestamp = max(Int(Date().timeIntervalSince1970 * 1000), lastBackupTimestamp + 1)
        let name = "layout-\(lastBackupTimestamp)-\(UUID().uuidString).json"
        try JSONEncoder().encode(layout).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func latestBackup() throws -> Layout? {
        flush()
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let latest = files.first else { return nil }
        return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: latest))
    }

    func reset() {
        flush()
        do {
            for url in [fileURL, journalURL] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("LayoutStore: не удалось сбросить раскладку — \(error.localizedDescription)")
        }
    }
}
