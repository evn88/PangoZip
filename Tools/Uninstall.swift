import Darwin
import Foundation

/// Выполняет системную регистрацию без shell и отклоняет обязательные неуспешные команды.
func run(_ executable: String, _ arguments: [String], required: Bool = true) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  if required && process.terminationStatus != 0 {
    throw NSError(
      domain: "app.pangozip.uninstall", code: Int(process.terminationStatus),
      userInfo: [
        NSLocalizedDescriptionKey: L10n.tr("Не удалось отменить системную регистрацию PangoZip.")
      ])
  }
}

/// Завершает удаление до изменения приложения, оставляя диагностическое сообщение в stderr.
func refuse(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard Bundle(url: app)?.bundleIdentifier == "app.pangozip.desktop" else {
  refuse(L10n.tr("Программа удаления должна находиться внутри PangoZip.app."))
}
let registrar =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
let worker = app.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
let previewURL = app.appendingPathComponent("Contents/PlugIns/PangoZipPreview.appex")
let extensionURL = app.appendingPathComponent("Contents/PlugIns/PangoZipFinderSync.appex")

// Не прерываем редактирование или операцию с архивом при удалении.
let running = Process()
running.executableURL = URL(fileURLWithPath: "/bin/ps")
running.arguments = ["-axo", "pid=,comm="]
let pipe = Pipe()
running.standardOutput = pipe
try running.run()
let processes = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  .split(separator: "\n").compactMap { line -> (pid: Int32, command: String)? in
    let parts = line.trimmingCharacters(in: .whitespaces).split(
      maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
    return (pid, String(parts[1]).trimmingCharacters(in: .whitespaces))
  }
running.waitUntilExit()
guard running.terminationStatus == 0 else {
  refuse(L10n.tr("Не удалось проверить работающие операции PangoZip."))
}
let executables = [
  app.appendingPathComponent("Contents/MacOS/PangoZip").path,
  worker.appendingPathComponent("Contents/MacOS/PangoZip").path,
  previewURL.appendingPathComponent("Contents/MacOS/PangoZipPreview").path,
]
if processes.contains(where: { executables.contains($0.command) }) {
  refuse(
    L10n.tr(
      "Сначала закройте PangoZip и дождитесь завершения фоновых операций, затем повторите удаление."
    ))
}

do {
  if FileManager.default.fileExists(atPath: previewURL.path) {
    try run("/usr/bin/pluginkit", ["-e", "ignore", "-i", "app.pangozip.desktop.preview"])
    try run("/usr/bin/pluginkit", ["-r", previewURL.path], required: false)
  }
  try run("/usr/bin/pluginkit", ["-e", "ignore", "-i", "app.pangozip.desktop.finder"])
  try run("/usr/bin/pluginkit", ["-r", extensionURL.path], required: false)
  for process in processes
  where process.command
    == extensionURL.appendingPathComponent("Contents/MacOS/PangoZipFinderSync").path
  {
    Darwin.kill(process.pid, SIGTERM)
  }
  try run(registrar, ["-u", worker.path], required: false)
  try run(registrar, ["-u", app.path], required: false)
  // После перемещения комплекта его каталоги переводов уже недоступны.
  let successMessage = L10n.tr(
    "PangoZip перемещён в Корзину. Расширение Finder отключено. Настройки сохранены.")
  var trash: NSURL?
  try FileManager.default.trashItem(at: app, resultingItemURL: &trash)
  try run("/System/Library/CoreServices/pbs", ["-update"], required: false)
  print(successMessage)
} catch {
  // При любой ошибке до перемещения возвращаем регистрацию приложения.
  if FileManager.default.fileExists(atPath: app.path) {
    try? run(registrar, ["-f", app.path])
    try? run(registrar, ["-f", worker.path])
    if FileManager.default.fileExists(atPath: previewURL.path) {
      try? run("/usr/bin/pluginkit", ["-a", previewURL.path])
      try? run("/usr/bin/pluginkit", ["-e", "use", "-i", "app.pangozip.desktop.preview"])
    }
    try? run("/usr/bin/pluginkit", ["-a", extensionURL.path])
    try? run("/usr/bin/pluginkit", ["-e", "use", "-i", "app.pangozip.desktop.finder"])
  }
  refuse(error.localizedDescription)
}
