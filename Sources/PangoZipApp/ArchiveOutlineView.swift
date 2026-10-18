import AppKit
import PangoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveOutlineView: NSViewRepresentable {
  @ObservedObject var model: ArchiveBrowserModel
  @ObservedObject var columnSettings: ArchiveColumnSettings = .shared
  var roots: [ArchiveNode] { model.visibleRoots }
  var sessionID: UUID? { model.session?.id }
  var selectedPaths: Set<String> {
    get { model.selectedPaths }
    nonmutating set { model.selectedPaths = newValue }
  }
  /// Передаёт действие модели, которая проверяет тип выделенной записи и доступность сеанса.
  func openSelection() { model.openSelectedExternally() }

  /// Хранит идентичность узлов и состояние AppKit между обновлениями SwiftUI.
  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Создаёт таблицу с отдельными правилами входящего и исходящего перетаскивания.
  func makeNSView(context: Context) -> NSScrollView {
    let outline = InteractiveOutlineView()
    outline.style = .inset
    outline.rowSizeStyle = .medium
    outline.allowsMultipleSelection = true
    outline.allowsEmptySelection = true
    outline.usesAlternatingRowBackgroundColors = true
    outline.columnAutoresizingStyle = .noColumnAutoresizing
    outline.autosaveExpandedItems = false
    outline.autosaveName = "ArchiveContents"
    outline.autosaveTableColumns = true
    outline.setAccessibilityLabel(L10n.tr("Содержимое архива"))
    context.coordinator.configureColumns(in: outline)
    outline.outlineTableColumn = outline.tableColumn(withIdentifier: .init("name"))
    outline.delegate = context.coordinator
    outline.dataSource = context.coordinator
    outline.target = context.coordinator
    outline.doubleAction = #selector(Coordinator.doubleClick(_:))
    outline.registerForDraggedTypes([.fileURL])
    outline.setDraggingSourceOperationMask(.copy, forLocal: false)
    outline.setDraggingSourceOperationMask([], forLocal: true)
    outline.makeContextMenu = { [weak coordinator = context.coordinator] row in
      coordinator?.contextMenu(row: row)
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = outline
    context.coordinator.outline = outline
    context.coordinator.update(self)
    return scroll
  }

  /// Синхронизирует существующую таблицу через координатор, сохраняя её состояние.
  func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update(self) }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Item {
      let node: ArchiveNode
      let children: [Item]
      /// Создаёт устойчивые объекты для AppKit из неизменяемого дерева архива.
      init(_ node: ArchiveNode) {
        self.node = node
        children = (node.children ?? []).map(Item.init)
      }
    }
    var parent: ArchiveOutlineView
    weak var outline: NSOutlineView?
    private var items: [Item] = []
    private var byPath: [String: Item] = [:]
    private var previousRoots: [ArchiveNode] = []
    private var previousSessionID: UUID?
    private var previousDetailsRevision = -1
    private var expandedPaths: Set<String> = []
    private var updating = false
    private var dragID: UUID?
    private var dragRoots: Set<String> = []
    private var dragSelection: Set<String> = []
    private static let dateFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      return formatter
    }()

    /// Сохраняет представление, которое будет заменяться при обновлениях SwiftUI.
    init(_ parent: ArchiveOutlineView) { self.parent = parent }

    func configureColumns(in outline: NSOutlineView) {
      for definition in ArchiveColumn.allCases {
        let column = NSTableColumn(identifier: .init(definition.rawValue))
        column.title = definition.title
        column.width = definition.width
        column.minWidth = definition == .name ? 220 : 70
        if definition.isNumeric { column.headerCell.alignment = .right }
        if definition == .compression {
          column.headerToolTip = L10n.tr(
            "На сколько размер в архиве меньше исходного. Отрицательное значение означает увеличение размера."
          )
        } else if definition == .fileCount || definition == .folderCount {
          column.headerToolTip = L10n.tr("Количество во всех вложенных папках")
        }
        outline.addTableColumn(column)
      }
    }

    private func applyColumnVisibility() {
      guard let outline else { return }
      for column in outline.tableColumns {
        guard let definition = ArchiveColumn(rawValue: column.identifier.rawValue) else { continue }
        column.isHidden = !parent.columnSettings.isVisible(definition)
      }
      let menu = NSMenu()
      menu.autoenablesItems = false
      for column in ArchiveColumn.allCases {
        let item = NSMenuItem(
          title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = column.rawValue
        item.state = parent.columnSettings.isVisible(column) ? .on : .off
        item.isEnabled = column != .name
        menu.addItem(item)
      }
      menu.addItem(.separator())
      let reset = NSMenuItem(
        title: L10n.tr("Стандартные колонки"), action: #selector(resetColumns), keyEquivalent: "")
      reset.target = self
      menu.addItem(reset)
      outline.headerView?.menu = menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
      guard let rawValue = sender.representedObject as? String,
        let column = ArchiveColumn(rawValue: rawValue)
      else { return }
      parent.columnSettings.setVisible(!parent.columnSettings.isVisible(column), for: column)
      applyColumnVisibility()
    }

    @objc private func resetColumns() {
      parent.columnSettings.reset()
      applyColumnVisibility()
    }

    /// Восстанавливает раскрытие и выделение без обратной записи промежуточных событий AppKit.
    func update(_ newParent: ArchiveOutlineView) {
      parent = newParent
      guard let outline else { return }
      applyColumnVisibility()
      updating = true
      defer { updating = false }
      if previousRoots != parent.roots || previousSessionID != parent.sessionID {
        if previousSessionID != parent.sessionID { expandedPaths.removeAll() }
        previousSessionID = parent.sessionID
        previousRoots = parent.roots
        items = parent.roots.map(Item.init)
        byPath.removeAll()
        /// Индексирует также скрытые дочерние узлы для восстановления выделения по пути.
        func index(_ items: [Item]) {
          for item in items {
            byPath[item.node.path] = item
            index(item.children)
          }
        }
        index(items)
        outline.reloadData()
        /// Раскрывает только ранее сохранённые пути и затем обходит их дочерние узлы.
        func restore(_ items: [Item]) {
          for item in items where expandedPaths.contains(item.node.path) {
            outline.expandItem(item)
            restore(item.children)
          }
        }
        restore(items)
      }
      let rows = IndexSet(
        parent.selectedPaths.compactMap { path in
          guard let item = byPath[path] else { return nil }
          let row = outline.row(forItem: item)
          return row >= 0 ? row : nil
        })
      if previousDetailsRevision != parent.model.itemDetailsRevision {
        previousDetailsRevision = parent.model.itemDetailsRevision
        let columns = IndexSet(
          outline.tableColumns.indices.filter {
            ["size", "compression", "fileCount", "folderCount"].contains(
              outline.tableColumns[$0].identifier.rawValue)
          })
        outline.reloadData(
          forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: columns)
      }
      if outline.selectedRowIndexes != rows {
        outline.selectRowIndexes(rows, byExtendingSelection: false)
      }
    }

    /// Для корня использует общее дерево, для строки — её непосредственных потомков.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      (item as? Item)?.children.count ?? items.count
    }
    /// Возвращает объект из того же дерева, по которому AppKit запросил число строк.
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      ((item as? Item)?.children ?? items)[index]
    }
    /// Виртуальная папка раскрывается только при наличии видимых дочерних записей.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      !(item as! Item).children.isEmpty
    }
    /// Не переносит в модель промежуточное выделение при программном обновлении таблицы.
    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let outline else { return }
      parent.selectedPaths = Set(
        outline.selectedRowIndexes.compactMap {
          (outline.item(atRow: $0) as? Item)?.node.path
        })
    }
    /// Сохраняет путь вместо объекта строки, чтобы пережить замену дерева.
    func outlineViewItemDidExpand(_ notification: Notification) {
      guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
      expandedPaths.insert(item.node.path)
    }
    /// Удаляет только путь свёрнутой папки, сохраняя раскрытие вложенных папок на будущее.
    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
      expandedPaths.remove(item.node.path)
    }
    /// Для папки меняет раскрытие, для файла использует текущее выделение модели.
    @objc func doubleClick(_ sender: NSOutlineView) {
      guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? Item else {
        return
      }
      if item.node.entry?.isDirectory == true || !item.children.isEmpty {
        if sender.isItemExpanded(item) {
          sender.collapseItem(item)
        } else {
          sender.expandItem(item)
        }
      } else {
        parent.openSelection()
      }
    }
    /// Повторно использует ячейки и подставляет прочерк для отсутствующих метаданных.
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
      -> NSView?
    {
      guard let column = tableColumn, let item = item as? Item else { return nil }
      let id = column.identifier
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
      let entry = item.node.entry
      let isFolder = entry?.isDirectory == true || !item.children.isEmpty || entry == nil
      let value: String
      switch id.rawValue {
      case "name": value = item.node.name
      case "size":
        value =
          (isFolder ? parent.model.itemDetailsByPath[item.node.path]?.size : entry?.size).map {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
          } ?? (isFolder && parent.model.areFolderDetailsLoading ? "…" : "—")
      case "compression":
        let details =
          isFolder
          ? parent.model.itemDetailsByPath[item.node.path]
          : entry.map { ArchiveItemDetails(entry: $0) }
        value =
          details?.compressionSavings.map {
            ($0 / 100).formatted(.percent.precision(.fractionLength(0...1)))
          } ?? (isFolder && parent.model.areFolderDetailsLoading ? "…" : "—")
      case "packed":
        value =
          isFolder
          ? "—"
          : entry?.packedSize.map {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
          } ?? "—"
      case "kind":
        let extensionName = (item.node.name as NSString).pathExtension
        value =
          isFolder
          ? L10n.tr("Папка")
          : UTType(filenameExtension: extensionName)?.localizedDescription
            ?? (extensionName.isEmpty ? L10n.tr("Файл") : extensionName.uppercased())
      case "modified": value = entry?.modifiedAt.map(Self.dateFormatter.string(from:)) ?? "—"
      case "method": value = isFolder ? "—" : entry?.method ?? "—"
      case "created": value = entry?.createdAt.map(Self.dateFormatter.string(from:)) ?? "—"
      case "permissions": value = entry?.permissions ?? "—"
      case "owner": value = entry?.owner ?? "—"
      case "group": value = entry?.group ?? "—"
      case "encrypted": value = entry.map { $0.isEncrypted ? L10n.tr("Да") : L10n.tr("Нет") } ?? "—"
      case "checksum": value = entry?.checksum ?? "—"
      case "path": value = item.node.path
      case "specialFile":
        value = entry.map { $0.isSymbolicLink ? L10n.tr("Да") : L10n.tr("Нет") } ?? "—"
      case "fileCount", "folderCount":
        if isFolder {
          let details = parent.model.itemDetailsByPath[item.node.path]
          value =
            details.map {
              (id.rawValue == "fileCount" ? $0.fileCount : $0.folderCount).formatted()
            } ?? (parent.model.areFolderDetailsLoading ? "…" : "—")
        } else {
          value = "—"
        }
      case "otherMetadata":
        let knownFields = Set(ArchiveColumn.allCases.compactMap(\.metadataKey))
        let metadata = (entry?.additionalMetadata ?? [:]).filter {
          !knownFields.contains($0.key)
        }.sorted { $0.key < $1.key }
        value =
          metadata.isEmpty ? "—" : metadata.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
      default:
        value =
          ArchiveColumn(rawValue: id.rawValue)?.metadataKey.flatMap {
            entry?.additionalMetadata[$0]
          } ?? "—"
      }
      cell.textField?.stringValue = value.isEmpty ? "—" : value
      if isFolder && parent.model.areFolderDetailsLoading
        && ["size", "compression", "fileCount", "folderCount"].contains(id.rawValue)
      {
        cell.toolTip =
          ["fileCount", "folderCount"].contains(id.rawValue)
          ? L10n.tr("Подсчитываем содержимое папок…") : L10n.tr("Подсчитываем размеры папок…")
      } else {
        cell.toolTip = id.rawValue == "name" ? item.node.path : value
      }
      if id.rawValue == "name" {
        cell.imageView?.image = NSImage(
          systemSymbolName: isFolder ? "folder" : "doc",
          accessibilityDescription: isFolder ? L10n.tr("Папка") : L10n.tr("Файл"))
        cell.imageView?.contentTintColor = isFolder ? .controlAccentColor : .secondaryLabelColor
      }
      return cell
    }
    /// Правый клик согласует выделение с меню до проверки доступности команд.
    func contextMenu(row: Int) -> NSMenu? {
      guard let outline else { return nil }
      if row >= 0 && !outline.selectedRowIndexes.contains(row) {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      } else if row < 0 {
        outline.deselectAll(nil)
      }
      let model = parent.model
      let menu = NSMenu()
      menu.autoenablesItems = false
      /// Фиксирует доступность команды при построении меню и направляет её координатору.
      func add(
        _ title: String, _ action: Selector, enabled: Bool, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
      ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
      }
      if !model.selectedPaths.isEmpty {
        add(
          L10n.tr("Открыть файл"), #selector(openFile), enabled: model.canOpenSelection, key: "\r")
        add(
          L10n.tr("Редактировать файл"), #selector(editFile),
          enabled: model.canModify && model.canOpenSelection, key: "e")
        add(
          L10n.tr("Извлечь выбранное…"), #selector(extractFiles), enabled: model.canQueueOperations,
          key: "e",
          modifiers: [.command, .shift])
        add(L10n.tr("Копировать путь в архиве"), #selector(copyPaths), enabled: true)
        menu.addItem(.separator())
        if row >= 0, model.selectedPaths.count == 1, let item = outline.item(atRow: row) as? Item,
          !item.children.isEmpty
        {
          add(
            outline.isItemExpanded(item) ? L10n.tr("Свернуть папку") : L10n.tr("Раскрыть папку"),
            #selector(toggleFolder), enabled: true)
        }
      }
      add(
        L10n.tr("Добавить файлы и папки…"), #selector(addFiles),
        enabled: model.canQueueModifications, key: "a",
        modifiers: [.command, .shift])
      add(
        L10n.tr("Сохранить изменения в архив"), #selector(saveFiles),
        enabled: model.canModify && !model.activeEdits.isEmpty, key: "s")
      if !model.selectedPaths.isEmpty {
        menu.addItem(.separator())
        add(
          L10n.tr("Удалить из архива…"), #selector(deleteFiles),
          enabled: model.canQueueModifications,
          key: "\u{8}")
      }
      return menu
    }

    /// Модель повторно проверяет доступность файла при выполнении команды меню.
    @objc private func openFile() { parent.model.openSelectedExternally() }
    /// Оставляет проверку изменяемости архива модели, даже если меню уже открыто.
    @objc private func editFile() { parent.model.editSelected() }
    /// Передаёт выделение модели, которая зафиксирует пути до показа панели назначения.
    @objc private func extractFiles() { parent.model.extractSelected() }
    /// Копирует внутренние пути без предварительного извлечения объектов.
    @objc private func copyPaths() { parent.model.copySelectedPaths() }
    /// Использует текущую папку выделения, которую модель зафиксирует перед выбором файлов.
    @objc private func addFiles() { parent.model.chooseFilesToAdd() }
    /// Сохранение рабочих копий требует отдельной команды пользователя во внешнем редакторе.
    @objc private func saveFiles() { parent.model.saveWorkingCopies() }
    /// Модель проверяет рабочие копии до удаления выделенных путей.
    @objc private func deleteFiles() { parent.model.deleteSelected() }
    /// Находит папку по пути, чтобы не использовать объект прежнего дерева.
    @objc private func toggleFolder() {
      guard let outline, let path = parent.model.selectedPath, let item = byPath[path] else {
        return
      }
      if outline.isItemExpanded(item) {
        outline.collapseItem(item)
      } else {
        outline.expandItem(item)
      }
    }

    /// Обещает только верхние пути выделения, исключая повторное извлечение вложенных объектов.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
      -> NSPasteboardWriting?
    {
      guard parent.model.canAct, let snapshot = parent.model.session, let item = item as? Item
      else { return nil }
      if dragID == nil || dragSelection != parent.selectedPaths {
        guard
          let roots = try? ArchiveSelection.topLevelPaths(
            Array(parent.selectedPaths), entries: snapshot.entries)
        else { return nil }
        dragSelection = parent.selectedPaths
        dragRoots = Set(roots)
        dragID = UUID()
      }
      guard dragRoots.contains(item.node.path), let id = dragID else { return nil }
      let promise = ArchiveFilePromise(
        path: item.node.path, session: snapshot, dragID: id, model: parent.model)
      return promise.provider(
        isDirectory: item.node.entry?.isDirectory == true || item.node.entry == nil)
    }

    /// Удерживает сеанс после начала перетаскивания, когда AppKit уже собрал обещания файлов.
    func outlineView(
      _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
      willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
      guard let id = dragID else { return }
      parent.model.beginDragging(
        id: id, paths: draggedItems.compactMap { ($0 as? Item)?.node.path })
    }

    /// Передаёт результат модели и сбрасывает идентификатор для следующего перетаскивания.
    func outlineView(
      _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
      endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      if let id = dragID { parent.model.endDragging(id: id, deposited: operation.contains(.copy)) }
      dragID = nil
      dragRoots.removeAll()
      dragSelection.removeAll()
    }

    /// Разрешает локальные файлы из другого источника и направляет вставку в ближайшую папку.
    func outlineView(
      _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
      proposedChildIndex index: Int
    ) -> NSDragOperation {
      guard parent.model.canQueueModifications,
        !(info.draggingSource as? NSOutlineView === outlineView),
        info.draggingPasteboard.canReadObject(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      else { return [] }
      if let folder = dropFolder(item) {
        outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
      } else {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
      }
      return .copy
    }

    /// Откладывает подтверждение добавления до выхода из обратного вызова AppKit.
    func outlineView(
      _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?,
      childIndex index: Int
    ) -> Bool {
      guard parent.model.canQueueModifications,
        let urls = info.draggingPasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
        !urls.isEmpty
      else { return false }
      let directory = dropFolder(item)?.node.path ?? ""
      let model = parent.model
      DispatchQueue.main.async { model.addDroppedFiles(urls, directory: directory) }
      return true
    }

    /// При попадании на файл выбирает его родителя; отсутствие папки означает корень архива.
    private func dropFolder(_ item: Any?) -> Item? {
      guard let item = item as? Item else { return nil }
      if item.node.entry?.isDirectory == true || item.node.entry == nil { return item }
      let parentPath = item.node.path.split(separator: "/").dropLast().joined(separator: "/")
      return byPath[parentPath]
    }

    /// Оставляет текст штатному NSTextField, чтобы сохранить выделение и доступность AppKit.
    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = id
      let text = NSTextField(labelWithString: "")
      text.lineBreakMode = .byTruncatingMiddle
      text.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(text)
      cell.textField = text
      var leading = cell.leadingAnchor
      var offset: CGFloat = 6
      if id.rawValue == "name" {
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.imageView = image
        NSLayoutConstraint.activate([
          image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
          image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          image.widthAnchor.constraint(equalToConstant: 18),
          image.heightAnchor.constraint(equalToConstant: 18),
        ])
        leading = image.trailingAnchor
        offset = 7
      } else {
        text.textColor = .secondaryLabelColor
        if ArchiveColumn(rawValue: id.rawValue)?.isNumeric == true {
          text.alignment = .right
          text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
      }
      NSLayoutConstraint.activate([
        text.leadingAnchor.constraint(equalTo: leading, constant: offset),
        text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }
  }
}

@MainActor
final class InteractiveOutlineView: NSOutlineView {
  var makeContextMenu: ((Int) -> NSMenu?)?
  /// Строит меню для строки под курсором, включая свободное пространство таблицы.
  override func menu(for event: NSEvent) -> NSMenu? {
    makeContextMenu?(row(at: convert(event.locationInWindow, from: nil)))
  }
}
