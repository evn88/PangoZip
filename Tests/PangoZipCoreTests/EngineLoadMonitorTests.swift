import XCTest

@testable import PangoZipCore

final class EngineLoadMonitorTests: XCTestCase {
  /// Нехватка процессора — это занятые другими программами ядра, а не медленный диск.
  func testContentionNeedsBusyProcessorAndStrongerNeighbours() {
    XCTAssertTrue(
      EngineLoadMonitor.isContended(
        engineCores: 0.1, otherCores: 7.8, idleCores: 0.1, processors: 8))
    // Движок получает больше остальных: он не уступает.
    XCTAssertFalse(
      EngineLoadMonitor.isContended(
        engineCores: 5, otherCores: 3, idleCores: 0, processors: 8))
    // Ядра свободны: движок ждёт диск, а не процессор.
    XCTAssertFalse(
      EngineLoadMonitor.isContended(
        engineCores: 0.2, otherCores: 2, idleCores: 5.8, processors: 8))
    XCTAssertFalse(
      EngineLoadMonitor.isContended(
        engineCores: 0.1, otherCores: 0.6, idleCores: 0.3, processors: 1))
  }

  /// Состояние включается после двух замеров подряд и выключается сразу.
  func testYieldingTurnsOnAfterTwoReadingsAndOffAfterOne() {
    var monitor = EngineLoadMonitor()
    var reading = EngineLoadMonitor.Reading(
      uptime: 0, engineSeconds: 0, busySeconds: 0, idleSeconds: 0)
    /// Сдвигает счётчики на три секунды работы восьми ядер.
    func advance(engine: Double, other: Double) -> Bool {
      reading.uptime += 3
      reading.engineSeconds += engine * 3
      reading.busySeconds += (engine + other) * 3
      reading.idleSeconds += (8 - engine - other) * 3
      return monitor.record(reading, processors: 8)
    }
    XCTAssertFalse(monitor.record(reading, processors: 8))
    XCTAssertFalse(advance(engine: 0.1, other: 7.9))
    XCTAssertFalse(monitor.isYielding)
    XCTAssertTrue(advance(engine: 0.1, other: 7.9))
    XCTAssertTrue(monitor.isYielding)
    XCTAssertFalse(advance(engine: 0.2, other: 7.8))
    XCTAssertTrue(advance(engine: 7, other: 0.5))
    XCTAssertFalse(monitor.isYielding)
  }

  /// Счётчики текущего процесса и системы читаются и не убывают.
  func testReadingReportsLiveCounters() throws {
    let first = try XCTUnwrap(EngineLoadMonitor.read(processes: [getpid()]))
    var sum = 0.0
    for index in 0..<2_000_000 { sum += Double(index).squareRoot() }
    XCTAssertGreaterThan(sum, 0)
    let second = try XCTUnwrap(EngineLoadMonitor.read(processes: [getpid()]))
    XCTAssertGreaterThan(first.engineSeconds, 0)
    XCTAssertGreaterThanOrEqual(second.engineSeconds, first.engineSeconds)
    XCTAssertGreaterThan(second.busySeconds + second.idleSeconds, 0)
  }
}
