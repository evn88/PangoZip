import PangoZipCore

struct ArchiveItemDetails: Sendable {
  let entry: ArchiveEntry
  private(set) var size: UInt64?
  private(set) var packedSize: UInt64?
  /// Хотя бы одна часть `packedSize` оценена по общему solid-блоку 7z, а не взята из архива.
  private(set) var isPackedSizeEstimated = false
  private(set) var fileCount = 0
  private(set) var folderCount = 0

  var compressionSavings: Double? {
    guard let size, size > 0, let packedSize else { return nil }
    return (1 - Double(packedSize) / Double(size)) * 100
  }

  init(entry: ArchiveEntry) {
    self.entry = entry
    size = entry.isDirectory ? 0 : entry.size
    packedSize = entry.isDirectory ? 0 : entry.packedSize ?? entry.estimatedPackedSize
    isPackedSizeEstimated =
      !entry.isDirectory && entry.packedSize == nil && entry.estimatedPackedSize != nil
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
          details.isPackedSizeEstimated =
            details.isPackedSizeEstimated || nested.isPackedSizeEstimated
          details.fileCount += nested.fileCount
          details.folderCount += nested.folderCount + 1
        } else {
          details.size = sum(details.size, child.entry?.size)
          let file = child.entry.map(ArchiveItemDetails.init(entry:))
          details.packedSize = sum(details.packedSize, file?.packedSize)
          details.isPackedSizeEstimated =
            details.isPackedSizeEstimated || file?.isPackedSizeEstimated == true
          details.fileCount += 1
        }
      }
      results[node.path] = details
    }
    return results
  }
}
