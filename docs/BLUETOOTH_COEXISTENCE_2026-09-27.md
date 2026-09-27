# Bluetooth coexistence evidence — 2026-09-27

Sena/Watch coexistence is a hypothesis to compare with observed Kawasaki telemetry, not a diagnosed cause. Apple documents that interference and obstructions can cause poor connections; Bluetooth and 2.4 GHz Wi-Fi share a band. Device count alone does not establish overload. [Apple interference guidance](https://support.apple.com/en-gb/102319)

## Hardware and firmware facts

- Sena 50S specifies Bluetooth 5.0 with HSP, HFP, A2DP and AVRCP. Phone pairing uses hands-free and stereo profiles; Bluetooth intercom and Mesh are distinct modes. Audio overlay and priority can reduce/interrupt music while bike telemetry continues normally. Record idle/music/call or Siri/Bluetooth intercom/Mesh as separate user-reported conditions. [Sena specifications](https://www.sena.com/product/50s/), [manual sections 4.3, 13.1 and 14.2.10](https://firmware.sena.com/senabluetoothmanager/UserGuide_50S_2.7.0_en_250123.pdf)
- Latest official release notices found: original **SP75 / 50S-01, 50S-01D: v1.5.1 (2026-02-13)**; revised **SP113 / 50S-10, 50S-10D: v2.7.2 (2026-04-15)**. The former addresses Smart Volume Control sensitivity and Mesh music sharing; the latter addresses Siri command processing. Neither notice establishes a Kawasaki BLE fix. Identify actual hardware and installed firmware; do not infer the branch from purchase year or compare 1.x against 2.x. Keep firmware unchanged during baseline comparison. [Original release](https://www.sena.com/en-us/stories/notice/sena-releases-firmware-updates-for-the-50s-v1-5-1/), [revised release](https://www.sena.com/en-us/stories/notice/sena-releases-firmware-updates-for-the-50s-v2-7-2/)
- Apple Watch Series 5 has Bluetooth 5.0 and 2.4 GHz-only 802.11b/g/n Wi-Fi. It generally uses Bluetooth near its paired iPhone, with Wi-Fi/cellular fallback where available. A 44 mm case does not identify GPS versus cellular. [Specifications](https://support.apple.com/en-ae/118453), [connection selection](https://support.apple.com/en-us/109319)

## What MotoLink can observe

| Evidence | Interpretation and limit |
| --- | --- |
| Bike connection callbacks and error domain/code | MotoLink's connection lifecycle, not proof of the RF cause. |
| Existing telemetry callback timing | App-observed arrival gaps; not over-the-air packet loss without independent sequence evidence. |
| Bike `readRSSI()` | Signal-strength evidence for the connected bike only; not interference, Sena RSSI or Watch RSSI. [Apple](https://developer.apple.com/documentation/corebluetooth/cbperipheral/readrssi%28%29) |
| `AVAudioSession.currentRoute` and route-change notifications | Best-effort audio-session port types; not a list of connected accessories. An empty/missing route means unknown. [Current route](https://developer.apple.com/documentation/avfaudio/avaudiosession/currentroute), [notifications](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes) |
| `isOtherAudioPlaying` | Another app plays audio; does not identify the app, content, headset, call or radio activity. [Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/isotheraudioplaying) |
| Audio interruption/media-services reset notification | A session-level event; do not label an interruption as a call or Siri without other evidence. |

The passive monitor records port **types**, never names/UIDs. It never configures or activates audio, overrides a route, records/plays audio, or requests microphone/media-library access. Apple warns that audio-session activation can interrupt background audio. Inactive-session observations are best effort and may be incomplete; do not activate audio to improve diagnostic visibility. [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)

There is no Watch companion in this app and the monitor does **not** activate `WCSession`. Even with a companion, `isPaired` means paired, and `isReachable` means a counterpart app can exchange interactive messages over Bluetooth **or Wi-Fi**. Neither establishes the Watch's current radio transport or RSSI. Actual Watch radio state is unknown to this monitor; “watch worn” can only be explicit user context. [Paired](https://developer.apple.com/documentation/watchconnectivity/wcsession/ispaired), [Apple Watch data transfer](https://developer.apple.com/videos/play/wwdc2021/10003/)

Public CoreBluetooth provides no RF-channel/channel-map or airtime-priority control for MotoLink. Sena's Open Mesh channel setting is not selection of the iPhone/bike BLE channel. `retrieveConnectedPeripherals(withServices:)` filters by known services; it is not universal accessory enumeration. `cancelPeripheralConnection` cancels the app's local connection and explicitly does not guarantee physical disconnection if another app maintains a connection. It cannot disconnect other apps, Sena or Watch. The peripheral-role `setDesiredConnectionLatency` is not a central-role scheduling guarantee. [Connected peripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals%28withservices%3A%29), [cancel connection](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29), [latency request](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/setdesiredconnectionlatency%28_%3Afor%3A%29)

## Bounded comparison

The audio-context monitor emits one snapshot at recording start and subsequent changes only, while recording. There is no timer or event-history array. A ride has at most 120 context events plus one explicit suppression marker; stopping/restarting recording resets that budget. Route notifications with unchanged observed context are omitted. This is context, not a complete system audio trace.

Use comparable durations, phone position, route/environment and app foreground/background conditions. Compare baseline with one change at a time: Sena off versus idle; then music versus actual intercom use; Watch off only if needed. Return to baseline and repeat a promising contrast. Change settings while stopped. Keep firmware and bike configuration fixed during comparison.

Prefer counts/durations, disconnections, reconnect latency, telemetry gap median/p95/max and sparse bike RSSI over raw payload floods. Keep a bounded event window around failures. If gaps follow app lifecycle rather than accessory conditions, investigate lifecycle handling. If audio changes but telemetry remains regular, the bike link has not demonstrated failure. Repeatable association motivates further diagnosis; it does not by itself prove interference.
