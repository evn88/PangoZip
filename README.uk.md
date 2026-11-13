# PangoZip

[English](README.md) | [Русский](README.ru.md) | [Српски](README.sr.md) | [Українська](README.uk.md)

<img src="Resources/Icons/AppIcon-master.png" width="128" alt="PangoZip: золотистий панголін">

Нативний менеджер архівів для macOS: перегляд вмісту, видобування та редагування окремих файлів.

Остання версія: [завантажити PangoZip](https://github.com/evn88/PangoZip/releases/latest).

Сайт: [pangozip.app](https://pangozip.app).

## Можливості

- Перегляд і видобування ZIP, 7z, RAR, TAR та інших форматів, які підтримує 7-Zip.
- Створення ZIP і 7z, зокрема архівів із паролем.
- Дерево файлів, пошук, налаштовувані стовпці та перетягування між архівом і Finder.
- Редагування файлів у зовнішній програмі з автоматичним збереженням змін в архіві.
- Попередній перегляд архівів клавішею пробілу у Finder та команди пакування й видобування в його контекстному меню.
- Видобування кількох архівів, черга операцій і скасування останньої зміни.
- Автоматичні оновлення з GitHub Releases та інтерфейс 14 мовами.

Змінювати вміст можна в ZIP, 7z і TAR. RAR, багатотомні та саморозпаковувані архіви доступні лише для читання. Підтримка форматів у системному попередньому перегляді може відрізнятися від основної програми: [Quick Look](docs/quick-look.md).

Щоб змінити файл, скористайтеся командою **«Редагувати» (⌘E)**. Після збереження в зовнішньому редакторі PangoZip автоматично оновить архів. Звичайне відкриття файлу створює копію без відстеження змін.

Паролі не зберігаються в налаштуваннях і передаються рушію 7-Zip через стандартне введення, тому не видимі в списку процесів.

## Встановлення

Потрібні **macOS 26+ та Apple Silicon (M1 або новіший)**. Готові збірки для Intel поки не публікуються.

1. Завантажте файл `PangoZip-<version>-arm64.dmg` з [останнього релізу](https://github.com/evn88/PangoZip/releases/latest).
2. Відкрийте образ диска та перетягніть PangoZip у Applications.
3. Від'єднайте образ диска та запустіть програму з Applications.

Якщо меню або попередній перегляд у Finder не з'явилися, увімкніть розширення PangoZip у системних параметрах macOS. У налаштуваннях програми можна вибрати, які типи архівів відкриватимуться в PangoZip.

Відомості про підпис наведено в описі релізу. Збірки без нотаризації Apple можуть блокуватися під час першого запуску. Докладніше про встановлення та видалення: [інструкція](docs/installation.txt).

## Розробка

Програму написано на SwiftUI та AppKit. Потрібні **Xcode 26+ і Swift 6.2+**. Перед змінами прочитайте [AGENTS.md](AGENTS.md).

```sh
git clone https://github.com/evn88/PangoZip.git
cd PangoZip
./scripts/build-app.sh
open build/PangoZip.app
```

Можна відкрити `Package.swift` у Xcode. Рушій 7zz включено до репозиторію; Sparkle завантажується через Swift Package Manager під час першої збірки.

Для перевірки інтеграції з Finder встановіть зібрану програму в `~/Applications` командою `./scripts/install-app.sh --skip-build`.

Перед надсиланням pull request до `main` виконайте збірку та перевірки:

```sh
swift test
swift format lint --strict --recursive Sources FinderExtension QuickLookExtension Tests Tools Package.swift
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

Докладніше: [робота з файлами](docs/file-interactions.md), [локалізація](docs/localization.md), [випуск релізів](docs/github-releases.md), [підпис і нотаризація](docs/notarization.md).

## Зворотний зв'язок

Повідомляйте про помилки та пропозиції в [GitHub Issues](https://github.com/evn88/PangoZip/issues). Укажіть версії PangoZip і macOS, формат архіву та кроки відтворення. Додавайте лише приклади без особистих даних і паролів.

Підтримати розробку можна через [GitHub Sponsors](https://github.com/sponsors/evn88).

## Ліцензія

Власний код і документація PangoZip поширюються за ліцензією [MIT](LICENSE). Вбудовані 7-Zip і Sparkle мають власні ліцензії: [сторонні компоненти, вихідний код та умови розповсюдження](THIRD_PARTY_NOTICES.md).
