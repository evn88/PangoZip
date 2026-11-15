import PangoZipCore
import XCTest

final class DropIslandProximityTests: XCTestCase {
  private let label = CGRect(x: 100, y: 100, width: 138, height: 32)
  private let open = CGRect(x: 0, y: 0, width: 340, height: 168)

  func testDistanceIsZeroInsideAndMeasuredFromNearestEdge() {
    XCTAssertEqual(DropIslandProximity.distance(from: CGPoint(x: 120, y: 110), to: label), 0)
    XCTAssertEqual(DropIslandProximity.distance(from: CGPoint(x: 60, y: 110), to: label), 40)
    XCTAssertEqual(DropIslandProximity.distance(from: CGPoint(x: 97, y: 136), to: label), 5)
  }

  func testIslandOpensOnlyNearLabelEdge() {
    let near = CGPoint(x: label.maxX + 43, y: label.midY)
    let far = CGPoint(x: label.maxX + 44, y: label.midY)
    XCTAssertTrue(DropIslandProximity.isOpen(wasOpen: false, mouse: near, label: label, open: open))
    XCTAssertFalse(DropIslandProximity.isOpen(wasOpen: false, mouse: far, label: label, open: open))
  }

  func testOpenIslandStaysOpenUntilCursorLeavesItsMargin() {
    let inside = CGPoint(x: open.maxX + 30, y: open.midY)
    let outside = CGPoint(x: open.maxX + 31, y: open.midY)
    XCTAssertTrue(
      DropIslandProximity.isOpen(wasOpen: true, mouse: inside, label: label, open: open))
    XCTAssertFalse(
      DropIslandProximity.isOpen(wasOpen: true, mouse: outside, label: label, open: open))
  }
}
