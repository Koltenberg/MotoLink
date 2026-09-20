# Проверка MotoLink 0.1

Дата: 20 сентября 2026. Работа выполнена в Linux без доступа к мотоциклу.

| Проверка | Результат |
|---|---|
| JavaScript syntax: app.js, protocol.js | PASS |
| Разбор известных кадров, усечений, all-FF/не готовых capabilities, ACK, allowlist | 6/6 PASS |
| Mock BLE: 3 подписки, отказ подписки, ранний response, ACK без данных, disconnect, постоянное сохранение | 6/6 PASS |
| Локальные ссылки статического сайта | PASS |
| Публикация приватной страницы | succeeded |
| Upstream Python tests | 9/9 PASS |
| Публичные fixtures: length=payloadLength+3 | 49/49 PASS |
| Нативные Info.plist, PrivacyInfo.xcprivacy, shared scheme XML | PASS |
| Нативный pbxproj: 29 объектов, ссылки на Swift | Статическая проверка пройдена |
| Xcode compilation, signing, установка IPA | НЕ ВЫПОЛНЕНО, нет Xcode/iOS SDK |
| Визуальная проверка в браузере/Bluefy | НЕ ВЫПОЛНЕНО, нет доступного совместимого предпросмотра |
| Фактический BLE обмен, pairing, background на iPhone | НЕ ВЫПОЛНЕНО, нужен телефон у байка |

Node тесты используют настоящий код страницы и имитацию периферии. Они проверяют
логику, но не возможности Bluefy, радиоканала, iOS или конкретной приборки.
Публичные образцы исходного проекта принадлежат Z500, не мотоциклу пользователя.
Нет реального upstream fixture потока0x4A; арифметические synthetic samples не
доказывают измерение RPM/скорости на EX500G.

В нативном проекте предусмотрены state restoration и pending connection, но
это архитектура, а не пройденное фоновое испытание. Проверка на телефоне описана
в README.md и ios/DEVELOPER_NOTES.md.

Web source commit: a7627a754b06ffecbb7df51e69d652be85a781b3.
Адрес: https://motolink-ex500g-lab.koltenberg.chatgpt.site
