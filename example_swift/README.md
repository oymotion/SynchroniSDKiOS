# example_swift — SensorDemoSwift

SwiftUI demo app (macOS + iPhone/iPad, one target) for the SensorSDKCXX
sensor.xcframework, ported from `example_qt` (Qt desktop/mobile parity) and
`example_android_capi_kt`. The app talks to the SDK through the
**sensorobjc** Objective-C wrapper (API style mirrors SensorSDKiOS), which is
compiled into `sensor.framework` itself — linking the xcframework is all the
app needs.

## Features

- Scan (RSSI-sorted list, in-place updates) / connect / disconnect; connect
  stops the scan first (Kotlin demo parity).
- Multi-device: several sensors can be connected at once; each scan row has
  its own Connect/Disconnect button and shows its link state. Selecting a
  connected row makes it the current device -- the Bio/IMU pages, NTF/FILTER
  switches, sample-rate radio, and Live Filter follow the selection.
- init (packageCount 32, 5 s timeout, 60 s battery poll) -> DeviceInfo labels
  (Model/HW/FW) -> NTF/FILTER getParam readback -> startDataNotification
  (skipped when the stream is already on, e.g. after the SDK's auto-reconnect
  session recovery).
- Per-type stream telemetry (Qt DeviceState parity): the status line shows
  every stream that delivered data (`Connected: name | EMG 8ch @ 250Hz |
  ...`), a second line shows measured-vs-nominal rates plus the stream-start
  wall clock and first-packet delay (`Actual: EEG 249.7 / 250Hz | start ...
  | delay 12ms`), refreshed ~1/s, and a "Packet Loss Stats" line reports the
  latest lost-package count per data type.
- Bio page with 8 fixed waveform slots and auto mode selection (PPG > EEG >
  EMG, data-driven repair): EMG channels fill the leading slots; EEG channels
  are paged (Prev/Next + "Page x / y", perPage = 8 - hasECG - hasBRTH,
  ECG/BRTH pinned to the trailing slots, curve colors stable per channel
  across pages); PPG devices show the fixed 6-plot set (EEG fp1/fp2 + PPG
  red/ir + SpO2 spo2/hr). Impedance side texts use the Qt color thresholds.
  Empty slots show "Waiting for data ..." / "Not connected" placeholders.
- IMU page: ACC/GYRO/EULER/QUATERNION waveforms (fixed Y ranges), each with
  an FFT spectrum strip underneath (background-computed, refreshed every
  500 ms), a "Real-time Values" panel with the latest numeric value per
  channel, + 3D quaternion cube (CubeWidget port); the NTF_IMU aggregate is
  split back into per-type rings (acc 0-2 / gyro 3-5 / euler 6-8 / quat 9-12).
- Live Filter picker on the Bio page (Off / delta / theta / alpha / beta /
  gamma bands): bandpasses the bio waveforms live; the selected band
  persists across devices and is rebuilt on every switch.
- 6 NTF switches (EEG/EMG/GESTURE/PPG/SpO2/IMU) + 4 FILTER switches
  (50Hz/60Hz/HPF/LPF; setParam; unsupported keys hidden once state info
  exists); a successful NTF/FILTER/EEG_SAMPLE_RATE setParam clears the UI
  data buffers (Qt clearUiData parity). The EEG sample-rate radios show the
  fixed 250/500 candidates, enabled only when reported by
  EEG_SAMPLE_RATE_LIST, with the checked state synced from the device.
- Gesture box in the multi-line Qt form (`gesture: -- (0-8)` etc.),
  battery with the +-4 stable band (applied only to the explicit read at
  connect; SDK power pushes are taken as-is), Auto Reconnect / Use Queue
  Data / SDK Debug Log toggles.
- Disconnect handling (Qt parity): the param controls grey out as soon as a
  disconnect starts; an abnormal drop with Auto Reconnect ON keeps the
  session and shows "Connection lost, auto reconnecting ..."; a final
  disconnect removes the device session and its cached parameter states.
- App event logging: user actions and callback results (scan/connect/
  setParam/replay/...) are written into the SDK log with the "App" tag,
  sharing the SDK's own log timeline (SDK debug log toggle must be on).
- Bin replay (Qt exclusive-session parity): refused while any device is
  connected; the replay appears as a selectable "[Replay]" row (with a
  "[Streaming]" mark) in the device list; scan/list/debug toggles/connect
  are locked while it runs; single Pause/Resume toggle; the end is detected
  via the data-transfer OFF push plus a 1 s poll fallback, distinguishing
  "Replay stopped" from "Replay finished". Offline parse-to-CSV is re-entry
  guarded and reveals the finished CSV in Finder (macOS).
- "Clone Data" (example_qt parity): batches are always enqueued and
  processed on a worker queue; ON = every batch is cloned on the SDK
  callback thread before enqueueing, OFF (default) = the zero-copy
  borrowed batch is enqueued directly (a batch rewritten before the
  worker reads it is caught by the isDataValid probe and reads as zeros).
- Shutdown: the data worker is stopped and joined before the SDK is
  terminated; on macOS the window-close notification triggers the same
  path (window close does not fire willTerminate) and quits the app.

## Build

Requires the prebuilt SDK framework (already in the repo at
`lib/sensor.xcframework`). To rebuild it, run
`bld/xcframework/build_xcframework.sh` in the SensorSDKCXX repo and copy the
result over.

Then build the app (or open `SensorDemoSwift.xcodeproj` in Xcode and Run):

```bash
# macOS (arm64; the framework's mac slice is arm64-only)
xcodebuild -project SensorDemoSwift.xcodeproj -target SensorDemoSwift \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
# iOS Simulator
xcodebuild -project SensorDemoSwift.xcodeproj -target SensorDemoSwift \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Notes:

- The app links the STATIC `sensor.xcframework` plus `CoreBluetooth` and
  `-lc++` (consumers link the framework's dependencies themselves).
- The sensorobjc wrapper (implementation AND public headers) ships inside
  the framework bundles, so the bridging header just does
  `#import <sensor/sensorobjc.h>`; nothing else from the SensorSDKCXX repo
  is referenced.
- The macOS app is unsigned/sandbox-free (demo); iOS deployment targets 16.0,
  macOS 13.0. Bluetooth permission strings are in `SensorDemoSwift/Info.plist`.
- On a real iPhone/iPad, set a Development Team in Xcode (Signing &
  Capabilities).

## Dev variant

The from-source Debug variant (`example_swift_dev/`) lives in the SensorSDKCXX
repo and is not part of this distribution — it needs the full SDK source tree.
