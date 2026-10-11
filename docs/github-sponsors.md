# GitHub Sponsors для PangoZip

Выбран получатель `evn88`, владелец репозитория `evn88/PangoZip`. Проверка GitHub API 11 октября 2026 года: `hasSponsorsListing: true`, `sponsorsListing.isPublic: true`. GitHub подтвердил публичную ссылку https://github.com/sponsors/evn88. Она настроена в приложении; `.github/FUNDING.yml` связывает репозиторий с `evn88`.

## Настройка владельцем

1. Войти как `evn88`, открыть [GitHub Sponsors](https://github.com/sponsors), нажать `Get sponsored` и выбрать личный аккаунт.
2. Указать Сербию и выбрать выплаты на банковский счёт.
3. Из панели Sponsors открыть `Stripe Connect account`; заполнить данные владельца и счёта. Страна банковского счёта должна совпадать со страной проживания.
4. В `Overview > tax forms` заполнить предложенную налоговую форму. GitHub указывает W-8BEN для физических лиц без резидентства и гражданства США; форму выбирают по фактическому статусу.
5. Включить 2FA, заполнить профиль и нажать `Request approval`.

[Официальная инструкция настройки](https://docs.github.com/en/sponsors/receiving-sponsorships-through-github-sponsors/setting-up-github-sponsors-for-your-personal-account).

Сербия включена в [список поддерживаемых регионов Sponsors](https://docs.github.com/en/sponsors/getting-started-with-github-sponsors/about-github-sponsors). Платёжный профиль Stripe создаётся в рамках GitHub Sponsors. Поддержка выплат через такую платформу отличается от доступности самостоятельного Stripe для приёма платежей: для стран вне списка Full service agreement условия Sponsors описывают Recipient service agreement. [Условия Stripe Connect в программе](https://docs.github.com/en/site-policy/github-terms/github-sponsors-additional-terms).

## Оформление поддержки PangoZip

В Featured work выбрать `evn88/PangoZip`. Рекомендуемый текст профиля:

> Я разрабатываю PangoZip — нативный менеджер архивов для macOS. Ваша поддержка помогает исправлять ошибки, улучшать интеграцию с Finder и добавлять новые возможности. Спасибо за помощь проекту!

Рекомендуемые разовые уровни: $5, $10 и $25. Ежемесячные уровни можно добавить позже. Это предложения по оформлению, а не обязательные условия программы. GitHub задаёт суммы уровней в USD и поддерживает разовые и ежемесячные взносы. [Уровни поддержки](https://docs.github.com/en/sponsors/receiving-sponsorships-through-github-sponsors/about-github-sponsors-for-open-source-contributors).

## Выплаты и расходы

Взносы с личных аккаунтов имеют комиссию GitHub 0%, с организаций — до 6%. [Тарифы](https://docs.github.com/en/sponsors/getting-started-with-github-sponsors/about-github-sponsors).

Все суммы программы выражены в USD; при выплате возможна конвертация. Валюту и доступные банковские реквизиты нужно проверить в мастере подключения, а банковские комиссии — у своего банка. Обещания о получении полной суммы в EUR без конвертации нет.

Условия GitHub предусматривают первоначальный период 60 дней после первого взноса. Затем Stripe Connect обычно инициирует выплаты 22-го числа; даты зависят от страны, календаря и минимального порога трансграничного перевода. Для ACH/wire указан отдельный график и порог $100; этот порог не следует переносить автоматически на любой Stripe Connect аккаунт. [Условия выплат](https://docs.github.com/en/site-policy/github-terms/github-sponsors-additional-terms).

Суммы и ожидаемая выплата доступны в `Your sponsors > Dashboard > Payouts`. [Управление выплатами](https://docs.github.com/en/sponsors/receiving-sponsorships-through-github-sponsors/managing-your-payouts-from-github-sponsors).

## Конфигурация приложения и репозитория

1. Проверить публичную страницу Sponsors для `evn88`: правильный получатель, PangoZip в описании и возможность разового взноса. Платёж для проверки перехода не требуется.
2. Указать проверенный публичный HTTPS-адрес в `PangoZipSupportURL` в `Resources/Info.plist`, выполнить проверки из AGENTS.md и проверить переход из настроек приложения.
3. Добавить `.github/FUNDING.yml` со следующим содержимым:

```yaml
github: evn88
```

4. В настройках репозитория `Settings > General > Features` включить `Sponsorships`; файл должен быть в основной ветке. [Инструкция Sponsor в репозитории](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/displaying-a-sponsor-button-in-your-repository).

Публичный профиль проверен и включён в конфигурацию. Статус банковской и налоговой верификации не проверялся; публичность профиля не подтверждает готовность выплат. Секреты, банковские реквизиты и налоговые формы не хранятся в репозитории. Регистрация, подключение выплат и подача заявки выполняются владельцем в интерфейсе GitHub/Stripe.
