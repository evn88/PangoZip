import Darwin
import Foundation

/// Пустой файл под будущим именем архива с опубликованным системным прогрессом.
/// Finder показывает такой файл серым, рисует круговой индикатор в колонке статуса списка
/// и полоску на иконке — так же, как во время работы системной «Утилиты архивов».
final class FinderFileProgress: @unchecked Sendable {
  private struct Placeholder {
    let url: URL
    let device: dev_t
    let inode: ino_t
  }

  private static let scale: Int64 = 10_000
  private let lock = NSLock()
  private var progress: Progress?
  private var placeholder: Placeholder?

  init() {}

  /// Занимает свободное имя пустым файлом и публикует для него прогресс.
  /// Возвращает имя, под которым нужно опубликовать готовый архив, или nil, если место не занято:
  /// архив тогда создаётся как раньше, просто без индикатора в Finder.
  func reserve(proposed: URL, format: String, volumes: Bool, sources: [URL]) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    guard placeholder == nil, proposed.isFileURL else { return nil }
    let parent = proposed.deletingLastPathComponent()
    // Пустой файл внутри выбранной папки попал бы в собственный архив.
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for source in sources {
      let resolved = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
      if resolvedParent.hasPrefix(resolved) { return nil }
    }
    let name = proposed.lastPathComponent
    let ending = "." + format
    let suffix: String
    if name.lowercased().hasSuffix(ending.lowercased()), name.count > ending.count {
      suffix = String(name.suffix(ending.count))
    } else {
      suffix = proposed.pathExtension.isEmpty ? "" : "." + proposed.pathExtension
    }
    let stem = String(name.dropLast(suffix.count))
    for number in 1...10_000 {
      // Набор томов начинается с «.001»: Finder показывает прогресс на первом томе.
      let candidate = stem + (number == 1 ? "" : " (\(number))") + suffix
      let target = parent.appendingPathComponent(candidate)
      let file = volumes ? URL(fileURLWithPath: target.path + ".001") : target
      let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
      if fd < 0 {
        if errno == EEXIST { continue }
        return nil
      }
      var info = stat()
      let described = fstat(fd, &info) == 0
      close(fd)
      guard described else {
        unlink(file.path)
        return nil
      }
      // Папки под наблюдением не должны принимать пустой файл за новый архив.
      OwnOutputRegistry.shared.register(file)
      placeholder = Placeholder(url: file, device: info.st_dev, inode: info.st_ino)
      let item = Progress(parent: nil, userInfo: nil)
      item.totalUnitCount = Self.scale
      item.completedUnitCount = 0
      item.kind = .file
      item.fileURL = file
      item.fileOperationKind = .copying
      item.isCancellable = false
      item.isPausable = false
      item.publish()
      progress = item
      return target
    }
    return nil
  }

  /// Переносит долю, скорость и счётчики операции в опубликованный прогресс.
  func update(_ state: ArchiveProgress) {
    lock.lock()
    defer { lock.unlock() }
    guard let progress else { return }
    if let fraction = state.fraction {
      let completed = Int64((fraction * Double(Self.scale)).rounded(.down))
      // Finder не должен видеть, как индикатор отходит назад между этапами.
      if completed > progress.completedUnitCount {
        progress.completedUnitCount = min(Self.scale, completed)
      }
    }
    progress.throughput = state.bytesPerSecond.map { Int(min($0, Double(Int.max))) }
    progress.estimatedTimeRemaining = state.remainingSeconds
    progress.fileTotalCount = state.totalFiles
    progress.fileCompletedCount = state.completedFiles
  }

  /// Снимает прогресс и удаляет пустой файл, если на его месте всё ещё он сам.
  /// Вызывается перед публикацией архива и при любом выходе; повторный вызов ничего не делает.
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    progress?.unpublish()
    progress = nil
    guard let placeholder else { return }
    self.placeholder = nil
    var info = stat()
    guard lstat(placeholder.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_dev == placeholder.device, info.st_ino == placeholder.inode, info.st_size == 0
    else { return }
    unlink(placeholder.url.path)
  }

  deinit { finish() }
}
