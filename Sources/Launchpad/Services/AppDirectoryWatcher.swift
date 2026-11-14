import Foundation
import CoreServices

/// Слушает реальные изменения каталогов приложений вместо периодического
/// полного обхода файловой системы. События объединяются: установка одного .app
/// обычно создаёт десятки и сотни низкоуровневых уведомлений.
@MainActor
final class AppDirectoryWatcher {
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var activeRoots: [String] = []

    init(paths: [String], latency: TimeInterval = 0.6,
         onChange: @escaping () -> Void) {
        self.paths = Self.minimalRoots(paths)
        self.latency = latency
        self.onChange = onChange
    }

    /// Удаляет дубликаты и вложенные пути: наблюдение `/Applications` уже
    /// включает `/Applications/Utilities` при флаге `.fileEvents`.
    nonisolated static func minimalRoots(_ paths: [String]) -> [String] {
        let standardized = Array(Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })).sorted { $0.count < $1.count }
        var roots: [String] = []
        for path in standardized where !roots.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) {
            roots.append(path)
        }
        return roots.sorted()
    }

    /// FSEvents не умеет наблюдать ещё не существующий каталог. В таком случае
    /// следим за ближайшим существующим родителем и автоматически перестраиваем
    /// stream, когда нужный каталог появится.
    nonisolated static func watchRoots(
        for paths: [String],
        directoryExists: (String) -> Bool = {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    ) -> [String] {
        minimalRoots(paths.compactMap { original in
            var candidate = URL(fileURLWithPath: original).standardizedFileURL
            while !directoryExists(candidate.path) {
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { return nil }
                candidate = parent
            }
            return candidate.path
        })
    }

    nonisolated static func requiresStreamRestart(_ flags: FSEventStreamEventFlags) -> Bool {
        let restartFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged)
        return flags & restartFlags != 0
    }

    func start() {
        guard stream == nil else { return }
        let roots = Self.watchRoots(for: paths)
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppDirectoryWatcher>
                .fromOpaque(info).takeUnretainedValue()
            var restart = false
            for index in 0..<count where AppDirectoryWatcher.requiresStreamRestart(flags[index]) {
                restart = true
                break
            }
            Task { @MainActor in watcher.receivedEvents(requiresRestart: restart) }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer)) else { return }

        self.stream = stream
        activeRoots = roots
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            activeRoots = []
        }
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        activeRoots = []
    }

    private func receivedEvents(requiresRestart: Bool) {
        let rootsChanged = Self.watchRoots(for: paths) != activeRoots
        if requiresRestart || rootsChanged {
            stop()
            start()
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + latency, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
