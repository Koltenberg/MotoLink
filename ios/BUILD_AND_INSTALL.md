# Сборка и установка MotoLink на свой iPhone

В архиве находится исходный проект. Готовым установщиком он не является. Скрипт ниже должен сначала успешно выполниться на macOS с Xcode; затем unsigned IPA необходимо подписать для личного iPhone.

## Если есть Windows, но нет Mac

1. Создать приватный репозиторий GitHub и загрузить **содержимое папки MotoLink в его корень**, сохранив `.github`, `ios`, `core`, `scripts`, `tests` и файлы лицензий. Не загружать личные журналы и идентификаторы байка. После загрузки должны существовать `.github/workflows/ios-build.yml` и `ios/MotoLink.xcodeproj`.
2. В GitHub открыть Actions → **Build unsigned iPhone IPA** → Run workflow. Запуск ручной; Apple-пароль и сертификаты не требуются. После зелёного результата скачать артефакт **MotoLink-unsigned-iPhone-…** и извлечь `MotoLink-unsigned.ipa` из ZIP. При красном результате скачать build-logs и сначала устранить ошибку — переименование ZIP в IPA сборку не заменяет.
3. Установить [Sideloadly с официального сайта](https://sideloadly.io/) и его Apple-компоненты для Windows. Подключить разблокированный iPhone USB-кабелем, подтвердить доверие компьютеру. Выбрать IPA и собственный Apple Account в Sideloadly, запустить установку. Логин, пароль и код подтверждения вводить только локально в программе/окне Apple, не отправлять в чат или в CI.
4. Выполнить указания iPhone о доверии профилю и Developer Mode: Настройки → Конфиденциальность и безопасность → Режим разработчика. При включении система перезапустит устройство и запросит подтверждение. [Инструкция Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/).
5. Дома открыть MotoLink, проверить экспорт журнала, закрыть обычным переходом на домашний экран и открыть снова. После этого проводить проверку у мотоцикла. Сборка в simulator подтверждает компиляцию; подключения к реальному BLE в CI нет.

Бесплатная личная подпись действует **7 дней**. Sideloadly может обновлять её с работающего ПК; беспроводному обновлению нужны предварительное USB-сопряжение и общая сеть. Не рассчитывать на продление без компьютера. Сам MotoLink после установки подключается к мотоциклу напрямую: ПК нужен для установки/обновления подписи. [Sideloadly](https://sideloadly.io/), [ограничения Apple Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account).

Стандартные GitHub macOS runners доступны в пределах квоты аккаунта; её остаток здесь не проверен. Workflow запускается вручную, ограничен 25 минутами и хранит артефакты 3 дня. Не включать paid larger runners. При настроенной оплате контролировать квоту/лимит расходов; без платёжного метода GitHub блокирует превышение. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

## Если доступен Mac

Для прямой установки открыть `ios/MotoLink.xcodeproj`, выбрать Team в Signing & Capabilities и iPhone как run destination, затем Run. Для получения unsigned IPA без Apple-аккаунта в CI выполнить из корня MotoLink:

```bash
chmod +x scripts/build-ios.sh
./scripts/build-ios.sh
```

Нужны полный Xcode с iOS SDK и Python 3. Скрипт проверяет Python-валидатор пакета, выполняет Swift-тесты протокольного ядра (`core/Package.swift`), собирает Release для simulator, затем отдельно Release для физического iPhone. `--skip-simulator` отключает только simulator-сборку. `--output /путь/к/результатам` меняет папку результатов. Каждый запуск получает отдельную папку; предыдущие `.app` не используются.

## Что проверяет пакет

- ZIP/CRC, единственный `Payload/*.app`, корректный plist и наличие указанного в `CFBundleExecutable` файла.
- Тип Mach-O executable, архитектуру arm64 и платформу **iOS**, чтобы случайно не выдать arm64 simulator build за iPhone build.
- Bluetooth permission, `bluetooth-central`, включённый в пакет PrivacyInfo.xcprivacy.
- Отсутствие provisioning profile и ресурсной подписи в unsigned артефакте.
- SHA-256 готового IPA и машинный отчёт `package-validation.json`.

Повторная проверка архива работает на macOS, Windows и Linux с Python 3:

```bash
python3 scripts/validate-ipa.py /path/to/MotoLink-unsigned.ipa
```

В Windows имя команды может быть `py -3` вместо `python3`. Валидатор не подписывает IPA и не доказывает работу интерфейса, Bluetooth или фонового восстановления. У приложения пока нет отдельного XCTest target; simulator build не называется тестированием поведения. Swift Package tests проверяют декодер на фикстурах отдельно от iOS UI и транспорта.

## Подпись и entitlements

Workflow передаёт `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, пустые identity и team. Он не включает `-allowProvisioningUpdates` и не использует секреты Apple. `UIBackgroundModes` и usage descriptions находятся в Info.plist; это не сертификат и не provisioning profile. Итоговую подпись, application identifier и профиль устройства добавляет локальный инструмент установки.

Если позже появятся Push/iCloud/App Groups или другие возможности с отдельными entitlements, этот простой путь нужно проверить заново. Сейчас успех будущего CI/подписи не заявлен: в доступной Linux-среде Xcode отсутствует.
