import Darwin
import Foundation

/// Замечает, что движок почти не получает процессор, потому что его заняли другие программы.
/// Движок работает классом utility и уступает сам; монитор только объясняет это пользователю.
struct EngineLoadMonitor {
  /// Интервал между замерами: чаще нет смысла, счётчики системы обновляются сотыми долями секунды.
  static let interval: TimeInterval = 3

  /// Накопленное процессорное время движка и всей системы на момент замера.
  struct Reading: Equatable {
    var uptime: TimeInterval
    var engineSeconds: Double
    var busySeconds: Double
    var idleSeconds: Double
  }

  private var previous: Reading?
  private var streak = 0
  private(set) var isYielding = false

  /// Процессор считается занятым другими, когда свободных ядер почти нет,
  /// а остальные программы тратят больше движка и не меньше одного ядра.
  static func isContended(
    engineCores: Double, otherCores: Double, idleCores: Double, processors: Int
  ) -> Bool {
    idleCores < max(0.5, Double(processors) * 0.1) && otherCores >= 1 && otherCores > engineCores
  }

  /// Учитывает новый замер и сообщает, изменилось ли состояние.
  /// Включается после двух подряд замеров с нехваткой процессора, выключается после первого без неё.
  mutating func record(_ reading: Reading, processors: Int) -> Bool {
    defer { previous = reading }
    guard let previous, reading.uptime - previous.uptime >= 0.5 else { return false }
    let span = reading.uptime - previous.uptime
    let engine = max(0, reading.engineSeconds - previous.engineSeconds) / span
    let busy = max(0, reading.busySeconds - previous.busySeconds) / span
    let idle = max(0, reading.idleSeconds - previous.idleSeconds) / span
    let contended = Self.isContended(
      engineCores: engine, otherCores: max(0, busy - engine), idleCores: idle,
      processors: processors)
    streak = contended ? streak + 1 : 0
    let next = streak >= 2
    guard next != isYielding else { return false }
    isYielding = next
    return true
  }

  /// Снимает счётчики запущенных этапов и системы; nil, если система их не отдала.
  static func read(processes: [pid_t]) -> Reading? {
    guard let host = hostSeconds() else { return nil }
    let engine = processes.reduce(0.0) { $0 + (processSeconds($1) ?? 0) }
    return Reading(
      uptime: ProcessInfo.processInfo.systemUptime, engineSeconds: engine,
      busySeconds: host.busy, idleSeconds: host.idle)
  }

  /// Процессорное время процесса; система отдаёт его в единицах mach, а не в наносекундах.
  private static func processSeconds(_ process: pid_t) -> Double? {
    var info = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(process, RUSAGE_INFO_V2, $0)
      }
    }
    guard status == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
    let units = Double(info.ri_user_time) + Double(info.ri_system_time)
    return units * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
  }

  /// Занятое и свободное время всех ядер; счётчики системы идут сотыми долями секунды.
  private static func hostSeconds() -> (busy: Double, idle: Double)? {
    var load = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let status = withUnsafeMutablePointer(to: &load) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    let ticks = Double(sysconf(_SC_CLK_TCK))
    guard ticks > 0 else { return nil }
    // Порядок счётчиков: user, system, idle, nice.
    let busy = Double(load.cpu_ticks.0) + Double(load.cpu_ticks.1) + Double(load.cpu_ticks.3)
    return (busy / ticks, Double(load.cpu_ticks.2) / ticks)
  }
}
