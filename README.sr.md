# PangoZip

[English](README.md) | [Русский](README.ru.md) | [Српски](README.sr.md) | [Українська](README.uk.md)

<img src="Resources/Icons/AppIcon-master.png" width="128" alt="PangoZip: златни панголин">

Нативни менаџер архива за macOS: преглед садржаја, распакивање и уређивање појединачних датотека.

Најновија верзија: [преузмите PangoZip](https://github.com/evn88/PangoZip/releases/latest).

Сајт: [pangozip.app](https://pangozip.app).

## Могућности

- Преглед и распакивање ZIP, 7z, RAR, TAR и других формата које подржава 7-Zip.
- Прављење ZIP и 7z архива, укључујући архиве заштићене лозинком.
- Стабло датотека, претрага, подесиве колоне и превлачење датотека између архиве и Finder-а.
- Уређивање датотека у спољној апликацији уз аутоматско чување измена у архиви.
- Преглед архива притиском на размакницу у Finder-у и команде за паковање и распакивање у његовом контекстном менију.
- Распакивање више архива, ред операција и поништавање последње измене.
- Аутоматско ажурирање преко GitHub Releases и интерфејс на 14 језика.

Измене садржаја подржане су за ZIP, 7z и TAR. RAR, вишетомне и самораспакујуће архиве могу само да се читају. Подршка за формате у системском прегледу може да се разликује од главне апликације: [Quick Look](docs/quick-look.md).

За измену датотеке користите **„Уреди“ (⌘E)**. Када сачувате датотеку у спољном уређивачу, PangoZip аутоматски ажурира архиву. Обично отварање датотеке прави копију без праћења измена.

Лозинке се не чувају у подешавањима и прослеђују се 7-Zip мотору преко стандардног улаза, па нису видљиве у списку процеса.

## Инсталација

Потребни су **macOS 26+ и Apple Silicon (M1 или новији)**. Готове верзије за Intel још се не објављују.

1. Преузмите `PangoZip-<version>-arm64.dmg` из [најновијег издања](https://github.com/evn88/PangoZip/releases/latest).
2. Отворите слику диска и превуците PangoZip у Applications.
3. Избаците слику диска и покрените апликацију из Applications.

Ако се мени или преглед у Finder-у не појаве, омогућите PangoZip проширења у системским подешавањима macOS-а. У подешавањима апликације можете да изаберете које типове архива ће отварати PangoZip.

Подаци о потпису наведени су у опису издања. Верзије без Apple нотаризације могу бити блокиране при првом покретању. Детаљи о инсталацији и уклањању: [упутство](docs/installation.txt).

## Развој

Апликација је написана помоћу SwiftUI и AppKit. Потребни су **Xcode 26+ и Swift 6.2+**. Пре измена прочитајте [AGENTS.md](AGENTS.md).

```sh
git clone https://github.com/evn88/PangoZip.git
cd PangoZip
./scripts/build-app.sh
open build/PangoZip.app
```

Можете да отворите `Package.swift` у Xcode-у. Механизам 7zz је укључен у репозиторијум; Sparkle се преузима преко Swift Package Manager-а при првој изградњи.

За проверу интеграције са Finder-ом инсталирајте изграђену апликацију у `~/Applications` командом `./scripts/install-app.sh --skip-build`.

Пре слања pull request-а у `main`, покрените изградњу и провере:

```sh
swift test
swift format lint --strict --recursive Sources FinderExtension QuickLookExtension Tests Tools Package.swift
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

Детаљи: [рад са датотекама](docs/file-interactions.md), [локализација](docs/localization.md), [објављивање издања](docs/github-releases.md), [потписивање и нотаризација](docs/notarization.md).

## Повратне информације

Пријавите грешке и предлоге преко [GitHub Issues](https://github.com/evn88/PangoZip/issues). Наведите верзије PangoZip-а и macOS-а, формат архиве и кораке за репродуковање проблема. Прилажите само примере без личних података и лозинки.

Развој можете подржати преко [GitHub Sponsors](https://github.com/sponsors/evn88).

## Лиценца

Сопствени код и документација PangoZip-а доступни су под [MIT лиценцом](LICENSE). Уграђени 7-Zip и Sparkle имају своје лиценце: [компоненте трећих страна, изворни код и услови дистрибуције](THIRD_PARTY_NOTICES.md).
