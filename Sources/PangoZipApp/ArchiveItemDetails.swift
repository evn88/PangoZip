import PangoZipCore

struct ArchiveItemDetails {
  let entry: ArchiveEntry
  let size: UInt64?
  let fileCount: Int
  let folderCount: Int

  init?(path: String, roots: [ArchiveNode]) {
    var candidates = roots
    var selected: ArchiveNode?
    while let node = candidates.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
      if node.path == path {
        selected = node
        break
      }
      candidates = node.children ?? []
    }
    guard let node = selected else { return nil }
    let entry = node.entry ?? ArchiveEntry(path: path, isDirectory: node.children != nil)
    self.entry = entry
    var total: UInt64? = entry.isDirectory ? 0 : entry.size
    var files = 0
    var folders = 0
    var pending = node.children ?? []
    while let child = pending.popLast() {
      if child.children != nil || child.entry?.isDirectory == true {
        folders += 1
        pending.append(contentsOf: child.children ?? [])
      } else {
        files += 1
        if let accumulated = total, let bytes = child.entry?.size {
          let sum = accumulated.addingReportingOverflow(bytes)
          total = sum.overflow ? nil : sum.partialValue
        } else {
          total = nil
        }
      }
    }
    size = total
    fileCount = files
    folderCount = folders
  }
}
