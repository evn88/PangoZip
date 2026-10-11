import Darwin
import Foundation

func run(_ executable: String, _ arguments: [String], required: Bool = true) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  if required && process.terminationStatus != 0 {
    throw NSError(
      domain: "app.pangozip.uninstall", code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "Не удалось отменить системную регистрацию PangoZip."])
  }
}

func refuse(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard Bundle(url: app)?.bundleIdentifier == "app.pangozip.desktop" else {
  refuse("Программа удаления должна находиться внутри PangoZip.app.")
}
let registrar =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
let worker = app.appendingPathComponent("Contents/Helpers/PangoZipWorker.app")
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
  refuse("Не удалось проверить работающие операции PangoZip.")
}
let executables = [
  app.appendingPathComponent("Contents/MacOS/PangoZip").path,
  worker.appendingPathComponent("Contents/MacOS/PangoZip").path,
]
if processes.contains(where: { executables.contains($0.command) }) {
  refuse(
    "Сначала закройте PangoZip и дождитесь завершения фоновых операций, затем повторите удаление.")
}

do {
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
  var trash: NSURL?
  try FileManager.default.trashItem(at: app, resultingItemURL: &trash)
  try run("/System/Library/CoreServices/pbs", ["-update"], required: false)
  print("PangoZip перемещён в Корзину. Расширение Finder отключено. Настройки сохранены.")
} catch {
  // При любой ошибке до перемещения возвращаем регистрацию приложения.
  if FileManager.default.fileExists(atPath: app.path) {
    try? run(registrar, ["-f", app.path])
    try? run(registrar, ["-f", worker.path])
    try? run("/usr/bin/pluginkit", ["-a", extensionURL.path])
    try? run("/usr/bin/pluginkit", ["-e", "use", "-i", "app.pangozip.desktop.finder"])
  }
  refuse(error.localizedDescription)
}
