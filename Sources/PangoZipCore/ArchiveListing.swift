import Foundation

public enum ArchiveListing {
  public static func parse(_ output: String) throws -> [ArchiveEntry] {
    var entries: [ArchiveEntry] = []
    var fields: [String: String] = [:]
    var paths: Set<String> = []
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = .current

    func appendEntry() throws {
      guard !fields.isEmpty else { return }
      guard let rawPath = fields["Path"], let rawSize = fields["Size"],
        let size = UInt64(rawSize)
      else { throw ArchiveError.malformedListing }
      let attributes = fields["Attributes"] ?? ""
      let isDirectory = fields["Folder"] == "+" || attributes.hasPrefix("D")
      let path = isDirectory && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
      try validatePath(path)
      guard paths.insert(path).inserted else { throw ArchiveError.duplicatePath }
      let unixMode = fields["Mode"] ?? attributes.split(separator: " ").last.map(String.init) ?? ""
      let isSpecial =
        !unixMode.isEmpty && ["l", "b", "c", "p", "s"].contains(String(unixMode.prefix(1)))
        && unixMode.count >= 10
      let isLink =
        !(fields["Symbolic Link"] ?? "").isEmpty || !(fields["Hard Link"] ?? "").isEmpty
        || isSpecial
      entries.append(
        ArchiveEntry(
          path: path, size: size, isDirectory: isDirectory, isSymbolicLink: isLink,
          createdAt: date(fields["Created"], formatter: formatter),
          modifiedAt: date(fields["Modified"], formatter: formatter),
          permissions: unixMode.count >= 10 ? unixMode : nil,
          owner: nonempty(fields["User"]) ?? nonempty(fields["User ID"]),
          group: nonempty(fields["Group"]) ?? nonempty(fields["Group ID"]),
          isEncrypted: fields["Encrypted"] == "+", checksum: nonempty(fields["CRC"]),
          method: nonempty(fields["Method"])))
      guard entries.count <= 100_000 else { throw ArchiveError.outputLimit }
      fields.removeAll(keepingCapacity: true)
    }

    for rawLine in output.components(separatedBy: "\n") {
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
      if line.isEmpty {
        try appendEntry()
        continue
      }
      guard let separator = line.range(of: " = ") else { throw ArchiveError.malformedListing }
      let key = String(line[..<separator.lowerBound])
      guard fields[key] == nil else { throw ArchiveError.malformedListing }
      fields[key] = String(line[separator.upperBound...])
    }
    try appendEntry()
    return entries
  }

  private static func nonempty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }

  private static func date(_ text: String?, formatter: DateFormatter) -> Date? {
    guard let text, text.count >= 19 else { return nil }
    return formatter.date(from: String(text.prefix(19)))
  }

  public static func validatePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.contains("\\"), !path.contains(":"), components.count <= 128,
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw ArchiveError.unsafePath
    }
  }

  public static func tree(from entries: [ArchiveEntry]) throws -> [ArchiveNode] {
    var records: [String: ArchiveEntry] = [:]
    var children: [String: Set<String>] = [:]
    for entry in entries {
      let parts = entry.path.split(separator: "/").map(String.init)
      var parent = ""
      for (index, component) in parts.enumerated() {
        let path = parent.isEmpty ? component : parent + "/" + component
        children[parent, default: []].insert(path)
        let record = index == parts.count - 1 ? entry : ArchiveEntry(path: path, isDirectory: true)
        if let existing = records[path], existing.isDirectory != record.isDirectory {
          throw ArchiveError.duplicatePath
        }
        if records[path] == nil || index == parts.count - 1 { records[path] = record }
        parent = path
      }
    }
    func nodes(under parent: String) -> [ArchiveNode] {
      (children[parent] ?? []).compactMap { path -> ArchiveNode? in
        guard let entry = records[path] else { return nil }
        return ArchiveNode(
          path: path, name: String(path.split(separator: "/").last ?? ""),
          entry: entry, children: entry.isDirectory ? nodes(under: path) : nil)
      }.sorted {
        if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    }
    return nodes(under: "")
  }
}
