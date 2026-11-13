# Services и Quick Actions Finder (облачные папки)

Основное контекстное меню PangoZip строится через Finder Sync: [finder-integration.md](finder-integration.md). В папках File Provider (iCloud Drive, включая синхронизируемые «Рабочий стол» и «Документы», Google Drive и т. п.) Finder не вызывает Finder Sync — это системное ограничение. Там остаются два штатных механизма, которые PangoZip объявляет дополнительно: **Services** и **Quick Actions**. Оба используют тот же путь доставки, что и Finder Sync: `FinderSelection` → `FinderRequest` → `PangoZipWorker`, поэтому операции, имена результатов и защита от перезаписи совпадают с меню Finder Sync.

## Что доступно

| Действие | Services (меню «Службы») | Quick Action (меню «Быстрые действия», панель просмотра) |
| --- | --- | --- |
| Открыть архив в PangoZip | да | нет |
| Добавить в архив PangoZip… (диалог параметров) | да | нет |
| Распаковать здесь | да | да |
| Распаковать в отдельные папки | да | нет |
| Заархивировать в ZIP | да | да |
| Заархивировать в 7z | да | нет |
| Тестировать архив | да | нет |

Пункты Services «Открыть», «Распаковать здесь», «Распаковать в отдельные папки» и «Тестировать» работают только с архивами из выделения; остальные файлы в смешанном выделении пропускаются, как и в меню Finder Sync. Если архивов нет, служба возвращает ошибку и ничего не запускает. Для распаковки и тестирования объявлен `NSSendFileTypes = public.archive`, поэтому macOS предлагает их только для архивов. В Info.plist добавлены импортированные UTI `org.7-zip.7-zip-archive` и `com.rarlab.rar-archive` (расширения 7z и rar), чтобы фильтр работал и на Mac, где система сама их не объявляет. Форматы без системного UTI (zst, wim, rpm, deb, cbz, lzma) фильтр не пропустит — для них используйте «Открыть архив» или Finder Sync.

## Как включить

- **Службы.** Системные настройки → Клавиатура → Сочетания клавиш → Службы → «Файлы и папки»: включите пункты PangoZip. Для каждого можно назначить собственное сочетание клавиш. Пункты появляются в контекстном меню Finder → «Службы».
- **Быстрые действия.** Системные настройки → Расширения → Finder (или «Действия») → включите «Распаковать здесь с PangoZip» и «Заархивировать в ZIP с PangoZip». Порядок и видимость настраиваются в Finder → ПКМ → «Быстрые действия» → «Настроить…». Те же действия доступны на панели просмотра Finder (Вид → Показать просмотр) для выбранного файла.

Нужна установка в `/Applications` или `~/Applications` (`./scripts/install-app.sh`): расширения и службы не работают из временных папок, Корзины и каталога загрузок.

## Реализация Services

Объявлены в `Resources/Info.plist` (`NSServices`), обработчики — `Sources/PangoZipApp/FinderServices.swift`. Каждая служба: `NSRequiredContext = com.apple.finder`, `NSSendTypes = public.file-url, NSFilenamesPboardType`. Названия локализованы в `ServicesMenu.strings` (14 языков, ключ — русское название из Info.plist).

Сервисы принимают современные file URL из pasteboard и резервно читают список путей старого формата. Запросы, пришедшие при холодном запуске до готовности модели, ставятся в очередь и доставляются после `FinderServices.configure`. Приложение назначает экземпляр как `NSApp.servicesProvider`; приём файлов из `open` перенаправляется через `deliverOpenURLs(_:)`. При холодном запуске Services macOS может предварительно открыть главное приложение. Для всех действий кроме «Открыть» основное приложение через `FinderServices.launchWorker` запускает `PangoZipWorker` — тот же механизм, что у «Добавить в архив».

Установщик вызывает `lsregister -f` и `pbs -update` для обновления кэша Services (`pbs` — отладочный инструмент Apple без гарантированного интерфейса; наличие проверяется перед вызовом).

## Реализация Quick Actions

Расширения Action extension: `QuickActionExtension/` (`Info-Extract.plist`, `Info-Zip.plist`, `Entitlements.plist`, `QuickActionHandler.swift`). Собираются в `scripts/build-app.sh` из одного исполняемого файла `PangoZipQuickAction` в два комплекта: `PangoZipQuickExtract.appex` и `PangoZipQuickZip.appex`.

- Точка расширения `com.apple.services` — вариант Action extension «без интерфейса» из шаблона Xcode (`NSExtensionRequestHandling`, без view controller). Вариант `com.apple.ui-services` предназначен для действий с окном и `NSViewController`.
- `NSExtensionServiceAllowsFinderPreviewItem = true`, `NSExtensionServiceRoleType = NSExtensionServiceRoleTypeEditor`, `NSExtensionActivationRule = TRUEPREDICATE` — значения из шаблона Xcode. Ограничение правилом только файлами или архивами не использовано: без живой проверки в Finder оно рискует скрыть пункт совсем. Выбор архива проверяет обработчик: для «Распаковать здесь» без архивов запрос завершается отменой и звуковым сигналом.
- Один appex даёт один пункт, поэтому действий два. Название пункта — `CFBundleDisplayName`; `InfoPlist.strings` для 14 языков build-app.sh генерирует из `ServicesMenu.strings`.
- Песочница как у Finder-расширения (`app-sandbox`, `files.user-selected.read-only`). Обработчик читает `public.file-url` из `NSExtensionContext.inputItems`, строит `FinderRequest` через `QuickAction.request(for:)` (`Sources/PangoZipCore/QuickAction.swift`), кладёт его в именованный pasteboard и открывает `PangoZipWorker.app` по `pangozip-worker://finder?request=UUID`. После запуска вызывается `completeRequest`; при ошибке — `cancelRequest`.
- Регистрация: `FinderRegistration` добавляет оба appex в план (`pluginkit -a`, включение остаётся за пользователем), `install-app.sh` дополнительно включает их, `check-finder-integration.sh` читает их статус, `Uninstall.swift` отключает и снимает регистрацию.

Живая проверка в Finder (появление пунктов, названия, значок, поведение в iCloud Drive) на момент написания не проводилась.

## Установка

```sh
./scripts/install-app.sh
```

Установщик собирает Release-сборку и устанавливает её в `~/Applications/PangoZip.app`. Для готовой сборки: `./scripts/install-app.sh --skip-build`. Другой путь указывается последним аргументом. Установщик не требует `sudo` и отказывается заменять элемент с иным bundle identifier, чем `app.pangozip.desktop`.

Источники: [Apple: Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html), [Apple: App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/index.html), [NSExtensionServiceFinderPreviewIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionservicefinderpreviewiconname), шаблон «Action Extension» в Xcode (`Templates/Project Templates/macOS/Application Extension`), [обсуждение отладки Finder Actions](https://developer.apple.com/forums/thread/723665).
