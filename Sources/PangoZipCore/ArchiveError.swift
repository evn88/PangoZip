import Foundation

public enum ArchiveError: LocalizedError, Equatable, Sendable {
  case engineUnavailable
  case passwordRequired
  case invalidArchive
  case malformedListing
  case unsafePath
  case duplicatePath
  case unsupportedExtraction
  case unsupportedEntry
  case fileTooLarge
  case outputLimit
  case timedOut
  case archiveChanged
  case extractionMismatch
  case sessionExpired
  case readOnlyArchive
  case operationInProgress
  case invalidOperation
  case activeEdits
  case editedFileChanged

  public var errorDescription: String? {
    switch self {
    case .engineUnavailable: "Не найден движок 7zz. Соберите приложение через scripts/build-app.sh."
    case .passwordRequired: "Для чтения архива или файла нужен правильный пароль."
    case .invalidArchive:
      "Не удалось прочитать архив. Возможно, формат не поддерживается или файл повреждён."
    case .malformedListing: "Список файлов архива имеет неподдерживаемый или неоднозначный формат."
    case .unsafePath: "В архиве найден небезопасный путь. Открытие остановлено."
    case .duplicatePath: "Архив содержит неоднозначные имена файлов. Открытие остановлено."
    case .unsupportedExtraction: "Извлечение ссылок и специальных файлов пока не поддерживается."
    case .unsupportedEntry: "Предпросмотр ссылок, папок и специальных файлов недоступен."
    case .fileTooLarge: "Файл превышает лимит предпросмотра 200 МБ."
    case .outputLimit: "Движок превысил допустимый объём данных. Операция остановлена."
    case .timedOut: "Обработка архива заняла больше двух минут. Операция остановлена."
    case .archiveChanged: "Архив изменился на диске. Откройте его заново."
    case .extractionMismatch: "Не удалось однозначно извлечь выбранный файл."
    case .readOnlyArchive:
      "Этот формат архива доступен только для чтения. Изменение поддерживается для ZIP, 7z и TAR."
    case .operationInProgress: "Другая операция с архивом ещё выполняется."
    case .invalidOperation: "Операция не может быть выполнена с выбранными файлами."
    case .activeEdits: "Сначала сохраните или завершите редактирование затрагиваемых файлов."
    case .editedFileChanged:
      "Рабочий файл изменился во время сохранения. Повторите сохранение после завершения работы редактора."
    case .sessionExpired: "Сеанс архива завершён. Откройте архив заново."
    }
  }
}
