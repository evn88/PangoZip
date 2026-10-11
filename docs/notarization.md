# Подпись и нотариализация PangoZip

Сценарий предназначен для выпуска DMG за пределами Mac App Store. Регистрация в App Store не нужна. Нужны активная Apple Developer Program, сертификат **Developer ID Application с приватным ключом** в Keychain и учётные данные сервиса нотариализации. Apple Development и ad hoc не подходят. Сертификат Developer ID Installer нужен для PKG; наш DMG его не использует.

## Однократная настройка

1. Оформите Apple Developer Program, добавьте аккаунт в Xcode → Settings → Accounts и создайте Developer ID Application. Сертификат без соответствующего приватного ключа подписать приложение не сможет.
2. Найдите полное имя сертификата командой `security find-identity -v -p codesigning`.
3. Сохраните доступ к нотариализации в Keychain, запустив интерактивную команду:

   ```sh
   xcrun notarytool store-credentials PangoZip
   ```

   Для Apple Account используйте Apple ID, Team ID и **пароль приложения** (app-specific password), а не основной пароль. Команда проверяет данные перед сохранением. Поддерживается и App Store Connect API key — параметры доступны через `xcrun notarytool store-credentials --help`. Не добавляйте сертификаты, приватные ключи, пароли, `.p12`, `.p8` и файлы с переменными окружения в Git и не передавайте их в чат.

## Выпуск

Перед новым релизом обновите версии и build number согласованно в `Resources/Info.plist`, `Resources/WorkerInfo.plist` и `FinderExtension/Info.plist`, запустите тесты и проверьте работу приложения. На машине сборки нужны macOS 26+, Xcode 26+ (Swift 6.2+) и доступ к Apple, включая сервер временных меток.

```sh
export PANGOZIP_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export PANGOZIP_NOTARY_PROFILE='PangoZip'
./scripts/notarize-release.sh
```

Дальше скрипт:

1. Собирает release и подписывает обе копии `7zz`, worker, программу удаления, Finder Extension и главное приложение, изнутри наружу. Для каждого исполняемого компонента включаются Hardened Runtime и secure timestamp. Sandbox entitlements получает только Finder Extension.
2. Проверяет Developer ID, одну команду подписи, временную метку, Hardened Runtime и целостность вложенных подписей. Ad hoc сборка и чужой сертификат отклоняются.
3. Фиксирует отдельный снимок приложения, чтобы локальные сборки не меняли отправляемый пакет. Отправляет ZIP приложения в Apple через `notarytool`. Только статус `Accepted` разрешает продолжение. Подтверждение прикрепляется к `.app`, проверяется `stapler validate` и Gatekeeper.
4. Создаёт и подписывает DMG с уже подтверждённым приложением, отправляет DMG в Apple, прикрепляет и проверяет подтверждение DMG. Проверяет целостность образа и оценку Gatekeeper.
5. Считает SHA-256 **после** прикрепления подтверждения и публикует результат локально в `build/PangoZip-<version>-<arch>.dmg` и соседний `.dmg.sha256`.

На GitHub скрипт ничего не загружает и тегов не создаёт. Для публикации используйте два итоговых файла и укажите точную версию в релизе. `scripts/package-dmg.sh` сам по себе делает подписанный образ, но не гарантирует нотариализацию — для готового релиза используйте `notarize-release.sh`.

`--skip-build` использует готовое `build/PangoZip.app`, проверяя его подпись тем же сертификатом. Это приложение должно быть заранее собрано через `PANGOZIP_SIGNING_IDENTITY='Developer ID Application: …' scripts/build-app.sh release`. Существующую сборку можно переподписать `scripts/sign-app.sh build/PangoZip.app`; для релиза предпочтительнее чистая release-сборка. Обычная локальная сборка без переменных остаётся ad hoc и не обращается в Apple.

## Ошибка или длительное ожидание

Каждая попытка получает отдельную папку `build/notarization/release.XXXXXX` с закрытым доступом для других пользователей. В ней остаются снимок приложения, отправленный ZIP, ответы Apple, идентификаторы отправок, доступные JSON-журналы и промежуточный DMG. До прохождения всех проверок предыдущий готовый DMG не заменяется. Не публикуйте промежуточные файлы. Папки игнорируются Git вместе с `build/`; после завершения их можно удалить.

По умолчанию ожидание каждой отправки ограничено 30 минутами. Можно задать `PANGOZIP_NOTARY_TIMEOUT=60m`. Тайм-аут не отменяет обработку у Apple. Перед повторным запуском проверьте существующую отправку:

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile PangoZip
xcrun notarytool log SUBMISSION_ID --keychain-profile PangoZip build/notary-log.json
```

Если идентификатор не сохранился из-за сетевого сбоя, используйте `xcrun notarytool history --keychain-profile PangoZip`. При `Invalid` сначала исправьте причину из журнала. При `In Progress` дождитесь результата; повторный запуск сценария делает новую отправку, автоматического возобновления нет. Статус `Accepted` сам по себе не прикрепляет подтверждение к файлу: шаги staple и validate обязательны для нашего сценария выпуска.

Нотариализация не заменяет проверку приложения. После получения сертификата нужно выполнить полный сценарий на реальном сервисе Apple и проверить установку загруженного DMG на чистом Mac: перетаскивание в Applications, запуск, Finder Extension, команды упаковки/извлечения и удаление. Обычное подтверждение первого запуска скачанного приложения может остаться; устраняется предупреждение о непроверенном разработчике при корректной подписи и принятии Apple.

## Проверки без сертификата

```sh
python3 scripts/tests/test_release_scripts.py
swift test
swift format lint --strict --recursive Sources FinderExtension Tests Tools Package.swift
scripts/build-app.sh
scripts/package-dmg.sh --skip-build
```

Автоматические проверки сценариев используют имитации системных утилит: проверяют параметры подписи, порядок операций, остановку при отказе/тайм-ауте и сохранность предыдущего DMG. Они не доказывают принятие сборки Apple. Настоящая нотариализация до получения Developer ID и доступа к сервису не выполнялась.

## Источники Apple

- [Подготовка программы к нотариализации](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Автоматизация: notarytool, Keychain и staple](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Диагностика ошибок подписи и нотариализации](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Apple Developer Program](https://developer.apple.com/programs/)
