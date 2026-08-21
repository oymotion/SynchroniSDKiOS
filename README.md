# SynchroniSDKiOS

OYMotion Synchroni SDK for iOS / macOS

## Brief

Synchroni SDK is the software development kit for developers to access OYMotion
Synchroni products on Apple platforms. It ships as a prebuilt static
`sensor.xcframework` (slices: iOS arm64, iOS Simulator arm64, macOS arm64) with
an Objective-C API that Swift can use directly.

A full SwiftUI demo app (`example_swift/`, one target for macOS + iPhone/iPad)
is included.

---

## Installation

1. Add `lib/sensor.xcframework` to your Xcode target (General -> Frameworks;
   it is a static framework, so "Do Not Embed" is correct).
2. Link `CoreBluetooth.framework` and the C++ runtime (`-lc++`).
3. Import the SDK:

```swift
import sensor          // Swift
```

```objc
#import <sensor/sensorobjc.h>   // Objective-C
```

All public types (`SensorController` / `SensorProfile` / `SensorData` /
`Sample` / `DeviceInfo` / `BLEDevice` / `BinFileInfo`) come from the framework
itself.

## 1. Permission

Add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist`; iOS/macOS
requests Bluetooth permission at first use. To keep streaming in the
background on iOS, also enable the `bluetooth-central` background mode.

When the app goes to the background, tell the SDK so pending log/capture
records are flushed to disk (streaming keeps running; stopping it is the app's
decision):

```swift
SensorController.getInstance().onSuspend()
```

## SensorController methods

### 1. Initialize

```swift
let controller = SensorController.getInstance()
controller.delegate = self   // SensorControllerDelegate

// SensorControllerDelegate:
//   onScanResult(_ bleDevices: [BLEDevice])  — device list updates while scanning
//   onEnableChanged(_ enabled: Bool)         — Bluetooth power state changes
```

Use `getVersion()` for the SDK version string and `capiVersion()` to detect a
wrapper/library mismatch at runtime.

### 2. Start scan

```swift
let ok = controller.startScan(6.0)   // result push period in seconds
```

### 3. Stop scan

```swift
controller.stopScan()
```

### 4. Check scanning / Bluetooth state

```swift
controller.isScanning
controller.isEnable
```

### 5. Create / get SensorProfile

```swift
// Creates and registers a profile (also works for devices not discovered by
// the scanner):
let profile = controller.requireSensor(bleDevice.mac)

// nil when the MAC is unknown:
let profile = controller.getSensor(bleDevice.mac)

let all = controller.getSensors()
let connected = controller.getConnectedSensors()   // link Connected or Ready
```

### 6. Terminate

```swift
SensorController.terminate()
```

Destroys the shared controller and tears the whole SDK down; every profile
handle is invalidated afterwards. Call once at application shutdown; repeated
calls are safe.

## SensorProfile methods

### 7. Register the delegate

```swift
profile.delegate = self   // SensorProfileDelegate

// - onData(_:dataList:)              — ALL batches accumulated since the last
//                                       callback, in one call
// - onStateChanged(_:newState:)      — BLEState transitions
// - onError(_:err:)                  — errors (link loss, reconnect budget
//                                       exhausted, ...)
// - onPowerChanged(_:power:)         — battery pushes (optional)
// - onDeviceInfoUpdate(_:info:)      — DeviceInfo changed in place (optional)
// - onDataTransferStateChange(_:isTransferring:) — stream on/off (optional)
// - onAutoReconnect(_:hasLastSession:) -> Bool   — gate/customize session
//                                       recovery (optional)
```

Callback threading model: delegate calls and completion blocks fire on
internal SDK threads — hop to the main queue for UI work. The one exception is
`onAutoReconnect`, which must answer synchronously on an SDK thread (return
immediately, never call blocking SDK methods from it).

### 8. Connect / disconnect

Both are completion-block async (a nil completion = fire-and-forget; a
non-nil completion fires exactly once with the final result):

```swift
profile.connect { success, err in ... }
profile.disconnect { success, err in ... }   // stops the stream first when one is running
```

### 9. Device state

```swift
profile.deviceState   // BLEState: Disconnected/Connecting/Connected/Ready/...
profile.isReady       // shortcut for deviceState == BLEStateReady
```

Send commands only in the `Ready` state.

### 10. Init data transfer

```swift
profile.init(32, timeout: 5.0, powerRefreshInterval: 60.0) { success, err in ... }
// packageCount: batch size in samples per channel
// powerRefreshInterval: battery polling period in seconds; 0 disables polling
//                       (one initial reading is still pushed)
profile.hasInited
```

### 11. Data notification

```swift
profile.startDataNotification(timeout: 5.0) { success, err in ... }
profile.stopDataNotification(timeout: 5.0) { success, err in ... }
profile.isDataTransfering
```

### 12. Device info

```swift
let info = profile.deviceInfo   // cached during init / fetchDeviceInfo, no GATT traffic
profile.fetchDeviceInfo(timeout: 5.0) { info, err in ... }
```

`DeviceInfo` carries the device name / model / hardware / firmware versions,
the MTU size, a channel-count / sample-rate pair per modality (EEG, ECG, EMG,
BRTH, ACC, Gyro, PPG, SpO2, Euler, Quat, MagAngle, Impe, IMU), the
device-reported max sample rates (`EmgMaxSampleRate` / `EegMaxSampleRate` /
`EcgMaxSampleRate`, 0 = not reported) and the negotiated BLE link parameters
(`ConnectionIntervalMs` / `PeripheralLatency` / `SupervisionTimeoutMs`,
0 / -1 / 0 = unknown).

### 13. Battery level

```swift
profile.getBatteryLevel(timeout: 5.0) { battery, err in ... }
// battery: 0...100; a fresh GATT query every time (may report failure)
```

### 14. Auto reconnect

```swift
profile.setAutoReconnect(true)   // default on
```

While enabled and the device is streaming, an abnormal disconnect is followed
by automatic reconnect -> `init` with the previous arguments -> re-applying
the previous session's `setParam` values -> `startDataNotification`. Return
`true` from `onAutoReconnect(_:hasLastSession:)` to take over recovery
yourself.

### 15. Reading data

Data types (`NotifyDataType`):

```swift
// NTF_ACC = 1, NTF_GYRO = 2, NTF_EULER = 4, NTF_QUATERNION = 5,
// NTF_GEST = 7, NTF_EMG = 8, NTF_MAG_ANGLE = 13, NTF_EEG = 16,
// NTF_ECG = 17, NTF_IMPEDANCE = 18, NTF_IMU = 19 (aggregated IMU batch:
// acc 0-2 / gyro 3-5 / euler 6-8 / quat 9-12, new-EMG devices only),
// NTF_ADS = 20, NTF_BRTH = 21, NTF_IMPEDANCE_EXT = 22, NTF_SPO2 = 23,
// NTF_PPG = 24
```

Each `SensorData` is one batch of a single stream:

```swift
func onData(_ profile: SensorProfile, dataList: [SensorData]) {
    for data in dataList {
        guard data.isDataValid() else { continue }   // one probe per batch
        switch data.dataType {
        case NTF_EEG, NTF_ECG:
            for ch in 0 ..< Int(data.channelCount) {
                guard data.isChannelEnabled(atChannel: ch) else { continue }
                for i in 0 ..< Int(data.sampleCount) {
                    let v = data.getData(atChannel: ch, index: i)
                    _ = v
                }
            }
        default:
            break
        }
    }
}
```

- Metadata: `deviceMac` / `deviceName` / `dataType` / `lostPackageCount` /
  `sampleRate` / `channelCount` / `channelMask` / `sampleCount` /
  `startSampleIndex` / `startTimeStamp` / `delay` / `startTimeSec`.
- Single-point accessors: `getData` / `getRawData` / `getImpedance` /
  `getSaturation` / `getSampleIndex` / `getTimeStampInMs` /
  `getAbsTimeStampInSec` / `isLost` (all `atChannel:index:`) and
  `getChannelSample(atChannel:index:)` materializing a `Sample`. The
  accessors return zero/nil on out-of-range or stale slots.
- A `SensorData` delivered to the callback borrows SDK memory: the content
  stays valid while the stream runs (a rewritten slot is caught by
  `isDataValid`), but do not use it after the stream stops. Call `clone()` on
  any instance you keep — the clone owns its copies.

### 16. setParam

```swift
profile.setParam(timeout: 5.0, key: "NTF_EEG", value: "ON") { result, err in ... }
```

Available keys (value `"ON"` / `"OFF"` unless noted):

```swift
// Data stream toggles
"NTF_EEG" "NTF_ECG" "NTF_EMG" "NTF_GEST" "NTF_BRTH" "NTF_IMU"
"NTF_IMPEDANCE" "NTF_MAG_ANGLE" "NTF_PPG" "NTF_PPG_RAW" (alias of NTF_PPG)
"NTF_SPO2" "NTF_GFORCE_ACC" "NTF_GFORCE_GYRO" "NTF_GFORCE_EULER" "NTF_GFORCE_QUAT"
// NTF_IMU is the master switch of the four NTF_GFORCE_* streams; on legacy
// EMG devices NTF_GEST and NTF_EMG are mutually exclusive.

// Firmware filters
"FILTER_50HZ" "FILTER_60HZ" "FILTER_HPF" "FILTER_LPF"

// EEG/ECG sample rate (bound together on devices that have both; validated
// against getParam("EEG_SAMPLE_RATE_LIST"))
"EEG_SAMPLE_RATE"  // e.g. "500"

// Per-profile debug output (see Logging controls)
"DEBUG_LOG_PATH"       // "True" / "False" / absolute path
"DEBUG_BLE_DATA_PATH"  // bin capture export: "True" / "False" / absolute path
```

Changing an `NTF_*` key while streaming restarts the data notification so the
new setting takes effect immediately; `FILTER_*` applies on the fly.

### 17. getParam

```swift
profile.getParam(timeout: 5.0, key: "NTF") { result, err in ... }
// "NTF"    -> "NTF_BRTH|ON|NTF_ECG|ON|..." (aggregate of all known keys)
// "FILTER" -> "FILTER_50HZ|ON|FILTER_60HZ|ON|..."
// "EEG_SAMPLE_RATE"      -> current rate, e.g. "250"
// "EEG_SAMPLE_RATE_LIST" -> selectable rates, e.g. "250|500"
// plus every setParam key individually.
```

If the key is not supported, the result starts with `"Error"`.

## Bin file recording and replay

The SDK records the raw BLE packets of every session into a `.bin` capture
(see `DEBUG_BLE_DATA_PATH`); bin files can be inspected, replayed through the
normal parsing pipeline, or converted to CSV offline.

```swift
let info = controller.getBinFileInfo(path)   // BinFileInfo (mac, deviceName,
                                             // durationSec, deviceInfo, valid)

// Replay through the parse pipeline; the returned profile's delegate receives
// the data like a live device:
let replay = controller.replayBinFile(path, deviceMac: info.mac,
                                      realtime: true, timeout: 60)
controller.pauseBinReplay(info.mac)     // "OK" or "Error: ..."
controller.resumeBinReplay(info.mac)
controller.stopBinReplay(info.mac)      // joins the replay thread — call off
                                        // the main thread

// Offline full-speed conversion to CSV (blocks the caller):
let csv = controller.parseBinToCsv(binPath, csvPath: csvPath)
```

## Logging controls

```swift
controller.setDebugEnabled(true)            // master switch for file output
controller.setLogPath(true, path: dir)      // log directory (created if missing);
                                            // setLogPath(false) disables file output
```

The controller log (`sensor_controller_log_YYYYMMDD_HHMMSS.txt`) holds the
common logs; per-profile logs are enabled via `setParam("DEBUG_LOG_PATH", ...)`.
The default log directory is `~/Documents/sensorsdklog` (the app-sandbox
Documents directory on iOS).

Applications can write their own events into the same SDK log timeline
(tagged `[App]`; level is judged by its first character, case-insensitive
d/i/w/e, default "I"):

```swift
controller.log("User clicked start", level: "I")
profile.log("User toggled filter 50Hz")     // routed to the profile's log
```

## Example app

`example_swift/` contains **SensorDemoSwift**, a full SwiftUI demo (one target
for macOS + iPhone/iPad): multi-device scan/connect/stream, bio waveforms with
live band-pass filter, IMU waveforms + FFT spectra + 3D quaternion cube,
NTF/FILTER/sample-rate controls, battery, auto reconnect, bin replay and
parse-to-CSV.

```bash
cd example_swift
# macOS (arm64)
xcodebuild -project SensorDemoSwift.xcodeproj -scheme SensorDemoSwift \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
# iOS Simulator
xcodebuild -project SensorDemoSwift.xcodeproj -scheme SensorDemoSwift \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

On a real iPhone/iPad, set a Development Team in Xcode (Signing &
Capabilities). The demo expects `lib/sensor.xcframework` next to it
(`../lib/sensor.xcframework`); keep the repo layout when moving directories.
