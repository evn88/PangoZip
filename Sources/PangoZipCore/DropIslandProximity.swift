import CoreGraphics
import Foundation

/// Зона срабатывания острова: расстояние считается от края ярлычка, а не от его центра.
public enum DropIslandProximity {
  /// Ближе этого расстояния до края ярлычка остров раскрывается.
  public static let openDistance: CGFloat = 44
  /// Дальше этого расстояния от края площадки остров сворачивается; зазор гасит дрожание.
  public static let closeDistance: CGFloat = 30

  /// Раскрыт ли остров при данном положении курсора; `wasOpen` даёт гистерезис.
  public static func isOpen(wasOpen: Bool, mouse: CGPoint, label: CGRect, open: CGRect) -> Bool {
    wasOpen
      ? distance(from: mouse, to: open) <= closeDistance
      : distance(from: mouse, to: label) < openDistance
  }

  /// Кратчайшее расстояние от точки до прямоугольника; внутри него равно нулю.
  public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }
}
