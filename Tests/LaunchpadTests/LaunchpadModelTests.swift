import XCTest
@testable import Launchpad

final class LaunchpadModelTests: XCTestCase {
    private var directory: URL!
    private var store: LayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchpadModelTests-\(UUID().uuidString)", isDirectory: true)
        store = LayoutStore(baseURL: directory)
    }

    override func tearDownWithError() throws {
        store.flush()
        try FileManager.default.removeItem(at: directory)
    }

    private func app(_ id: String) -> AppEntry {
        AppEntry(name: id, path: "/Applications/\(id).app", bundleID: id)
    }

    private func isolatedSettings() -> (AppSettings, String) {
        let suite = "LaunchpadModelTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), suite)
    }

    func testHideAndRestoreApplication() async {
        let a = app("hidden"), b = app("visible")
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings,
                                       scanApps: { [a, b] })
            model.load()
            model.hideApp(a)

            XCTAssertEqual(model.hiddenApps, [a])
            XCTAssertFalse(model.pages.flatMap(\.items).flatMap(\.containedApps).contains(a))
            XCTAssertTrue(settings.hiddenAppIDs.contains(a.id))

            model.unhideApp(a)

            XCTAssertTrue(model.hiddenApps.isEmpty)
            XCTAssertTrue(model.pages.flatMap(\.items).flatMap(\.containedApps).contains(a))
            XCTAssertFalse(settings.hiddenAppIDs.contains(a.id))
        }
    }

    func testPortableLayoutExportAndImport() async throws {
        let a = app("a"), b = app("b")
        let exportURL = directory.appendingPathComponent("export.json")
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        try await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings,
                                       scanApps: { [a, b] })
            model.load()
            model.pages = [Page(id: "portable", items: [.app(b), .app(a)])]
            try model.exportLayout(to: exportURL)
            model.pages = [Page(items: [.app(a), .app(b)])]

            XCTAssertTrue(model.importLayout(from: exportURL))
            XCTAssertEqual(model.pages.first?.id, "portable")
            XCTAssertEqual(model.pages.first?.items.flatMap(\.containedApps), [b, a])
        }
    }

    func testReloadRemovesDuplicatesAndMissingAppsWhilePreservingOrder() async throws {
        let a = app("a"), b = app("b"), c = app("c"), new = app("new")
        var freshA = a
        freshA.path = "/Applications/Moved.app"
        let installed = [freshA, b, c, new]
        store.save(Layout(pages: [Page(id: "original", items: [
            .app(a),
            .folder(Folder(id: "tools", name: "Tools", apps: [a, b, b, c, app("removed")])),
            .app(c),
        ])]))

        try await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { installed })
            model.load()

            XCTAssertEqual(model.pages.flatMap(\.items).flatMap(\.containedApps), installed)
            XCTAssertEqual(model.pages.first?.id, "original")
            XCTAssertEqual(model.folder(withID: "tools")?.apps, [b, c])
            XCTAssertEqual(try XCTUnwrap(store.load()).pages, model.pages)
        }
    }

    func testMoveRejectsInvalidPagesAndMovingBeforeItself() async {
        let items: [LaunchpadItem] = [.app(app("a")), .app(app("b"))]
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            let pages = [Page(id: "page", items: items)]
            model.pages = pages

            model.move(items[0].id, before: nil, onPage: -1)
            model.move(items[0].id, before: nil, onPage: pages.count)
            model.move(items[0].id, before: items[0].id, onPage: 0)

            XCTAssertEqual(model.pages, pages)
        }
    }

    func testRemovingLastFolderClampsPageAndClosesOverlay() async {
        let a = app("a"), b = app("b")
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: [.app(a)]), Page(items: [
                .folder(Folder(id: "folder", name: "Tools", apps: [b])),
            ])]
            model.currentPage = 1
            model.openFolderID = "folder"

            model.removeFromFolder(b.id, folderID: "folder")

            XCTAssertEqual(model.pages.count, 1)
            XCTAssertEqual(model.currentPage, 0)
            XCTAssertNil(model.openFolderID)
        }
    }

    func testReloadClosesFolderThatNoLongerExists() async {
        let a = app("a")
        store.save(Layout(pages: [Page(items: [
            .folder(Folder(id: "folder", name: "Tools", apps: [a, app("removed")])),
        ])]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [a] })
            model.openFolderID = "folder"
            model.load()

            XCTAssertNil(model.openFolderID)
            XCTAssertEqual(model.pages.flatMap(\.items), [.app(a)])
        }
    }

    func testFolderNameRejectsWhitespaceAndTrimsValidName() async {
        let apps = [app("a"), app("b")]
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: [.folder(Folder(id: "folder", name: "Tools", apps: apps))])]

            model.renameFolder("folder", to: " \n ")
            XCTAssertEqual(model.folder(withID: "folder")?.name, "Tools")
            model.renameFolder("folder", to: "  Work\n")
            XCTAssertEqual(model.folder(withID: "folder")?.name, "Work")
        }
    }
    func testUndoRedoFolderOperationsAndBranching() async throws {
        let apps = [app("a"), app("b"), app("c")]
        store.save(Layout(pages: [Page(id: "page", items: apps.map { .app($0) })]))
        try await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            let original = model.pages
            XCTAssertTrue(model.combine("app:a", into: "app:b"))
            let combined = model.pages
            let folder = try XCTUnwrap(model.pages[0].items.first)
            guard case .folder(let value) = folder else { return XCTFail("Expected folder") }
            model.renameFolder(value.id, to: "Work")
            model.undoLayoutChange()
            XCTAssertEqual(model.pages, combined)
            model.undoLayoutChange()
            XCTAssertEqual(model.pages, original)
            XCTAssertFalse(model.canUndo)
            model.redoLayoutChange()
            XCTAssertEqual(model.pages, combined)
            model.extractApp("a", fromFolder: value.id)
            XCTAssertFalse(model.canRedo)
            model.undoLayoutChange()
            XCTAssertEqual(model.pages, combined)
            XCTAssertEqual(try XCTUnwrap(store.load()).pages, combined)
        }
    }

    func testResetHasPersistentBackupAndCanBeUndone() async throws {
        let apps = [app("a"), app("b")]
        let original = [Page(id: "page", items: apps.reversed().map { .app($0) })]
        store.save(Layout(pages: original))
        try await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            model.resetLayout()
            XCTAssertEqual(try XCTUnwrap(store.latestBackup()).pages, original)
            model.undoLayoutChange()
            XCTAssertEqual(model.pages, original)
            model.redoLayoutChange()
            XCTAssertEqual(model.pages.flatMap(\.items).flatMap(\.containedApps), apps)
            let reopened = LaunchpadModel(layoutStore: store, scanApps: { apps })
            reopened.load()
            XCTAssertTrue(reopened.restoreLatestBackup())
            XCTAssertEqual(reopened.pages, original)
        }
    }

    func testSearchSelectionResetsAndClamps() async {
        let apps = [app("app1"), app("app2"), app("app3")]
        store.save(Layout(pages: [Page(items: apps.map { .app($0) })]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            model.searchText = "app"
            model.selectSearchResult(offset: 1)
            XCTAssertEqual(model.selectedSearchApp?.id, "app2")
            model.selectSearchResult(offset: 100)
            XCTAssertEqual(model.selectedSearchApp?.id, "app3")
            model.selectSearchResult(offset: -100)
            XCTAssertEqual(model.selectedSearchApp?.id, "app1")
            model.searchText = "app2"
            XCTAssertEqual(model.selectedSearchApp?.id, "app2")
            model.searchText = "no-match"
            XCTAssertNil(model.selectedSearchApp)
        }
    }

    func testBackgroundRefreshDefersDuringDragAndPreservesLiveEdits() async {
        let a = app("a"), b = app("b"), c = app("c")
        store.save(Layout(pages: [Page(id: "page", items: [.app(a), .app(b)])]))
        let model = await MainActor.run {
            let model = LaunchpadModel(layoutStore: store)
            model.loadCachedLayout()
            model.layoutInteractionActive = true
            return model
        }
        await model.refreshApps {
            XCTAssertFalse(Thread.isMainThread)
            return AppScanner.ScanResult(apps: [a, b, c])
        }
        await MainActor.run {
            XCTAssertEqual(model.allApps.count, 2)
            model.move("app:b", before: "app:a", onPage: 0)
            model.layoutInteractionActive = false
            XCTAssertEqual(model.pages.flatMap(\.items).flatMap(\.containedApps).map(\.id), ["b", "a", "c"])
            XCTAssertFalse(model.isScanning)
        }
    }

    func testUnavailableDirectoryPreservesAppsAndSuccessfulScanRemovesMissing() async {
        let a = app("a")
        store.save(Layout(pages: [Page(id: "page", items: [.app(a)])]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store)
            model.loadCachedLayout()
            model.applyScan(AppScanner.ScanResult(apps: [], unavailablePaths: ["/Applications"]))
            XCTAssertEqual(model.allApps, [a])
            XCTAssertEqual(model.pages[0].id, "page")
            model.applyScan(AppScanner.ScanResult(apps: []))
            XCTAssertTrue(model.allApps.isEmpty)
            XCTAssertEqual(model.pages.count, 1)
            XCTAssertTrue(model.pages[0].items.isEmpty)
        }
    }

    func testBackupFailureDoesNotResetLayout() async throws {
        let apps = [app("a"), app("b")]
        let original = [Page(id: "page", items: apps.reversed().map { .app($0) })]
        store.save(Layout(pages: original))
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("Backups"))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            model.resetLayout()
            XCTAssertEqual(model.pages, original)
            XCTAssertNotNil(model.statusMessage)
            XCTAssertFalse(model.canUndo)
        }
    }

    func testNoOpDoesNotEraseRedoHistory() async {
        let apps = [app("a"), app("b")]
        store.save(Layout(pages: [Page(id: "page", items: apps.map { .app($0) })]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            model.move("app:b", before: "app:a", onPage: 0)
            model.undoLayoutChange()
            model.move("app:a", before: "app:a", onPage: 0)
            XCTAssertTrue(model.canRedo)
            model.redoLayoutChange()
            XCTAssertEqual(model.pages.flatMap(\.items).flatMap(\.containedApps).map(\.id), ["b", "a"])
        }
    }

    func testRepeatedMovesCombinesExtractionAndUndoKeepEveryApp() async throws {
        let apps = (0..<100).map { app("app\($0)") }
        store.save(Layout(pages: [Page(items: apps.map { .app($0) })]))
        try await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { apps })
            model.load()
            for index in 0..<40 {
                let items = model.pages.flatMap(\.items)
                if index % 3 == 0, items.count > 1 {
                    model.combine(items[0].id, into: items[1].id)
                } else if let folder = items.compactMap({ item -> Folder? in
                    if case .folder(let folder) = item { return folder }; return nil
                }).first, let app = folder.apps.first {
                    model.extractApp(app.id, fromFolder: folder.id)
                } else if let last = items.last {
                    model.moveItem(last.id, toPage: index % (model.pages.count + 1))
                }
                let changed = model.pages
                model.undoLayoutChange()
                model.redoLayoutChange()
                XCTAssertEqual(model.pages, changed)
                let ids = model.pages.flatMap(\.items).flatMap(\.containedApps).map(\.id)
                XCTAssertEqual(Set(ids), Set(apps.map(\.id)))
                XCTAssertEqual(ids.count, apps.count)
                XCTAssertTrue(model.pages.allSatisfy { $0.items.count <= model.itemsPerPage })
                XCTAssertTrue(model.pages.indices.contains(model.currentPage))
            }
            XCTAssertEqual(try XCTUnwrap(store.load()).pages, model.pages)
        }
    }

    func testKeyboardGridNavigationCrossesPagesAndMovesByRows() async {
        let apps = (0..<7).map { app("app\($0)") }
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.columns = 4
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            model.pages = [
                Page(id: "first", items: apps.prefix(6).map { .app($0) }),
                Page(id: "second", items: [.app(apps[6])]),
            ]

            model.moveGridSelection(horizontal: 1)
            XCTAssertEqual(model.selectedGridItemID, "app:app0")
            model.moveGridSelection(vertical: 1)
            XCTAssertEqual(model.selectedGridItemID, "app:app4")
            model.selectGridBoundary(first: false)
            model.moveGridSelection(horizontal: 1)
            XCTAssertEqual(model.currentPage, 1)
            XCTAssertEqual(model.selectedGridItemID, "app:app6")
            model.moveGridSelection(horizontal: -1)
            XCTAssertEqual(model.currentPage, 0)
            XCTAssertEqual(model.selectedGridItemID, "app:app5")
        }
    }

    func testPageChangeClearsGridSelection() async {
        let apps = [app("a"), app("b")]
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: [.app(apps[0])]), Page(items: [.app(apps[1])])]
            model.selectedGridItemID = "app:a"

            model.goToPage(1)

            XCTAssertNil(model.selectedGridItemID)
            XCTAssertEqual(model.currentPage, 1)
        }
    }

    func testKeyboardFolderNavigationSelectsRowsAndClamps() async {
        let apps = (0..<7).map { app("folder\($0)") }
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: [
                .folder(Folder(id: "tools", name: "Tools", apps: apps)),
            ])]

            model.openFolder("tools")
            XCTAssertEqual(model.selectedFolderApp?.id, "folder0")
            model.moveFolderSelection(vertical: 1, columns: 4)
            XCTAssertEqual(model.selectedFolderApp?.id, "folder4")
            model.moveFolderSelection(vertical: 1, columns: 4)
            XCTAssertEqual(model.selectedFolderApp?.id, "folder6")
            model.closeFolder()
            XCTAssertNil(model.selectedFolderAppID)
        }
    }

    func testKeyboardReorderingSwapsItemsAndCanBeUndone() async {
        let apps = (0..<6).map { app("move\($0)") }
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.columns = 4
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            model.pages = [Page(items: apps.map { .app($0) })]
            model.selectedGridItemID = "app:move0"

            XCTAssertTrue(model.moveSelectedGridItem(horizontal: 1))
            XCTAssertEqual(model.pages[0].items.map(\.id).prefix(2), ["app:move1", "app:move0"])
            XCTAssertTrue(model.moveSelectedGridItem(vertical: 1))
            XCTAssertEqual(model.pages[0].items.last?.id, "app:move0")
            XCTAssertEqual(model.selectedGridItemID, "app:move0")

            model.undoLayoutChange()
            XCTAssertEqual(model.pages[0].items.map(\.id).prefix(2), ["app:move1", "app:move0"])
        }
    }

    func testKeyboardReorderingCrossesFullPagesWithoutLosingItems() async {
        let apps = (0..<24).map { app("cross\($0)") }
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.columns = 4
        settings.rows = 3
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            model.pages = [
                Page(items: apps.prefix(12).map { .app($0) }),
                Page(items: apps.suffix(12).map { .app($0) }),
            ]
            model.selectedGridItemID = "app:cross11"

            XCTAssertTrue(model.moveSelectedGridItem(horizontal: 1))
            XCTAssertEqual(model.currentPage, 1)
            XCTAssertEqual(model.pages[0].items.last?.id, "app:cross12")
            XCTAssertEqual(model.pages[1].items.first?.id, "app:cross11")
            XCTAssertEqual(Set(model.pages.flatMap(\.items).flatMap(\.containedApps)), Set(apps))
        }
    }

    func testKeyboardCanCreateFolderAndKeepsItSelected() async {
        let apps = [app("source"), app("target"), app("other")]
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: apps.map { .app($0) })]
            model.selectedGridItemID = "app:source"

            XCTAssertTrue(model.combineSelectedGridItem(withNeighbor: 1))
            guard case .folder(let folder)? = model.selectedGridItem else {
                return XCTFail("Expected the new folder to stay selected")
            }
            XCTAssertEqual(Set(folder.apps), Set(apps.prefix(2)))
        }
    }

    func testKeyboardReordersAndExtractsSelectedFolderApp() async {
        let apps = (0..<4).map { app("inside\($0)") }
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [] })
            model.pages = [Page(items: [
                .folder(Folder(id: "folder", name: "Folder", apps: apps)),
            ])]
            model.openFolder("folder")

            XCTAssertTrue(model.moveSelectedFolderApp(horizontal: 1, columns: 2))
            XCTAssertEqual(model.folder(withID: "folder")?.apps.prefix(2), [apps[1], apps[0]])
            XCTAssertTrue(model.extractSelectedFolderApp())
            XCTAssertNil(model.openFolderID)
            XCTAssertEqual(model.selectedGridItemID, "app:inside0")
            XCTAssertTrue(model.pages.flatMap(\.items).contains(.app(apps[0])))
        }
    }

    func testNavigationStateRestoresPageFolderAndSelectedApp() async {
        let apps = [app("outside"), app("inside1"), app("inside2")]
        let pages = [
            Page(id: "first", items: [.app(apps[0])]),
            Page(id: "second", items: [
                .folder(Folder(id: "tools", name: "Tools", apps: Array(apps.suffix(2)))),
            ]),
        ]
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await MainActor.run {
            let original = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            original.pages = pages
            original.currentPage = 1
            original.selectedGridItemID = "folder:tools"
            original.openFolder("tools")
            original.selectedFolderAppID = "inside2"
            original.saveNavigationState()

            let restored = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            restored.pages = pages
            restored.restoreNavigationState()

            XCTAssertEqual(restored.currentPage, 1)
            XCTAssertEqual(restored.selectedGridItemID, "folder:tools")
            XCTAssertEqual(restored.openFolderID, "tools")
            XCTAssertEqual(restored.selectedFolderAppID, "inside2")
        }
    }

    func testNavigationStateDropsMissingObjects() async {
        let app = app("available")
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.saveNavigationState(LaunchpadNavigationState(
            pageID: "missing-page", itemID: "app:missing",
            folderID: "missing-folder", folderAppID: "missing-app"))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings, scanApps: { [] })
            model.pages = [Page(id: "only", items: [.app(app)])]

            model.restoreNavigationState()

            XCTAssertEqual(model.currentPage, 0)
            XCTAssertNil(model.selectedGridItemID)
            XCTAssertNil(model.openFolderID)
            XCTAssertNil(model.selectedFolderAppID)
        }
    }

    func testNewAppsFillLastPageBeforeCreatingNewOne() async {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.columns = 4
        settings.rows = 3
        let old = (0..<14).map { app("old\($0)") }
        let fresh = (0..<3).map { app("new\($0)") }
        store.save(Layout(pages: [
            Page(id: "first", items: old.prefix(12).map { .app($0) }),
            Page(id: "tail", items: old.suffix(2).map { .app($0) }),
        ]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings,
                                       scanApps: { old + fresh })
            model.load()
            XCTAssertEqual(model.pages.map(\.id), ["first", "tail"])
            XCTAssertEqual(model.pages[1].items.map(\.id),
                           (old.suffix(2) + fresh).map { "app:" + $0.id })
        }
    }

    func testNewAppsOverflowFullLastPage() async {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.columns = 4
        settings.rows = 3
        let old = (0..<12).map { app("old\($0)") }
        let fresh = app("fresh")
        store.save(Layout(pages: [Page(id: "full", items: old.map { .app($0) })]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, settings: settings,
                                       scanApps: { old + [fresh] })
            model.load()
            XCTAssertEqual(model.pages.count, 2)
            XCTAssertEqual(model.pages[0].items.count, 12)
            XCTAssertEqual(model.pages[1].items.map(\.id), ["app:fresh"])
        }
    }

    func testScanKeepsUndoHistoryWithoutRemovedApps() async {
        let a = app("a"), b = app("b"), c = app("c")
        store.save(Layout(pages: [Page(id: "page", items: [.app(a), .app(b), .app(c)])]))
        await MainActor.run {
            let model = LaunchpadModel(layoutStore: store, scanApps: { [a, b, c] })
            model.load()
            model.move("app:c", before: "app:a", onPage: 0)
            XCTAssertTrue(model.canUndo)
            model.applyScan(AppScanner.ScanResult(apps: [a, c]))
            XCTAssertTrue(model.canUndo)
            model.undoLayoutChange()
            XCTAssertEqual(model.pages.flatMap(\.items).map(\.id), ["app:a", "app:c"])
        }
    }
}
