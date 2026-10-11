import XCTest

@testable import PangoZipApp

final class SupportConfigurationTests: XCTestCase {
  /// В сборке без реальной страницы не появляется кнопка с подставным адресом.
  func testMissingOrEmptyConfigurationDisablesSupport() {
    XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: nil))
    XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: [:]))
    for value: Any in ["", " \n", 42] {
      XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: ["PangoZipSupportURL": value]))
    }
  }

  /// Сохраняет путь и параметры платёжной страницы без добавления суммы или идентификаторов.
  func testHTTPSPagePreservesPaymentParameters() {
    let address = "https://support.example.test/pangozip?currency=EUR&amount=5#support"
    let url = SupportConfiguration.pageURL(infoDictionary: ["PangoZipSupportURL": address])
    XCTAssertEqual(url?.absoluteString, address)
  }

  /// Допускает пробелы вокруг скопированной ссылки, но только HTTPS-схему.
  func testWhitespaceAroundHTTPSPageIsTrimmed() {
    let url = SupportConfiguration.pageURL(
      infoDictionary: ["PangoZipSupportURL": " \nhttps://support.example.test/pangozip\n "])
    XCTAssertEqual(url?.absoluteString, "https://support.example.test/pangozip")
  }

  /// Отклоняет локальные команды, HTTP, относительные адреса и встроенные учётные данные.
  func testUnsafeOrMalformedPagesDisableSupport() {
    for address in [
      "http://support.example.test", "file:///tmp/support", "javascript:alert(1)",
      "pangozip://support", "/support", "https://", "https:///support",
      "https://user@support.example.test", "https://user:password@support.example.test",
    ] {
      XCTAssertNil(
        SupportConfiguration.pageURL(infoDictionary: ["PangoZipSupportURL": address]), address)
    }
  }
}
