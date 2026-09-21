# Kawasaki / Moto Link: расширенная проверка источников

Проверено 21 сентября 2026. Это исследование источников, не результат нового дорожного испытания. Внешние приложения не устанавливались, команды мотоциклу не отправлялись, личные журналы наружу не передавались. Исходники Moto Link этим исследованием не изменены.

## 1. Главное новое подтверждение: у EX500G есть ограниченное окно обнаружения

Официальное руководство Kawasaki **99805-0653, 2024 Street Motorcycle General Owner's Manual**, раздел **Meter Instruments (ER500E/EX500G)**, печатные страницы **233, 251–252**, подтверждает:

- Если телефон не обнаружен более трёх минут или движение началось до обнаружения, индикатор блока связи гаснет.
- Для подключения после этого руководство предписывает выключить и включить зажигание.
- Ранее сопряжённое обнаруженное устройство подключается автоматически.
- При проблеме обнаружения рекомендовано приблизить телефон к **передней части сиденья водителя**, а не к приборке.

Это инструкция именно для семейства ER500E/EX500G с LCD. Она **не говорит**, что уже установленное соединение должно разрываться через три минуты; не описывает состояние рекламирования после радиотаймаута. Гипотеза о повторном закрытии окна после обрыва остаётся непроверенной.

Источники:

- [Официальное оглавление 2024](https://www.ktisc.eu/k-tisc/service/document/1856388864768482638).
- [Непосредственно PDF раздела ER500E/EX500G](https://www.ktisc.eu/k-tisc/service/procedure/1856388864768482638/PDF/91a4a6a3-5f36-4cc4-8b70-04143b97e0a9/en_GB?uid=91a4a6a3-5f36-4cc4-8b70-04143b97e0a9&nid=22&baseUrl=%2Fservice%2Fdocument%2F1856388864768482638).
- [Турецкое руководство Ninja 500, печатная стр. 61](https://www.kawasaki.com.tr/Photos/Pdf/pdfname638536969437782223.pdf) независимо повторяет это ограничение; публикация помечена 1 ноября 2023, разделы EX500G/EX500J.
- [Руководство 2025, раздел ER500E/EX500G](https://www.ktisc.eu/k-tisc/service/procedure/1981027998740119906/PDF/c9b3a995-1a4f-4c8b-803e-60bee1a82d98/en_GB?uid=c9b3a995-1a4f-4c8b-803e-60bee1a82d98&nid=162&baseUrl=%2Fservice%2Fdocument%2F1981027998740119906), печатная стр. 209: тот же порядок.

PDF 2024 прочитан и отрисован; визуально сверены заголовок модели, страница ограничения и указание положения телефона. Локально: `work/kawasaki-expanded-evidence/manual-2024-ex500g.pdf`, изображения `manual-2024-ex500g-p1.png`, `-p19.png`, `-p20.png`. SHA-256 PDF: `2b6c52c18dedfc207029a927fa9307bfdbfdf8abf77b712478c123c54526e291`.

**Вывод для приложения, а не утверждение производителя:** сохранять работающий GATT-канал; не рвать соединение из-за пропажи одного вида телеметрии при наличии других корректных данных. Сохранять намерение переподключаться, но не обещать, что повторы приложения могут включить рекламу периферийного устройства. В подсказках различать «телефон не найден до начала движения» и «потерян уже работающий поток».

## 2. 500 SE и 650: похожее название не означает одинаковую схему

В том же руководстве 2024 раздел **ER500F/EX500J** (TFT, печатная стр. 210) повторяет правило окна обнаружения. [PDF раздела](https://www.ktisc.eu/k-tisc/service/procedure/1856388864768482638/PDF/e3b5305e-dcec-4d97-9358-7666ab091c17/en_GB?uid=e3b5305e-dcec-4d97-9358-7666ab091c17&nid=21&baseUrl=%2Fservice%2Fdocument%2F1856388864768482638).

Для **ER650S/EX650S**, печатные стр. 681–686, описаны меню Bluetooth On/Off, Pairing Open/Limited, PIN с приборки и автоматическое подключение ранее сопряжённого телефона. Такого же текста о трёх минутах в просмотренном разделе нет. Это не доказательство отсутствия любых ограничений. [PDF 650](https://www.ktisc.eu/k-tisc/service/procedure/1856388864768482638/PDF/d36af907-abcf-4d92-9a6f-f0f4c9ad26bf/en_GB?uid=d36af907-abcf-4d92-9a6f-f0f4c9ad26bf&nid=31&baseUrl=%2Fservice%2Fdocument%2F1856388864768482638).

В официальном [немецком руководстве RIDEOLOGY 2020](https://www.kawasaki.info/iframe/_files/RIDEOLOGY_THE_APP_Benutzerhandbuch.pdf), стр. 20, при включённом зажигании и невозможности соединения предложено проверить нейтраль. Но более новое [руководство приложения, стр. 19](https://storage.kawasaki.eu/repository/ch/de-CH/Rideology/RIDEOLOGY_THE_APP_MOTORCYCLE_APP_manual_gh_final.pdf) описывает блокировку интерфейса при движении, передаче, открытом газе или отсутствии данных, а стр. 12 отдельно описывает запись скорости/передач/оборотов в движении. **Блокировка UI не равна намеренному разрыву BLE.**

Официальные каталоги запчастей подтверждают отдельный трансивер **21180-0007** у [Ninja 500 2024](https://www.kawasaki.com/en-us/owner-center/parts/347327/2024/EX500GRFAL) и [Z500 SE 2024](https://www.kawasaki.com/en-us/OwnerCenter/DownloadDiagramPdf/324041?modelcode=ER500FRFAN&modelyear=2024). Поэтому положение телефона рядом с приборкой само по себе не доказывает хорошую радиосвязь с трансивером. Дефект трансивера или экранирование пока не установлены.

## 3. Независимый BLE5-клиент: новые полезные детали

[Wazeology](https://github.com/agstrc/wazeology), просмотренная ревизия **418793517961145b74b3a06bff84a4c615ddbd24**. По автору проверен Z900 SE «R Edition» Бразилия MY2026, а не EX500G/iPhone.

[BleClient.java](https://github.com/agstrc/wazeology/blob/418793517961145b74b3a06bff84a4c615ddbd24/src/com/waze/wazeology/BleClient.java) и [ClusterBridge.java](https://github.com/agstrc/wazeology/blob/418793517961145b74b3a06bff84a4c615ddbd24/src/com/waze/wazeology/ClusterBridge.java):

- Отсутствующий сервис сразу после сопряжения рассматривается и как возможный временно пустой GATT-кеш. Известное сопряжённое устройство получает дополнительные попытки; случайный неподходящий прибор не объявляется Kawasaki.
- Callback проверяется по текущему GATT handle; поздняя discovery/MTU информация не перезапускает настройку готового соединения.
- Записи идут по одной, с паузой 50 мс; CCCD включаются последовательно.
- Разрыв ACL во время системного сопряжения не считается автоматически окончательной неудачей сопряжения.
- В фоне Android использует пассивный `autoConnect=true`; прямое подключение и ожидание разделены.

Для iOS полезны правила состояния и различение временной ошибки от несовместимости. Android `refreshCache`, `createBond`, `requestMtu`, `autoConnect` не являются доступными методами CoreBluetooth и буквально не переносятся.

Их 0x13 каждые 5 секунд — индикация TFT/навигации; это не новое доказательство необходимого heartbeat для LCD EX500G. [Описание границ авторской проверки](https://github.com/agstrc/wazeology/blob/418793517961145b74b3a06bff84a4c615ddbd24/DEVELOPMENT.md).

## 4. Дополнительные проекты: что можно перенести и что нельзя

| Первичный источник | Проверенное содержание | Полезный вывод для Moto Link |
|---|---|---|
| [Home Assistant Mobile BLE Proxy](https://github.com/Zen3515/homeassistant-mobile-ble-proxy/tree/d6c17263ce2bbc6bbe4e389f12286fec61353d80) | Android foreground service, сохранённый bond, адресные фильтры сканирования при блокировке, локальная запись предыдущего аварийного завершения | Учитывать разные режимы ОС, сохранять диагностическую причину перезапуска; Android foreground service не аналог iOS background mode |
| [Его issue 4, авторский отчёт о тормозах от журналов](https://github.com/Zen3515/homeassistant-mobile-ble-proxy/issues/4) | Накопленный UI-журнал замедляет интерфейс | Ограничивать отображаемую историю и обновления UI, не держать весь поток в наблюдаемом массиве |
| [Его issue 5](https://github.com/Zen3515/homeassistant-mobile-ble-proxy/issues/5) | Цикл scan start/stop создаёт тысячи записей | Исключить самоподдерживающийся цикл восстановления; backoff и ограничение одинаковых сообщений |
| [iKawa](https://github.com/gabrielerandazzo/iKawa/tree/79eb9049d13037be6fd91b8a1d1acd164ca70104) | ESP32 физически подключается к K-Line ECU, ANCS/AMS получает данные iPhone | Это другой аппаратный путь, не готовый клиент RIDEOLOGY. Его автосвязь ANCS не доказывает автоматическую фоновую телеметрию нашего приложения |
| [KTM-Nav-GEN3](https://github.com/Pavanayi1/KTM-Nav-GEN3) | Автор подтвердил повторные циклы зажигания KTM 390 Adventure; сохранение протокольных ключей, локальная история, маршрут без обязательной онлайн-карты | Не сбрасывать подтверждённое сопряжение при обновлении; собственная схема маршрута позволяет не обращаться к картам. Полная телеметрия KTM у автора не подтверждена, несмотря на поля протокола |
| [Suzuki Connect RE / GixxerBridge](https://github.com/mrwick1/suzuki-connect-re) | Другие UUID/кадры, ответные уведомления требуют записи телефона, разобранные heartbeat и журнал опровергнутых предположений | Каждый вывод привязывать к источнику/наблюдению; наличие поля в декомпиляции ещё не датчик на машине. Suzuki heartbeat нельзя послать в Kawasaki |
| [open-cfmoto](https://github.com/Asiern/open-cfmoto) | Отдельные BLE-auth/keepalive и облачный источник телеметрии; автор отличает BLE-управление от MQTT | Разделять транспортные слои. Нельзя переносить чужой heartbeat или облачную зависимость в Moto Link |
| [KoveDash](https://github.com/ttarlov/kove-dash) | Две несовместимые семьи приборок; отдельно отмечены проверки на месте и в дороге; автор ещё решает медленный reconnect | Модель, firmware и реальные возможности важнее одного бренда. Отдельно тестировать смену зажигания и непредвиденный разрыв |
| [BMW Open Connected TFT](https://github.com/vandelayautollc/open-connected-tft) | Данные X_KOMBI3/4 получены через Bluetooth Classic SPP/ICE; проверен дисплей 2019 года | Это не BLE GATT; реализация не является дополнительным декодером Kawasaki |
| [Bluejay](https://github.com/steamclock/bluejay) | Swift BLE библиотека разделяет ожидаемый disconnect, ошибки, восстановление состояния и очередь операций | Использовать как независимый контроль архитектуры; внедрение всей библиотеки не нужно ради одного аудита |
| [KDS2Bluetooth](https://github.com/HerrRiebmann/KDS2Bluetooth), [Eztys/KDS](https://github.com/Eztys/KDS), [Keyword-Protocol-2000](https://github.com/aster94/Keyword-Protocol-2000) | Диагностический K-Line/KWP2000 с физическим адаптером | Путь к дополнительным датчикам в будущем; не адресное пространство штатной характеристики RIDEOLOGY |
| [Kawasaki Grapher](https://github.com/biwabel/kawasaki-grapher), [RideologyKML](https://github.com/halojenproductions/RideologyKML), [rideology2gpx](https://github.com/jbokser/rideology2gpx) | Анализ и преобразование экспортированной истории | Можно использовать структуру экспорта для сравнения; связь они не устанавливают |

Повторно проверен и [Zen3515 Kawasaki BLE](https://github.com/Zen3515/homeassistant-kawasaki-rideology-ble): в его каталоге подтверждён только Z500 ER500F. Более устойчивый Android proxy предпочитается старому ESP32. Изменение supervision timeout и Wi-Fi/BLE coexistence относится к ESP32 и не является доступным iOS-переключателем. Регистрационные операции и удаление bonds автоматически переносить нельзя.

## 5. Что найдено на форумах — только воспроизводимые направления проверки

- [Ninja 650: GPS прекращается после примерно десяти минут](https://www.reddit.com/r/Ninja650/comments/sk8v29/): рассказ пользователя, не BLE-трасса. Проверять GPS и Bluetooth отдельно; не приравнивать исчезновение карты к потере мотоцикла.
- [RIDEOLOGY и повторное включение Bluetooth](https://www.reddit.com/r/Kawasaki/comments/w0a6ie/): встречаются ручной reset приборки и запуск приложения до зажигания. Это не доказательство конкретного исправления нашего клиента.
- [Ninja 500: iPhone не видит, Android видит](https://www.reddit.com/r/Kawasaki/comments/1bx20si/): направления проверки разрешений/сопряжения/рекламирования; без версий ОС и HCI нельзя делать вывод о дефекте iPhone.

Форумы не использованы как спецификация интервалов, байтовых команд или датчиков. Перечисленные истории полезны как сценарии регрессии, но нельзя обещать результат на их основании.

## 6. Каталог официально заявленной смартфонной связи

Это **каталог наличия связи RIDEOLOGY**, не обещание поддержки всех данных Moto Link. Регион, модельный год и комплектация должны оставаться полями записи; каталог не должен автоматически активировать новые команды. «С 2020» ниже — формулировка старого официального списка, а не доказательство неизменной приборки во всех последующих годах.

| Модель / семейство | Годы, прямо подтверждённые источниками | Источник |
|---|---|---|
| Ninja 500 / ABS, LCD | 2024; EX500G также в руководстве 2025 | [Спецификация США 2024](https://content.kawasaki.com/en-us/products/ProductSpecSheetPDF/2024-ninja-500), руководство раздела выше |
| Ninja 500 SE, TFT | 2024; EX500J также 2025 | [США 2024](https://content.kawasaki.com/en-us/motorcycle/ninja/sport/ninja-500/2024-ninja-500-se-abs), [Германия 2024](https://www.kawasaki.de/de_de/Motorcycles/Supersport_Sport/Ninja_500_SE_2024.html/EX500JRFAN/EX500JRFAN/MetallicMatteDarkGrayMetallicFlatSparkBlackMetallicMoondustGray) |
| Z500 / ABS, LCD | 2024; ER500E также 2025 | [США 2024](https://content.kawasaki.com/en-us/products/ProductSpecSheetPDF/2024-z500-abs), [Греция 2024](https://www.kawasaki.gr/en/Motorcycles/A2_Bikes/Z500_2024.html) |
| Z500 SE, TFT | 2024; ER500F также 2025 | [Австралия 2024](https://kma.kawasaki-global.com/en-au/motorcycle/z/supernaked/z500/2024-z500-se), руководство ER500F/EX500J |
| Z650, TFT | MY2020 и позднее по списку; отдельно ER650S 2024/2025 | [Официальный список, стр. 4](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf), PDF 650 выше |
| Ninja 650, TFT | MY2020 и позднее по списку; отдельно EX650S 2024/2025 | [Анонс MY2020](https://content2.kawasaki.com/contentstorage/kmc/products/7835/pressrelease/2020-kawasaki-ninja-650-press-release.191039845.pdf), PDF 650 выше |
| Versys 650, TFT | 2022; KLE650J в руководствах 2024/2025 | [Анонс производителя MY2022](https://content2.kawasaki.com/ContentStorage/KMC/PressReleases/696/e3e65a9c-fc12-4338-8ab7-c25be64fc1b3.pdf) |
| Z900 | MY2020 и позднее в историческом списке; приборки новых поколений отдельно | [Список Kawasaki](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf) |
| Ninja 1000SX | MY2020 и позднее в историческом списке | [Список Kawasaki](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf) |
| Z H2 | MY2020 и позднее в историческом списке | [Список Kawasaki](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf) |
| Ninja H2 / H2 Carbon | MY2019 и позднее в историческом списке | [Список Kawasaki](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf) |
| Versys 1000 SE | MY2019 и позднее в историческом списке; это не все Versys 1000 | [Список Kawasaki](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf) |
| Ninja H2 SX SE+ | MY2019 и позднее в старом списке; H2 SX 2022 отдельно SPIN | [Список](https://storage.kawasaki.eu/repository/sk/sk-SK/RideologyAppManual_final_KME-1.pdf), [производитель о SPIN](https://global.kawasaki.com/en/corp/newsroom/news/detail/?f=20211124_0706) |
| Eliminator 451 cc / Eliminator 500 по региону | MY2024 | [Анонс США](https://content2.kawasaki.com/ContentStorage/KMC/PressReleases/736/11126f6e-352b-4e38-b346-773d70abce9b.pdf) |
| Ninja ZX-4RR | MY2023; ZX400P/S также в руководстве 2024 | [Официальный анонс Индонезии](https://content2.kawasaki.com/ContentStorage/KMI/PressReleases/22/3e100581-0686-40dd-b023-6c60d8bc5afc.pdf) |
| KLX230 нового поколения | Анонс октябрь 2023; MY2024 KLX230 S имеет BT-блок | [Kawasaki Japan Mobility Show](https://global.kawasaki.com/en/corp/newsroom/news/detail/?f=20231025_9672), [официальная схема 2024](https://www.kawasaki.com/en-us/ownercenter/downloaddiagrampdf/367442?modelcode=KLX232DRFNN&modelyear=2024) |

Старый [Connectivity List](https://storage.kawasaki.eu/repository/ch/de-CH/Rideology/Rideology_Connectivity_list.pdf) содержит также Z H2 SE, Versys 1000 S, ZX-10R MY2021/2022+, Z900 SE. Его нельзя выдавать за полный актуальный каталог 2026. Новый глобальный PDF `https://www.global-kawasaki-motors.com/kawasaki_connect/en/pdf/Connectivity_list.pdf` в этой сессии вернул HTTP 403; содержание не выдумывалось. ATV/SxS/KX используют иные приложения/функции, в этот каталог не добавлены без отдельной проверки.

## 7. Конкретная программа самопроверки

Предложения для текущего исправления, не отметка «уже сделано»:

1. Развести BLE intent, состояние ОС/GATT и свежесть каждого измерения. Наличие GPS, сети, карты или открытого экрана истории не должно разрешать/запрещать Bluetooth-запись.
2. Проверить сохранение intent после resetting/poweredOff/poweredOn, возвращения разрешения, didFailToConnect, didDisconnect, ошибки discovery/notify/write, invalidated services и восстановления процесса.
3. Восстанавливать только после закрытия предыдущей попытки; отбросить поздние callback. Отличать Stop пользователя от собственного cancel для восстановления.
4. Не обрывать здоровое соединение при устаревании одного opcode. Проверить раздельные окна last-any-packet/last-4A, пропавшие ACK, поздние ответы, частичный notify и пустой GATT-кеш известного устройства.
5. Проверить долгую запись: ограниченный UI-буфер, запись вне отрисовки, ограничение повторяющихся ошибок, восстановление последней завершённой строки после аварии, недостаток места и локальное открытие истории.
6. Честно маркировать оценённый участок маршрута. Кратчайший путь требует дорожного графа, даже офлайн; прямая между двумя точками не становится доказанным маршрутом. Не использовать достроенную линию как измеренный пробег или подтверждение телеметрии.
7. Не обращаться к iOS-музыке/гарнитуре как к установленной причине: это пока только совместная нагрузка радио. Не отключать VPN/музыку автоматически. Без контролируемого сравнения и радиотрассы причину первых двух таймаутов доказать нельзя.

Охват поиска: официальные руководства и региональные страницы Kawasaki (Европа, США, Турция, Япония/Индонезия, Австралия), поиск GitHub по RIDEOLOGY/Kawasaki BLE/KDS и смежным брендам, собственные репозитории авторов, форумные сообщения владельцев. Это широкий, но ограниченный обзор; утверждение «нашёл всё в интернете» не делается.
