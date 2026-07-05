import SwiftUI
import UniformTypeIdentifiers

/// Одна страница сетки приложений с поддержкой перетаскивания.
struct PageView: View {
    let page: Page
    let pageIndex: Int
    @ObservedObject var model: LaunchpadModel
    @Binding var draggingID: String?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 24), count: model.columns)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 28) {
            ForEach(page.items) { item in
                GridCell(item: item,
                         pageIndex: pageIndex,
                         model: model,
                         draggingID: $draggingID)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Ячейка сетки: приложение или папка.
struct GridCell: View {
    let item: LaunchpadItem
    let pageIndex: Int
    @ObservedObject var model: LaunchpadModel
    @Binding var draggingID: String?

    @State private var isTargeted = false

    var body: some View {
        content
            .frame(width: 120, height: 128)
            .scaleEffect(draggingID == item.id ? 0.85 : (isTargeted ? 1.12 : 1.0))
            .opacity(draggingID == item.id ? 0.4 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: draggingID)
            .contentShape(Rectangle())
            .onTapGesture { activate() }
            .onDrag {
                draggingID = item.id
                return NSItemProvider(object: item.id as NSString)
            }
            .onDrop(of: [.text],
                    delegate: CellDropDelegate(targetID: item.id,
                                               pageIndex: pageIndex,
                                               model: model,
                                               draggingID: $draggingID,
                                               isTargeted: $isTargeted))
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .app(let app):
            AppIconView(app: app)
        case .folder(let folder):
            FolderIconView(folder: folder)
        }
    }

    private func activate() {
        switch item {
        case .app(let app):
            AppLauncher.launch(app)
            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
        case .folder(let folder):
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.openFolderID = folder.id
            }
        }
    }
}

/// Делегат сброса для ячейки: центр — объединение в папку, край — перестановка.
struct CellDropDelegate: DropDelegate {
    let targetID: String
    let pageIndex: Int
    let model: LaunchpadModel
    @Binding var draggingID: String?
    @Binding var isTargeted: Bool

    private let cellWidth: CGFloat = 120

    func dropEntered(info: DropInfo) {
        if draggingID != nil, draggingID != targetID, canCombine {
            isTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isTargeted = false
            draggingID = nil
        }
        guard let source = draggingID, source != targetID else { return false }

        // Центральная треть ячейки — попытка объединить в папку.
        let x = info.location.x
        let central = x > cellWidth * 0.28 && x < cellWidth * 0.72
        if central && canCombine {
            if model.combine(source, into: targetID) { return true }
        }
        model.move(source, before: targetID, onPage: pageIndex)
        return true
    }

    /// Можно объединять, если цель — папка либо оба элемента приложения.
    private var canCombine: Bool {
        guard let source = draggingID else { return false }
        return isFolder(targetID) || (isApp(source) && isApp(targetID))
    }

    private func isFolder(_ id: String) -> Bool { id.hasPrefix("folder:") }
    private func isApp(_ id: String) -> Bool { id.hasPrefix("app:") }
}
