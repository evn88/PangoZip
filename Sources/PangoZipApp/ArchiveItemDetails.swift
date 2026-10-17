import PangoZipCore

struct ArchiveItemDetails: Sendable {
  let entry: ArchiveEntry
  private(set) var size: UInt64?
  private(set) var packedSize: UInt64?
  private(set) var fileCount = 0
  private(set) var folderCount = 0

  var compressionSavings: Double? {
    guard let size, size > 0, let packedSize else { return nil }
    return (1 - Double(packedSize) / Double(size)) * 100
  }

  init(entry: ArchiveEntry) {
    self.entry = entry
    size = entry.isDirectory ? 0 : entry.size
    packedSize = entry.isDirectory ? 0 : entry.packedSize
  }

  /// Каждый узел участвует только в сумме непосредственного родителя; обход работает вне UI.
  static func folders(in roots: [ArchiveNode]) throws -> [String: ArchiveItemDetails] {
    try Task.checkCancellation()
    func isFolder(_ node: ArchiveNode) -> Bool {
      node.children != nil || node.entry?.isDirectory == true
    }
    func sum(_ first: UInt64?, _ second: UInt64?) -> UInt64? {
      guard let first, let second else { return nil }
      let result = first.addingReportingOverflow(second)
      return result.overflow ? nil : result.partialValue
    }
    var results: [String: ArchiveItemDetails] = [:]
    var pending: [(node: ArchiveNode, expanded: Bool)] = []
    for root in roots {
      try Task.checkCancellation()
      if isFolder(root) { pending.append((root, false)) }
    }
    while let (node, expanded) = pending.popLast() {
      try Task.checkCancellation()
      if !expanded {
        pending.append((node, true))
        for child in node.children ?? [] {
          try Task.checkCancellation()
          if isFolder(child) { pending.append((child, false)) }
        }
        continue
      }
      var details = ArchiveItemDetails(
        entry: node.entry ?? ArchiveEntry(path: node.path, isDirectory: true))
      for child in node.children ?? [] {
        try Task.checkCancellation()
        if isFolder(child) {
          let nested = results[child.path]!
          details.size = sum(details.size, nested.size)
          details.packedSize = sum(details.packedSize, nested.packedSize)
          details.fileCount += nested.fileCount
          details.folderCount += nested.folderCount + 1
        } else {
          details.size = sum(details.size, child.entry?.size)
          details.packedSize = sum(details.packedSize, child.entry?.packedSize)
          details.fileCount += 1
        }
      }
      results[node.path] = details
    }
    return results
  }
}
