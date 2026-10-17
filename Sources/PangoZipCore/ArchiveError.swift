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
    case .engineUnavailable:
      L10n.tr("Не найден движок 7zz. Соберите приложение через scripts/build-app.sh.")
    case .passwordRequired: L10n.tr("Для чтения архива или файла нужен правильный пароль.")
    case .invalidArchive:
      L10n.tr("Не удалось прочитать архив. Возможно, формат не поддерживается или файл повреждён.")
    case .malformedListing:
      L10n.tr("Список файлов архива имеет неподдерживаемый или неоднозначный формат.")
    case .unsafePath: L10n.tr("В архиве найден небезопасный путь. Открытие остановлено.")
    case .duplicatePath: L10n.tr("Архив содержит неоднозначные имена файлов. Открытие остановлено.")
    case .unsupportedExtraction:
      L10n.tr("Извлечение ссылок и специальных файлов пока не поддерживается.")
    case .unsupportedEntry: L10n.tr("Предпросмотр ссылок, папок и специальных файлов недоступен.")
    case .fileTooLarge: L10n.tr("Файл превышает лимит предпросмотра 200 МБ.")
    case .outputLimit: L10n.tr("Движок превысил допустимый объём данных. Операция остановлена.")
    case .timedOut: L10n.tr("Обработка архива заняла больше двух минут. Операция остановлена.")
    case .archiveChanged: L10n.tr("Архив изменился на диске. Откройте его заново.")
    case .extractionMismatch: L10n.tr("Не удалось однозначно извлечь выбранный файл.")
    case .readOnlyArchive:
      L10n.tr(
        "Этот формат архива доступен только для чтения. Изменение поддерживается для ZIP, 7z и TAR."
      )
    case .operationInProgress: L10n.tr("Другая операция с архивом ещё выполняется.")
    case .invalidOperation: L10n.tr("Операция не может быть выполнена с выбранными файлами.")
    case .activeEdits:
      L10n.tr("Сначала сохраните или завершите редактирование затрагиваемых файлов.")
    case .editedFileChanged:
      L10n.tr(
        "Рабочий файл изменился во время сохранения. Повторите сохранение после завершения работы редактора."
      )
    case .sessionExpired: L10n.tr("Сеанс архива завершён. Откройте архив заново.")
    }
  }
}
