import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Per-device context: profile, stream state, and cached UI values.
final class DeviceContext {
    let profile: SensorProfile
    let state = DeviceState()
    var info: DeviceInfo?
    var batteryLevel = -1
    var batteryText = "Power: -"
    var linkText = "Link: --"
    var mtuText = "MTU: --"
    var modelText = "Model: -"
    var hwText = "HW: -"
    var fwText = "FW: -"
    var ntfStates: [String: Bool] = [:]
    var filterStates: [String: Bool] = [:]
    var ntfSupported: Set<String>?
    var filterSupported: Set<String>?
    var eegSampleRateOptions: [Int] = []
    var eegSampleRate = 0
    var emgSampleRateOptions: [Int] = []
    var emgSampleRate = 0
    var imuSampleRateOptions: [Int] = []
    var imuSampleRate = 0
    var ppgSampleRateOptions: [Int] = []
    var ppgSampleRate = 0
    /// True while the stream is on.
    var streaming = false
    /// Replay session context.
    var isReplay = false
    /// Connect -> init -> start chain issued.
    var flowStarted = false
    /// Current EEG page of the Bio panel.
    var bioPageIndex = 0

    init(profile: SensorProfile) { self.profile = profile }

    var mac: String { profile.device.mac }
    var connected: Bool {
        profile.deviceState == .ready || profile.deviceState == .connected
    }
}

/// Shared 50 ms plot tick: one Timer drives every waveform/cube redraw.
final class PlotTicker: ObservableObject {
    @Published private(set) var tick: UInt64 = 0
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick &+= 1
        }
    }

    deinit { timer?.invalidate() }
}

/// App-wide model: scan -> connect -> init -> stream, per-device contexts,
/// and the UI state the pages bind to.
final class AppModel: NSObject, ObservableObject {

    // MARK: published UI state

    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var statusText = "Press Start Scan"
    @Published private(set) var connectionText = "Disconnected"
    @Published private(set) var countersText = ""
    /// Measured-vs-nominal per-type rate line.
    @Published private(set) var rateText = ""
    /// Per-type packet-loss line.
    @Published private(set) var lostPacketText = "Packet Loss Stats: None"
    @Published private(set) var modelText = "Model: -"
    @Published private(set) var hwText = "HW: -"
    @Published private(set) var fwText = "FW: -"
    @Published private(set) var batteryText = "Power: -"
    /// Link connection parameters from DeviceInfo.
    @Published private(set) var linkText = "Link: --"
    @Published private(set) var mtuText = "MTU: --"
    /// EEG sample-rate control state: options and current value.
    @Published private(set) var eegSampleRateOptions: [Int] = []
    @Published private(set) var eegSampleRate = 0
    /// EMG sample-rate control state.
    @Published private(set) var emgSampleRateOptions: [Int] = []
    @Published private(set) var emgSampleRate = 0
    /// IMU sample-rate control state.
    @Published private(set) var imuSampleRateOptions: [Int] = []
    @Published private(set) var imuSampleRate = 0
    /// PPG sample-rate control state.
    @Published private(set) var ppgSampleRateOptions: [Int] = []
    @Published private(set) var ppgSampleRate = 0
    @Published private(set) var storageText = ""
    /// Current device's DeviceInfo.
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var gestureText = AppModel.gestureEmptyText
    @Published private(set) var bioMode: BioMode = .none
    @Published private(set) var replayText = ""
    /// Replay session state: member macs in start order and their names.
    @Published private(set) var replayMacs: [String] = []
    @Published private(set) var replayNames: [String: String] = [:]
    @Published private(set) var replayPaused = false
    @Published private(set) var replayStopRequested = false
    /// Re-entry guard for the parse-to-CSV worker.
    @Published private(set) var analyzing = false
    /// MACs with a user disconnect in flight.
    @Published private(set) var disconnectingMacs: Set<String> = []
    /// Current EEG page of the current device's Bio panel.
    @Published private(set) var bioPageIndex = 0

    var replaying: Bool { !replayMacs.isEmpty }

    /// The demo's own version. Shown on the Device page.
    static let demoVersion = "0.1.22"
    /// SDK version string, captured at startup.
    let sdkVersion: String

    /// Live Filter band index (0 = Off).
    @Published var liveFilterBand = 0 {
        didSet {
            contextsLock.lock()
            let all = contexts.values
            contextsLock.unlock()
            for ctx in all { ctx.state.liveFilter.setBand(liveFilterBand) }
            let label = liveFilterBand >= 0 && liveFilterBand < LiveFilter.bandLabels.count
                ? LiveFilter.bandLabels[liveFilterBand] : "Off"
            appLog("User: live filter -> \(label)")
        }
    }

    /// Scan-list row selection; the selected device becomes the current one.
    @Published var selectedMac: String? {
        didSet { syncMirrors() }
    }
    /// MACs of the devices whose link is up.
    @Published private(set) var connectedMacs: Set<String> = []
    /// Macs whose stream is on.
    @Published private(set) var streamingMacs: Set<String> = []
    /// MAC of the current device (the one the Bio/IMU pages and the
    /// parameter controls are bound to).
    @Published private(set) var currentMac: String?
    @Published var autoReconnect = true {
        didSet {
            appLog("User: auto reconnect \(autoReconnect ? "ON" : "OFF")")
            contextsLock.lock()
            let all = contexts.values
            contextsLock.unlock()
            for ctx in all { ctx.profile.setAutoReconnect(autoReconnect) }
            for (_, p) in replayProfiles { p.setAutoReconnect(autoReconnect) }
        }
    }
    @Published var cloneData = false {
        didSet {
            dataModeLock.lock()
            cloneDataMode = cloneData
            dataModeLock.unlock()
        }
    }
    @Published var debugLogEnabled = true {
        didSet {
            appLog("User: SDK debug log \(debugLogEnabled ? "ON" : "OFF")")
            applyDebugLog()
            let value = debugLogEnabled ? "True" : "False"
            contextsLock.lock()
            let all = contexts.values
            contextsLock.unlock()
            for ctx in all where ctx.connected && ctx.profile.hasInited {
                sendSessionParam(ctx.profile, key: "DEBUG_LOG_PATH", value: value)
            }
        }
    }
    /// "Enable Debug Bin Data" toggle.
    @Published var debugBinEnabled = true {
        didSet {
            appLog("User: data debug log \(debugBinEnabled ? "ON" : "OFF")")
            let value = debugBinEnabled ? "True" : "False"
            contextsLock.lock()
            let all = contexts.values
            contextsLock.unlock()
            for ctx in all where ctx.connected && ctx.profile.hasInited {
                sendSessionParam(ctx.profile, key: "DEBUG_BLE_DATA_PATH", value: value)
            }
        }
    }

    /// NTF / FILTER switch states and support sets.
    @Published private(set) var ntfStates: [String: Bool] = [:]
    @Published private(set) var filterStates: [String: Bool] = [:]
    @Published private(set) var ntfSupported: Set<String>?
    @Published private(set) var filterSupported: Set<String>?

    static let ntfKeys = ["NTF_EEG", "NTF_EMG", "NTF_GEST", "NTF_PPG", "NTF_SPO2", "NTF_IMU"]
    static let filterKeys = ["FILTER_50HZ", "FILTER_60HZ", "FILTER_HPF", "FILTER_LPF"]
    /// Friendly switch labels.
    static let ntfLabels: [String: String] = [
        "NTF_EEG": "EEG", "NTF_EMG": "EMG", "NTF_GEST": "GESTURE",
        "NTF_PPG": "PPG", "NTF_SPO2": "SpO2", "NTF_IMU": "IMU",
    ]
    static let filterLabels: [String: String] = [
        "FILTER_50HZ": "50Hz", "FILTER_60HZ": "60Hz",
        "FILTER_HPF": "HPF", "FILTER_LPF": "LPF",
    ]
    /// EEG Sample Rate radio candidates.
    static let sampleRateCandidates = [250, 500, 1000, 2000]
    /// EMG Sample Rate radio candidates.
    static let emgSampleRateCandidates = [500, 1000]
    /// IMU Sample Rate radio candidates.
    static let imuSampleRateCandidates = [50, 100, 200, 250, 400, 500, 1000, 2000]
    /// PPG Sample Rate radio candidates.
    static let ppgSampleRateCandidates = [50, 100, 200, 400, 800, 1000, 1600, 3200]
    /// Bio page slot count.
    static let bioSlotCount = 8
    /// Gesture box text before the first gesture sample.
    static let gestureEmptyText = "Gesture:\n  gesture: -- (0-8)\n  raw gesture: -- (0-8)\n" +
        "  possiblity: -- (0-100)\n  strength: -- (0-100)"

    // MARK: internals

    /// Placeholder returned by deviceState while no device context is current.
    private let placeholderState = DeviceState()
    /// Shared plot tick.
    let plotTicker = PlotTicker()
    private var controller: SensorController { SensorController.getInstance() }
    /// Per-device contexts keyed by MAC.
    private let contextsLock = NSLock()
    private var contexts: [String: DeviceContext] = [:]
    /// Insertion order of contexts.
    private var contextOrder: [String] = []
    /// Consecutive scan rounds each listed device has been absent.
    private var absentRounds: [String: Int] = [:]
    /// Active replay members keyed by mac.
    private var replayProfiles: [String: SensorProfile] = [:]
    /// User-initiated disconnects.
    private var pendingUserDisconnect: Set<String> = []
    /// MACs in an abnormal drop being auto-reconnected.
    private var autoReconnectingMacs: Set<String> = []
    /// Successful user setParam history per device (auto-reconnect restore).
    private var savedParamsByMac: [String: [(key: String, value: String)]] = [:]
    /// Devices whose next stream start replays the saved params.
    private var pendingParamRestore: Set<String> = []
    /// Per-MAC caches of the resolved device log/bin-data paths.
    private var lastLogPaths: [String: String] = [:]
    private var lastDataPaths: [String: String] = [:]
    /// Security-scoped URLs held for the active replay session.
    private var replayScopedUrls: [URL] = []
    /// Security-scoped URLs held for the in-flight bin parse.
    private var parseScopedUrls: [URL] = []
    /// Last 1 Hz rotation of the per-type rate windows.
    private var lastRateTick = Date.distantPast
    private let dataModeLock = NSLock()
    private var cloneDataMode = false
    /// Data pipeline queue: batches paired with the target device's stream
    /// state.
    private let dataQueueLock = NSCondition()
    private var dataQueue: [(state: DeviceState, batch: SensorData)] = []
    private var dataWorkerStop = false
    private var dataWorker: Thread?
    private var uiTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    #if os(macOS)
    private var windowCloseObserver: NSObjectProtocol?
    #endif
    private var didShutdown = false

    /// The context the Bio/IMU pages and the parameter controls bind to.
    private var currentContext: DeviceContext? {
        contextsLock.lock()
        defer { contextsLock.unlock() }
        if let mac = selectedMac, let ctx = contexts[mac] {
            return ctx
        }
        for mac in contextOrder {
            if let ctx = contexts[mac], ctx.connected { return ctx }
        }
        if let mac = contextOrder.first { return contexts[mac] }
        return nil
    }

    private func context(for mac: String) -> DeviceContext? {
        contextsLock.lock()
        defer { contextsLock.unlock() }
        return contexts[mac]
    }

    /// Current device's profile (nil when nothing is connected/selected).
    var profile: SensorProfile? { currentContext?.profile }

    /// Current device's stream state.
    var deviceState: DeviceState { currentContext?.state ?? placeholderState }

    /// Current device link state.
    var connected: Bool { currentContext?.connected ?? false }

    /// NTF/FILTER/sample-rate controls enabled state.
    var controlsEnabled: Bool {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return false }
        return !disconnectingMacs.contains(ctx.mac)
    }

    /// Scan-list row state text for one device.
    func stateText(for mac: String) -> String {
        guard !didShutdown else { return "Disconnected" }
        return context(for: mac)?.profile.stateString ?? "Disconnected"
    }

    /// Re-publishes the current device's cached values into the @Published
    /// mirrors.
    private func syncMirrors() {
        let ctx = currentContext
        currentMac = ctx?.mac
        deviceInfo = ctx?.info
        modelText = ctx?.modelText ?? "Model: -"
        hwText = ctx?.hwText ?? "HW: -"
        fwText = ctx?.fwText ?? "FW: -"
        batteryText = ctx?.batteryText ?? "Power: -"
        linkText = ctx?.linkText ?? "Link: --"
        mtuText = ctx?.mtuText ?? "MTU: --"
        eegSampleRateOptions = ctx?.eegSampleRateOptions ?? []
        eegSampleRate = ctx?.eegSampleRate ?? 0
        emgSampleRateOptions = ctx?.emgSampleRateOptions ?? []
        emgSampleRate = ctx?.emgSampleRate ?? 0
        imuSampleRateOptions = ctx?.imuSampleRateOptions ?? []
        imuSampleRate = ctx?.imuSampleRate ?? 0
        ppgSampleRateOptions = ctx?.ppgSampleRateOptions ?? []
        ppgSampleRate = ctx?.ppgSampleRate ?? 0
        ntfStates = ctx?.ntfStates ?? [:]
        filterStates = ctx?.filterStates ?? [:]
        ntfSupported = ctx?.ntfSupported
        filterSupported = ctx?.filterSupported
        connectionText = ctx?.profile.stateString ?? "Disconnected"
        bioPageIndex = ctx?.bioPageIndex ?? 0
        contextsLock.lock()
        connectedMacs = Set(contexts.values
            .filter { $0.connected || autoReconnectingMacs.contains($0.mac) }
            .map { $0.mac })
        streamingMacs = Set(contexts.values.filter { $0.streaming }.map { $0.mac })
        contextsLock.unlock()
    }

    override init() {
        sdkVersion = SensorController.getInstance().getVersion()
        super.init()
        controller.delegate = self
        applyDebugLog()
        statusText = "SensorSDK \(sdkVersion) \u{2014} Press Start Scan"
        let worker = Thread { [weak self] in self?.drainDataQueue() }
        worker.name = "SensorDataDrain"
        worker.start()
        dataWorker = worker
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshDerived()
        }
        #if os(macOS)
        let terminateNotification = NSApplication.willTerminateNotification
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.shutdown()
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
        #else
        let terminateNotification = UIApplication.willTerminateNotification
        #endif
        terminateObserver = NotificationCenter.default.addObserver(
            forName: terminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.shutdown()
        }
    }

    deinit {
        uiTimer?.invalidate()
        if let terminateObserver = terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        #if os(macOS)
        if let windowCloseObserver = windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        #endif
        dataQueueLock.lock()
        dataWorkerStop = true
        dataQueueLock.signal()
        dataQueueLock.unlock()
    }

    /// Idempotent shutdown.
    private func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        appLog("App: demo window closing")
        // All SDK handles die with terminate() below; drop every reference
        // first so a view flush or a queued callback during AppKit's
        // termination runloop spin takes an empty path instead of touching
        // a dead profile.
        contextsLock.lock()
        contexts.removeAll()
        contextOrder.removeAll()
        contextsLock.unlock()
        replayProfiles.removeAll()
        replayMacs.removeAll()
        replayNames.removeAll()
        devices.removeAll()
        for url in replayScopedUrls { url.stopAccessingSecurityScopedResource() }
        replayScopedUrls.removeAll()
        for url in parseScopedUrls { url.stopAccessingSecurityScopedResource() }
        parseScopedUrls.removeAll()
        syncMirrors()
        dataQueueLock.lock()
        dataWorkerStop = true
        dataQueueLock.signal()
        dataQueueLock.unlock()
        if let worker = dataWorker {
            while !worker.isFinished {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        SensorController.terminate()
    }

    // MARK: app log

    /// Writes an app event line into the SDK log.
    func appLog(_ message: String, level: String = "I", profile: SensorProfile? = nil) {
        if let target = profile ?? self.profile {
            target.log(message, level: level)
        } else {
            controller.log(message, level: level)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            if !didShutdown { body() }
        } else {
            DispatchQueue.main.async {
                if !self.didShutdown { body() }
            }
        }
    }

    private func refreshDerived() {
        let state = deviceState
        countersText = state.countersText()
        let g = state.currentGesture()
        gestureText = g.gesture >= 0
            ? "Gesture:\n  gesture: \(g.gesture) (0-8)\n  raw gesture: \(g.rawGesture) (0-8)\n" +
              "  possiblity: \(g.possibility) (0-100)\n  strength: \(g.strength) (0-100)"
            : AppModel.gestureEmptyText
        bioMode = state.currentBioMode()
        lostPacketText = state.lostPacketText()
        // 1 Hz tick.
        let now = Date()
        guard now.timeIntervalSince(lastRateTick) >= 1.0 else { return }
        lastRateTick = now
        state.updateActualRates()
        if let ctx = currentContext, ctx.flowStarted {
            let name = ctx.profile.device.name
            let head = ctx.isReplay ? "Replaying: \(name)" : "Connected: \(name)"
            statusText = state.buildStatusText(head: head)
        }
        rateText = state.buildRateText()
    }

    // MARK: data pipeline

    /// Enqueues one batch with its target device's stream state.
    private func enqueueData(_ state: DeviceState, _ batch: SensorData) {
        dataQueueLock.lock()
        while dataQueue.count >= 1000 {
            dataQueue.removeFirst()
        }
        dataQueue.append((state, batch))
        dataQueueLock.signal()
        dataQueueLock.unlock()
    }

    /// Drains the data queue.
    private func drainDataQueue() {
        var pending: [(state: DeviceState, batch: SensorData)] = []
        while true {
            dataQueueLock.lock()
            while !dataWorkerStop && dataQueue.isEmpty {
                dataQueueLock.wait()
            }
            if dataWorkerStop && dataQueue.isEmpty {
                dataQueueLock.unlock()
                return
            }
            pending = dataQueue
            dataQueue.removeAll(keepingCapacity: true)
            dataQueueLock.unlock()
            for item in pending {
                item.state.append([item.batch])
            }
            pending.removeAll(keepingCapacity: true)
        }
    }

    // MARK: scan

    func toggleScan() {
        if controller.isScanning {
            appLog("Stop scan")
            controller.stopScan()
            scanning = false
            statusText = "Scan stopped"
        } else {
            if !controller.isEnable {
                appLog("User: start scan rejected (Bluetooth disabled)", level: "W")
                statusText = "Bluetooth is not enabled"
                return
            }
            appLog("User: start scan")
            scanning = controller.startScan(3.0)
            statusText = scanning ? "Scanning..." : "Error: start scan failed"
        }
    }

    private func mergeDevices(_ list: [BLEDevice]) {
        let present = Set(list.map { $0.mac })
        for d in list {
            absentRounds[d.mac] = 0
            if let idx = devices.firstIndex(where: { $0.mac == d.mac }) {
                devices[idx] = d
            } else {
                let at = devices.firstIndex(where: { $0.rssi < d.rssi }) ?? devices.count
                devices.insert(d, at: at)
            }
        }
        contextsLock.lock()
        let ctxMacs = Set(contexts.keys)
        contextsLock.unlock()
        var i = 0
        while i < devices.count {
            let mac = devices[i].mac
            if present.contains(mac) {
                i += 1
                continue
            }
            if ctxMacs.contains(mac) || replayMacs.contains(mac) {
                absentRounds[mac] = 0
                i += 1
                continue
            }
            let missed = (absentRounds[mac] ?? 0) + 1
            if missed >= 2 {
                absentRounds.removeValue(forKey: mac)
                devices.remove(at: i)
                if selectedMac == mac {
                    selectedMac = nil
                }
            } else {
                absentRounds[mac] = missed
                i += 1
            }
        }
    }

    // MARK: connect chain

    /// Per-device connect/disconnect from the scan-list row button.
    func toggleConnect(mac: String) {
        let reconnecting = autoReconnectingMacs.contains(mac)
        if let ctx = context(for: mac), ctx.connected || reconnecting {
            disconnect(mac: mac)
        } else if devices.contains(where: { $0.mac == mac }) {
            connect(mac: mac)
        } else {
            appLog("User: connect rejected (no device selected)", level: "W")
            statusText = "Select a device first"
        }
    }

    private func connect(mac: String, restoreParams: Bool = false) {
        controller.stopScan()
        scanning = false

        let name = devices.first { $0.mac == mac }?.name ?? mac
        appLog("User: connect \(name) (\(mac))")
        let p = controller.requireSensor(mac)
        p.delegate = self
        p.setAutoReconnect(autoReconnect)
        let ctx: DeviceContext
        if let kept = context(for: mac), !kept.isReplay, kept.profile === p {
            ctx = kept
            ctx.flowStarted = false
        } else {
            ctx = DeviceContext(profile: p)
            ctx.state.liveFilter.setBand(liveFilterBand)
            contextsLock.lock()
            contexts[mac] = ctx
            if !contextOrder.contains(mac) { contextOrder.append(mac) }
            contextsLock.unlock()
        }
        if restoreParams {
            pendingParamRestore.insert(mac)
        } else {
            pendingParamRestore.remove(mac)
        }
        statusText = "Connecting to \(mac)..."
        syncMirrors()
        if ctx === currentContext {
            connectionText = "Connecting..."
        }
        if p.isReady {
            startReadyFlow(p)
            return
        }
        p.connect { [weak self] ok, err in
            self?.onMain {
                guard let self = self else { return }
                guard ok else {
                    self.appLog("App: failed to connect to \(name) (\(mac))", level: "E", profile: p)
                    self.statusText = "Connect failed: \(err?.localizedDescription ?? "")"
                    self.syncMirrors()
                    return
                }
                self.startReadyFlow(p)
            }
        }
    }

    /// Ready-state entry: runs the connect chain once per session.
    private func startReadyFlow(_ p: SensorProfile) {
        guard let ctx = context(for: p.device.mac) else { return }
        guard !ctx.flowStarted else {
            if ctx === currentContext {
                statusText = ctx.state.buildStatusText(head: "Connected: \(p.device.name)")
            }
            return
        }
        ctx.flowStarted = true
        if !p.hasInited {
            statusText = "Initializing \(p.device.name)..."
            startInitChain(p)
        } else {
            afterInit(p)
        }
    }

    private func startInitChain(_ p: SensorProfile) {
        p.`init`(32, timeout: 5, powerRefreshInterval: 60) { [weak self] ok, err in
            self?.onMain {
                guard let self = self else { return }
                guard ok else {
                    self.appLog("App: failed to initialize \(p.device.name) (\(p.device.mac))",
                                level: "E", profile: p)
                    self.statusText = "Init failed: \(err?.localizedDescription ?? "")"
                    return
                }
                self.afterInit(p)
            }
        }
    }

    private func afterInit(_ p: SensorProfile) {
        guard let ctx = context(for: p.device.mac) else { return }
        let info = p.deviceInfo
        ctx.info = info
        ctx.modelText = "Model: \(info.modelName ?? "-")"
        ctx.hwText = "HW: \(info.hardwareVersion ?? "-")"
        ctx.fwText = "FW: \(info.firmwareVersion ?? "-")"
        applyLinkInfo(info, for: ctx)
        ctx.state.seedBioMode(from: info)
        syncMirrors()

        p.getParam(5, key: "NTF") { [weak self] result, _ in
            self?.onMain { self?.applyParamReadback(result, keys: AppModel.ntfKeys, for: ctx) }
        }
        p.getParam(5, key: "FILTER") { [weak self] result, _ in
            self?.onMain { self?.applyParamReadback(result, keys: AppModel.filterKeys, for: ctx) }
        }
        refreshEegSampleRateState(p, for: ctx)
        refreshAuxSampleRateStates(p, for: ctx)

        p.getBatteryLevel(5) { [weak self] level, _ in
            self?.onMain { _ = self?.filteredBattery(Int(level), for: ctx) }
        }

        if p.isDataTransfering {
            finishStart(p, ok: true, err: nil)
        } else {
            statusText = "Starting data notification..."
            p.startDataNotification(10) { [weak self] ok, err in
                self?.onMain { self?.finishStart(p, ok: ok, err: err) }
            }
        }
    }

    /// Stream-start tail of the connect chain.
    private func finishStart(_ p: SensorProfile, ok: Bool, err: Error?) {
        guard let ctx = context(for: p.device.mac) else { return }
        if ok {
            appLog("App: device connected and streaming: \(p.device.name) (\(p.device.mac))",
                   profile: p)
            statusText = "Streaming (\(p.device.name))"
            applySessionParams(ctx) { [weak self] in
                guard let self = self else { return }
                guard self.pendingParamRestore.remove(p.device.mac) != nil else { return }
                ctx.state.clearBuffers()
                self.restoreSavedParams(p, for: ctx)
            }
        } else {
            appLog("App: failed to start data stream on \(p.device.mac)",
                   level: "E", profile: p)
            statusText = "Start data failed: \(err?.localizedDescription ?? "")"
        }
        syncMirrors()
    }

    /// Disconnects one device.
    func disconnect(mac: String) {
        guard let ctx = context(for: mac) else { return }
        appLog("User: disconnect \(mac)", profile: ctx.profile)
        disconnectingMacs.insert(mac)
        pendingUserDisconnect.insert(mac)
        if ctx.profile.deviceState == .disconnected {
            handleDisconnected(ctx.profile)
            return
        }
        statusText = "Disconnecting..."
        ctx.profile.disconnect(nil)
    }

    // MARK: multi start / stop

    /// Connected, initialized device contexts in insertion order.
    private func readyContexts() -> [DeviceContext] {
        contextsLock.lock()
        defer { contextsLock.unlock() }
        return contextOrder.compactMap { contexts[$0] }.filter {
            $0.connected && !$0.isReplay && $0.profile.hasInited
        }
    }

    func multiStart() {
        let targets = readyContexts()
        guard !targets.isEmpty else {
            appLog("User: multi start rejected (no ready device)", level: "W")
            statusText = "No ready device for multi start"
            return
        }
        appLog("User: multi start (\(targets.count) device(s))")
        let streaming = targets.filter { $0.profile.isDataTransfering }.map { $0.profile }
        guard !streaming.isEmpty else {
            startMulti(targets)
            return
        }
        controller.multiStopDataNotification(streaming, timeoutMs: 10000) { [weak self] results, _ in
            let failed = results.filter { !$0.value.boolValue }.map { $0.key }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard failed.isEmpty else {
                    let macs = failed.joined(separator: ", ")
                    self.appLog("App: multi start aborted, stop failed on: \(macs)", level: "W")
                    self.statusText = "Multi start aborted: stop failed on \(macs)"
                    return
                }
                self.startMulti(targets)
            }
        }
    }

    private func startMulti(_ targets: [DeviceContext]) {
        let sameModel = Set(targets.map { $0.info?.modelName ?? "" }).count == 1
        statusText = "Multi starting ..."
        controller.multiStartDataNotification(targets.map { $0.profile },
                                              timeoutMs: sameModel ? 30000 : 60000,
                                              maxDelayDispersionMs: sameModel ? 5 : -1,
                                              maxAttempts: sameModel ? 3 : 5) { [weak self] results, errors in
            DispatchQueue.main.async {
                self?.reportMulti("start", total: targets.count,
                                  results: results, errors: errors)
            }
        }
    }

    func multiStop() {
        let targets = readyContexts().filter { $0.streaming }
        guard !targets.isEmpty else {
            appLog("User: multi stop rejected (no streaming device)", level: "W")
            statusText = "No streaming device for multi stop"
            return
        }
        appLog("User: multi stop (\(targets.count) device(s))")
        statusText = "Multi stopping ..."
        controller.multiStopDataNotification(targets.map { $0.profile },
                                             timeoutMs: 10000) { [weak self] results, errors in
            DispatchQueue.main.async {
                self?.reportMulti("stop", total: targets.count,
                                  results: results, errors: errors)
            }
        }
    }

    /// Per-device multi-op result line.
    private func reportMulti(_ action: String, total: Int,
                             results: [String: NSNumber]?, errors: [String: String]?) {
        let failed = (results ?? [:]).filter { !$0.value.boolValue }.map { $0.key }
        for mac in failed {
            appLog("App: multi \(action) failed on \(mac): \(errors?[mac] ?? "")", level: "W")
        }
        if failed.isEmpty {
            statusText = "Multi \(action): \(total) device(s) \(action == "start" ? "started" : "stopped")"
        } else {
            statusText = "Multi \(action) failed on: \(failed.joined(separator: ", "))"
        }
    }

    // MARK: link / MTU info

    private func applyLinkInfo(_ info: DeviceInfo, for ctx: DeviceContext) {
        if info.peripheralLatency < 0 || info.connectionIntervalMs <= 0 {
            ctx.linkText = "Link: --"
        } else {
            ctx.linkText = String(format: "Link: %gms / latency %d / timeout %dms",
                                  info.connectionIntervalMs, info.peripheralLatency,
                                  info.supervisionTimeoutMs)
        }
        ctx.mtuText = info.mtuSize > 0 ? "MTU: \(info.mtuSize)" : "MTU: --"
    }

    // MARK: EEG sample rate (getParam/setParam "EEG_SAMPLE_RATE")

    /// Re-reads the option list and the current bound rate.
    private func refreshEegSampleRateState(_ p: SensorProfile, for ctx: DeviceContext) {
        p.getParam(5, key: "EEG_SAMPLE_RATE_LIST") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                ctx.eegSampleRateOptions = result.hasPrefix("Error")
                    ? [] : result.split(separator: "|").compactMap { Int($0) }
                if ctx === self.currentContext {
                    self.eegSampleRateOptions = ctx.eegSampleRateOptions
                }
            }
        }
        p.getParam(5, key: "EEG_SAMPLE_RATE") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                if !result.hasPrefix("Error"), let rate = Int(result) {
                    ctx.eegSampleRate = rate
                    if ctx === self.currentContext {
                        self.eegSampleRate = rate
                    }
                }
            }
        }
    }

    func setEegSampleRate(_ rate: Int) {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return }
        guard rate != eegSampleRate, eegSampleRateOptions.contains(rate) else { return }
        ctx.eegSampleRate = rate
        eegSampleRate = rate
        let p = ctx.profile
        DispatchQueue.main.async { [weak self] in
            self?.applySampleRate(p, key: "EEG_SAMPLE_RATE", rate: rate, for: ctx)
        }
    }

    // MARK: EMG/IMU/PPG sample rates

    /// Re-reads the option lists and the current bound rates.
    private func refreshAuxSampleRateStates(_ p: SensorProfile, for ctx: DeviceContext) {
        p.getParam(5, key: "EMG_SAMPLE_RATE_LIST") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                ctx.emgSampleRateOptions = result.hasPrefix("Error")
                    ? [] : result.split(separator: "|").compactMap { Int($0) }
                if ctx === self.currentContext {
                    self.emgSampleRateOptions = ctx.emgSampleRateOptions
                }
            }
        }
        p.getParam(5, key: "EMG_SAMPLE_RATE") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                if !result.hasPrefix("Error"), let rate = Int(result) {
                    ctx.emgSampleRate = rate
                    if ctx === self.currentContext {
                        self.emgSampleRate = rate
                    }
                }
            }
        }
        p.getParam(5, key: "IMU_SAMPLE_RATE_LIST") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                ctx.imuSampleRateOptions = result.hasPrefix("Error")
                    ? [] : result.split(separator: "|").compactMap { Int($0) }
                if ctx === self.currentContext {
                    self.imuSampleRateOptions = ctx.imuSampleRateOptions
                }
            }
        }
        p.getParam(5, key: "IMU_SAMPLE_RATE") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                if !result.hasPrefix("Error"), let rate = Int(result) {
                    ctx.imuSampleRate = rate
                    if ctx === self.currentContext {
                        self.imuSampleRate = rate
                    }
                }
            }
        }
        p.getParam(5, key: "PPG_SAMPLE_RATE_LIST") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                ctx.ppgSampleRateOptions = result.hasPrefix("Error")
                    ? [] : result.split(separator: "|").compactMap { Int($0) }
                if ctx === self.currentContext {
                    self.ppgSampleRateOptions = ctx.ppgSampleRateOptions
                }
            }
        }
        p.getParam(5, key: "PPG_SAMPLE_RATE") { [weak self] result, _ in
            self?.onMain {
                guard let self = self else { return }
                if !result.hasPrefix("Error"), let rate = Int(result) {
                    ctx.ppgSampleRate = rate
                    if ctx === self.currentContext {
                        self.ppgSampleRate = rate
                    }
                }
            }
        }
    }

    func setEmgSampleRate(_ rate: Int) {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return }
        guard rate != emgSampleRate, emgSampleRateOptions.contains(rate) else { return }
        ctx.emgSampleRate = rate
        emgSampleRate = rate
        let p = ctx.profile
        DispatchQueue.main.async { [weak self] in
            self?.applySampleRate(p, key: "EMG_SAMPLE_RATE", rate: rate, for: ctx)
        }
    }

    func setImuSampleRate(_ rate: Int) {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return }
        guard rate != imuSampleRate, imuSampleRateOptions.contains(rate) else { return }
        ctx.imuSampleRate = rate
        imuSampleRate = rate
        let p = ctx.profile
        DispatchQueue.main.async { [weak self] in
            self?.applySampleRate(p, key: "IMU_SAMPLE_RATE", rate: rate, for: ctx)
        }
    }

    func setPpgSampleRate(_ rate: Int) {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return }
        guard rate != ppgSampleRate, ppgSampleRateOptions.contains(rate) else { return }
        ctx.ppgSampleRate = rate
        ppgSampleRate = rate
        let p = ctx.profile
        DispatchQueue.main.async { [weak self] in
            self?.applySampleRate(p, key: "PPG_SAMPLE_RATE", rate: rate, for: ctx)
        }
    }

    /// Sends the sample-rate setParam; failure reverts through a re-read.
    private func applySampleRate(_ p: SensorProfile, key: String, rate: Int, for ctx: DeviceContext) {
        guard ctx.connected, !ctx.isReplay else { return }
        p.setParam(5, key: key, value: "\(rate)") { [weak self] result, err in
            self?.onMain {
                guard let self = self else { return }
                self.appLog("User: setParam(\(key), \(rate)) -> \(result)", profile: p)
                self.recordSavedParam(ctx.mac, key: key, value: "\(rate)", result: result)
                if err != nil || result.hasPrefix("Error") || result.hasPrefix("ERROR:") {
                    self.statusText = "\(key) failed: \(err?.localizedDescription ?? result)"
                } else {
                    ctx.state.clearBuffers()
                }
                self.refreshEegSampleRateState(p, for: ctx)
                self.refreshAuxSampleRateStates(p, for: ctx)
            }
        }
    }

    // MARK: setParam

    func setParamToggle(key: String, on: Bool) {
        guard let ctx = currentContext, ctx.connected, !ctx.isReplay else { return }
        let p = ctx.profile
        let value = on ? "ON" : "OFF"
        p.setParam(5, key: key, value: value) { [weak self] result, err in
            self?.onMain {
                guard let self = self else { return }
                self.appLog("User: setParam(\(key), \(value)) -> \(result)", profile: p)
                self.recordSavedParam(ctx.mac, key: key, value: value, result: result)
                let failed = err != nil || result.hasPrefix("Error") || result.hasPrefix("ERROR:")
                if failed {
                    self.statusText = "\(key) failed: \(err?.localizedDescription ?? result)"
                } else {
                    ctx.state.clearBuffers()
                }
                if AppModel.ntfKeys.contains(key) {
                    p.getParam(5, key: "NTF") { [weak self] result, _ in
                        self?.onMain { self?.applyParamReadback(result, keys: AppModel.ntfKeys, for: ctx) }
                    }
                } else {
                    p.getParam(5, key: "FILTER") { [weak self] result, _ in
                        self?.onMain { self?.applyParamReadback(result, keys: AppModel.filterKeys, for: ctx) }
                    }
                }
            }
        }
    }

    /// Records a successful setParam for the auto-reconnect restore.
    private func recordSavedParam(_ mac: String, key: String, value: String, result: String) {
        if result.hasPrefix("Error") { return }
        var list = savedParamsByMac[mac] ?? []
        if let idx = list.firstIndex(where: { $0.key == key }) {
            list[idx].value = value
        } else {
            list.append((key, value))
        }
        savedParamsByMac[mac] = list
    }

    /// Replays the recorded setParam history, then re-syncs the controls.
    private func restoreSavedParams(_ p: SensorProfile, for ctx: DeviceContext) {
        let params = savedParamsByMac[p.device.mac] ?? []
        var step: ((Int) -> Void)?
        step = { [weak self] index in
            guard let self = self else { return }
            guard index < params.count else {
                step = nil
                p.getParam(5, key: "NTF") { [weak self] result, _ in
                    self?.onMain { self?.applyParamReadback(result, keys: AppModel.ntfKeys, for: ctx) }
                }
                p.getParam(5, key: "FILTER") { [weak self] result, _ in
                    self?.onMain { self?.applyParamReadback(result, keys: AppModel.filterKeys, for: ctx) }
                }
                self.refreshEegSampleRateState(p, for: ctx)
                self.refreshAuxSampleRateStates(p, for: ctx)
                return
            }
            let param = params[index]
            p.setParam(5, key: param.key, value: param.value) { [weak self] result, _ in
                self?.appLog("App: restore setParam(\(param.key), \(param.value)) -> \(result)",
                             profile: p)
                self?.onMain { step?(index + 1) }
            }
        }
        step?(0)
    }

    private func applyParamReadback(_ result: String, keys: [String], for ctx: DeviceContext) {
        let parts = result.split(separator: "|").map(String.init)
        var map: [String: String] = [:]
        var i = 0
        while i + 1 < parts.count {
            map[parts[i]] = parts[i + 1]
            i += 2
        }
        let isNtf = AppModel.ntfKeys.contains(keys.first ?? "")
        if isNtf {
            guard !result.hasPrefix("Error") else {
                ctx.ntfSupported = nil
                syncMirrors()
                return
            }
            let info = ctx.info
            let channelMap: [String: Int] = [
                "NTF_EEG": Int(info?.eegChannelCount ?? 0),
                "NTF_EMG": Int(info?.emgChannelCount ?? 0),
                "NTF_GEST": Int(info?.emgChannelCount ?? 0),
                "NTF_PPG": Int(info?.ppgChannelCount ?? 0),
                "NTF_SPO2": Int(info?.spo2ChannelCount ?? 0),
                "NTF_IMU": Int(max(info?.accChannelCount ?? 0, info?.gyroChannelCount ?? 0)),
            ]
            var supported = Set<String>()
            for key in keys {
                if (channelMap[key] ?? 0) > 0 {
                    supported.insert(key)
                    ctx.ntfStates[key] = map[key] == "ON"
                } else {
                    ctx.ntfStates[key] = false
                }
            }
            ctx.ntfSupported = supported
        } else {
            guard !result.hasPrefix("Error") else {
                ctx.filterSupported = nil
                syncMirrors()
                return
            }
            var supported = Set<String>()
            for key in keys where map[key] != nil {
                supported.insert(key)
                ctx.filterStates[key] = map[key] == "ON"
            }
            ctx.filterSupported = supported
        }
        syncMirrors()
    }

    func isParamVisible(_ key: String) -> Bool {
        if AppModel.ntfKeys.contains(key) {
            return ntfSupported?.contains(key) ?? true
        }
        return filterSupported?.contains(key) ?? true
    }

    /// EEG sample-rate section visibility.
    var eegSampleRateSectionVisible: Bool {
        !eegSampleRateOptions.isEmpty
    }

    /// EMG sample-rate section visibility.
    var emgSampleRateSectionVisible: Bool {
        !emgSampleRateOptions.isEmpty
    }

    /// IMU sample-rate section visibility.
    var imuSampleRateSectionVisible: Bool {
        !imuSampleRateOptions.isEmpty
    }

    /// PPG sample-rate section visibility.
    var ppgSampleRateSectionVisible: Bool {
        !ppgSampleRateOptions.isEmpty
    }

    /// EEG sample-rate candidate visibility.
    func isSampleRateVisible(_ rate: Int) -> Bool {
        eegSampleRateOptions.contains(rate)
    }

    /// EMG sample-rate candidate visibility.
    func isEmgSampleRateVisible(_ rate: Int) -> Bool {
        emgSampleRateOptions.contains(rate)
    }

    /// IMU sample-rate candidate visibility.
    func isImuSampleRateVisible(_ rate: Int) -> Bool {
        imuSampleRateOptions.contains(rate)
    }

    /// PPG sample-rate candidate visibility.
    func isPpgSampleRateVisible(_ rate: Int) -> Bool {
        ppgSampleRateOptions.contains(rate)
    }

    // MARK: bio paging

    /// EEG page count of the current device.
    var bioPageCount: Int {
        guard let ctx = currentContext, ctx.state.currentBioMode() == .eeg else { return 1 }
        let info = ctx.info
        let state = ctx.state
        let hasECG = Int(info?.ecgChannelCount ?? 0) > 0 || state.ecg.channelCount > 0
        let hasBRTH = Int(info?.brthChannelCount ?? 0) > 0 || state.brth.channelCount > 0
        let perPage = AppModel.bioSlotCount - (hasECG ? 1 : 0) - (hasBRTH ? 1 : 0)
        let reported = Int(info?.eegChannelCount ?? 0)
        let total = reported > 0 ? reported : state.eeg.channelCount
        guard perPage > 0, total > 0 else { return 1 }
        return max(1, (total + perPage - 1) / perPage)
    }

    /// Prev/Next page of the Bio panel.
    func bioPage(_ delta: Int) {
        guard let ctx = currentContext else { return }
        let pages = bioPageCount
        let newPage = min(max(ctx.bioPageIndex + delta, 0), pages - 1)
        guard newPage != ctx.bioPageIndex else { return }
        ctx.bioPageIndex = newPage
        appLog("User: \(delta < 0 ? "prev" : "next") page -> \(newPage)", level: "D")
        bioPageIndex = newPage
    }

    // MARK: battery

    /// Stable-band filter for the explicit battery read.
    private func filteredBattery(_ value: Int, for ctx: DeviceContext) -> Int? {
        guard value >= 0 else { return nil }
        if ctx.batteryLevel < 0 || abs(value - ctx.batteryLevel) >= 4 {
            ctx.batteryLevel = value
            ctx.batteryText = "Power: \(value)%"
            if ctx === currentContext {
                batteryText = ctx.batteryText
            }
            return value
        }
        return nil
    }

    // MARK: session params

    /// Per-device session params: the profile log redirect and the bin-data
    /// recording.
    private func applySessionParams(_ ctx: DeviceContext, completion: (() -> Void)? = nil) {
        if debugLogEnabled {
            applyDebugLogPath(for: ctx) { [weak self] in
                guard let self = self else { return }
                if self.debugBinEnabled {
                    self.applyDebugBin(for: ctx, completion: completion)
                } else {
                    completion?()
                }
            }
        } else if debugBinEnabled {
            applyDebugBin(for: ctx, completion: completion)
        } else {
            completion?()
        }
    }

    private func applyDebugLogPath(for ctx: DeviceContext, completion: (() -> Void)? = nil) {
        let p = ctx.profile
        guard ctx.connected, p.hasInited else { completion?(); return }
        let mac = ctx.mac
        let path = lastLogPaths[mac] ?? "True"
        p.setParam(5, key: "DEBUG_LOG_PATH", value: path) { [weak self] result, err in
            self?.onMain {
                guard let self = self else { return }
                self.appLog("App: setParam(DEBUG_LOG_PATH, \(path)) -> \(result)", profile: p)
                let failed = err != nil || result.hasPrefix("Error") || result.hasPrefix("ERROR:")
                if !failed {
                    p.getParam(5, key: "DEBUG_LOG_PATH") { [weak self] result, _ in
                        self?.onMain {
                            if !result.isEmpty && !result.hasPrefix("Error") {
                                self?.lastLogPaths[mac] = result
                            }
                        }
                    }
                }
                completion?()
            }
        }
    }

    private func applyDebugBin(for ctx: DeviceContext, completion: (() -> Void)? = nil) {
        let p = ctx.profile
        guard ctx.connected, p.hasInited else { completion?(); return }
        let mac = ctx.mac
        let path = lastDataPaths[mac] ?? "True"
        p.setParam(5, key: "DEBUG_BLE_DATA_PATH", value: path) { [weak self] result, err in
            self?.onMain {
                guard let self = self else { return }
                self.appLog("App: setParam(DEBUG_BLE_DATA_PATH, \(path)) -> \(result)", profile: p)
                let failed = err != nil || result.hasPrefix("Error") || result.hasPrefix("ERROR:")
                if !failed {
                    p.getParam(5, key: "DEBUG_BLE_DATA_PATH") { [weak self] result, _ in
                        self?.onMain {
                            if !result.isEmpty && !result.hasPrefix("Error") {
                                self?.lastDataPaths[mac] = result
                            }
                        }
                    }
                }
                completion?()
            }
        }
    }

    /// Literal True/False session-param write for the debug toggles.
    private func sendSessionParam(_ p: SensorProfile, key: String, value: String) {
        p.setParam(5, key: key, value: value) { [weak self] result, _ in
            self?.appLog("App: setParam(\(key), \(value)) -> \(result)", profile: p)
        }
    }

    // MARK: debug log

    private func applyDebugLog() {
        if debugLogEnabled {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let stamp = {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd_HHmmss"
                return f.string(from: Date())
            }()
            let version = controller.getVersion().replacingOccurrences(of: ".", with: "_")
            let path = dir.appendingPathComponent("sensorsdklog/\(stamp)_\(version)").path
            _ = controller.setParam("LOG_PATH", value: path)
            storageText = "Logs & bins: \(path)"
        } else {
            storageText = ""
        }
        _ = controller.setParam("DEBUG_ENABLED", value: debugLogEnabled ? "True" : "False")
    }

    // MARK: bin replay / parse

    /// Replay entry guard: no live devices, no active replay.
    private func canStartReplay() -> Bool {
        contextsLock.lock()
        let busy = !contexts.isEmpty
        contextsLock.unlock()
        guard !busy else {
            appLog("User: replay rejected (devices still connected)", level: "W")
            statusText = "Please disconnect all devices before replaying a bin file"
            return false
        }
        return replayMacs.isEmpty
    }

    private func stopScanForReplay() {
        if controller.isScanning {
            appLog("Stop scan")
            controller.stopScan()
            scanning = false
        }
    }

    /// Registers one started replay member.
    private func addReplayMember(_ p: SensorProfile, info: BinFileInfo) {
        let mac = info.mac
        p.delegate = self
        replayProfiles[mac] = p
        replayMacs.append(mac)
        replayNames[mac] = info.deviceName
        let ctx = DeviceContext(profile: p)
        ctx.isReplay = true
        ctx.flowStarted = true
        ctx.state.liveFilter.setBand(liveFilterBand)
        if info.deviceInfo.eegSampleRate > 0 {
            ctx.eegSampleRate = Int(info.deviceInfo.eegSampleRate)
        }
        if info.deviceInfo.emgSampleRate > 0 {
            ctx.emgSampleRate = Int(info.deviceInfo.emgSampleRate)
        }
        if info.deviceInfo.accSampleRate > 0 {
            ctx.imuSampleRate = Int(info.deviceInfo.accSampleRate)
        }
        if info.deviceInfo.ppgSampleRate > 0 {
            ctx.ppgSampleRate = Int(info.deviceInfo.ppgSampleRate)
        }
        contextsLock.lock()
        contexts[mac] = ctx
        if !contextOrder.contains(mac) { contextOrder.append(mac) }
        contextsLock.unlock()
    }

    /// Starts a bin replay session.
    func replayBin(url: URL) {
        guard canStartReplay() else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let path = url.path
        appLog("User: replay bin file: \(path)")
        guard let info = controller.getBinFileInfo(path), info.valid, !info.mac.isEmpty else {
            appLog("App: invalid bin file (no config record): \(path)", level: "W")
            statusText = "Invalid bin file: no config record found"
            replayText = statusText
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        stopScanForReplay()
        let mac = info.mac
        guard let p = controller.replayBinFile(path, deviceMac: mac, realtime: true, timeout: 5) else {
            statusText = "Replay failed to start"
            replayText = statusText
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        replayStopRequested = false
        replayPaused = false
        if accessing { replayScopedUrls.append(url) }
        addReplayMember(p, info: info)
        selectedMac = mac
        syncMirrors()
        let text = "Replaying: \(url.lastPathComponent) (duration " +
            String(format: "%.1f", info.durationSec) + "s, realtime) ..."
        statusText = text
        replayText = text
    }

    /// Starts a synchronized group replay of several bin files.
    func replayBinGroup(urls: [URL]) {
        guard urls.count >= 2 else {
            appLog("User: multi replay rejected (needs at least 2 bin files)", level: "W")
            statusText = "Multi replay needs at least 2 bin files"
            return
        }
        guard canStartReplay() else { return }
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            scoped.append(url)
        }
        var paths: [String] = []
        var macs: [String] = []
        var infos: [String: BinFileInfo] = [:]
        var names: [String: String] = [:]
        for url in urls {
            let path = url.path
            appLog("User: replay bin file: \(path)")
            guard let info = controller.getBinFileInfo(path), info.valid, !info.mac.isEmpty else {
                appLog("App: invalid bin file (no config record): \(path)", level: "W")
                continue
            }
            guard !macs.contains(info.mac) else {
                appLog("App: duplicate replay mac skipped: \(info.mac) (\(path))", level: "W")
                continue
            }
            paths.append(path)
            macs.append(info.mac)
            infos[info.mac] = info
            names[info.mac] = url.lastPathComponent
        }
        guard !paths.isEmpty else {
            statusText = "Invalid bin file: no config record found"
            replayText = statusText
            for url in scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        stopScanForReplay()
        let results = controller.multiReplayBinFile(paths, deviceMacs: macs,
                                                    realtime: true, timeout: 5)
        replayStopRequested = false
        replayPaused = false
        var started: [String] = []
        for i in paths.indices {
            guard i < results.count, let p = results[i] as? SensorProfile,
                  let info = infos[macs[i]] else {
                appLog("App: replay member failed to start: \(paths[i])", level: "W")
                continue
            }
            addReplayMember(p, info: info)
            started.append(names[macs[i]] ?? paths[i])
        }
        guard !replayMacs.isEmpty else {
            statusText = "Replay failed to start"
            replayText = statusText
            for url in scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        replayScopedUrls.append(contentsOf: scoped)
        selectedMac = replayMacs.first
        syncMirrors()
        let text = "Replaying: \(started.joined(separator: " + ")) (realtime) ..."
        statusText = text
        replayText = text
    }

    /// Drops one replay member's context; idempotent.
    private func removeReplayContext(mac: String) {
        contextsLock.lock()
        contexts.removeValue(forKey: mac)
        contextOrder.removeAll { $0 == mac }
        contextsLock.unlock()
        replayProfiles.removeValue(forKey: mac)
        replayMacs.removeAll { $0 == mac }
        replayNames.removeValue(forKey: mac)
        if selectedMac == mac {
            selectedMac = replayMacs.first
        }
        syncMirrors()
    }

    /// Single pause/resume toggle.
    func toggleReplayPause() {
        guard let mac = replayMacs.first else { return }
        let action = replayPaused ? "resume" : "pause"
        let result = replayPaused
            ? controller.resumeBinReplay(mac)
            : controller.pauseBinReplay(mac)
        appLog("User: \(action) replay -> \(result)", level: result == "OK" ? "I" : "W",
               profile: replayProfiles[mac])
        guard result == "OK" else {
            statusText = "Replay pause/resume failed: \(result)"
            return
        }
        replayPaused.toggle()
        statusText = replayPaused ? "Replay paused" : "Replaying ..."
    }

    func stopReplay() {
        let macs = replayMacs
        guard !macs.isEmpty else { return }
        replayStopRequested = true
        DispatchQueue.global().async { [weak self] in
            var failed = ""
            for mac in macs {
                let result = self?.controller.stopBinReplay(mac) ?? ""
                if result != "OK" { failed = result }
                self?.onMain {
                    guard let self = self else { return }
                    self.appLog("User: stop replay -> \(result)",
                                level: result == "OK" ? "I" : "W",
                                profile: self.replayProfiles[mac])
                }
            }
            self?.onMain {
                guard let self = self else { return }
                if !failed.isEmpty {
                    self.statusText = "Stop replay failed: \(failed)"
                    self.replayStopRequested = false
                } else {
                    self.statusText = "Stopping replay ..."
                }
            }
        }
    }

    /// Replay teardown of one member; idempotent.
    private func finishReplay(_ message: String, mac: String) {
        guard let p = replayProfiles[mac] else { return }
        appLog("App: replay done: \(message)", profile: p)
        removeReplayContext(mac: mac)
        guard replayMacs.isEmpty else { return }
        for url in replayScopedUrls { url.stopAccessingSecurityScopedResource() }
        replayScopedUrls.removeAll()
        replayStopRequested = false
        replayPaused = false
        statusText = message
        replayText = message
    }

    /// Parses a bin file to CSV next to it.
    func parseBinToCsv(url: URL) {
        guard !analyzing else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let binPath = url.path
        let csvPath = url.deletingPathExtension().appendingPathExtension("csv").path
        appLog("User: analyze bin file: \(binPath)")
        analyzing = true
        if accessing { parseScopedUrls.append(url) }
        replayText = "Analyzing: \(url.lastPathComponent) ..."
        DispatchQueue.global().async { [weak self] in
            let result = self?.controller.parseBin(toCsv: binPath, csvPath: csvPath) ?? ""
            self?.onMain {
                guard let self = self else { return }
                self.analyzing = false
                for scopedUrl in self.parseScopedUrls {
                    scopedUrl.stopAccessingSecurityScopedResource()
                }
                self.parseScopedUrls.removeAll()
                if result.hasPrefix("Error") {
                    self.appLog("App: analyze failed: \(result)", level: "E")
                    self.replayText = "Analyze failed: \(result)"
                } else {
                    self.appLog("App: CSV saved: \(result)")
                    self.replayText = "CSV saved: \(result)"
                    #if os(macOS)
                    NSWorkspace.shared.selectFile(
                        result, inFileViewerRootedAtPath: (result as NSString).deletingLastPathComponent)
                    #endif
                }
            }
        }
    }
}

// MARK: - SensorControllerDelegate

extension AppModel: SensorControllerDelegate {
    func onEnableChanged(_ enabled: Bool) {
        onMain {
            if !enabled {
                self.scanning = false
                self.statusText = "Bluetooth turned off"
            }
        }
    }

    func onScanResult(_ bleDevices: [BLEDevice]) {
        onMain { self.mergeDevices(bleDevices) }
    }
}

// MARK: - SensorProfileDelegate

extension AppModel: SensorProfileDelegate {
    func onData(_ profile: SensorProfile, dataList: [SensorData]) {
        guard let ctx = context(for: profile.device.mac) else { return }
        dataModeLock.lock()
        let cloning = cloneDataMode
        dataModeLock.unlock()
        if cloning {
            for b in dataList {
                enqueueData(ctx.state, b.clone())
            }
        } else {
            for b in dataList {
                enqueueData(ctx.state, b)
            }
        }
    }

    func onStateChanged(_ profile: SensorProfile, newState: BLEState) {
        onMain {
            if self.replayProfiles[profile.device.mac] != nil {
                if newState == .disconnected {
                    self.finishReplay("Replay finished", mac: profile.device.mac)
                }
                return
            }
            switch newState {
            case .ready:
                let mac = profile.device.mac
                self.disconnectingMacs.remove(mac)
                self.autoReconnectingMacs.remove(mac)
                self.startReadyFlow(profile)
                self.syncMirrors()
            case .disconnected:
                self.handleDisconnected(profile)
            default:
                self.syncMirrors()
            }
        }
    }

    /// Final-disconnect handling.
    private func handleDisconnected(_ profile: SensorProfile) {
        let mac = profile.device.mac
        guard let ctx = context(for: mac) else { return }
        disconnectingMacs.remove(mac)
        let byUser = pendingUserDisconnect.remove(mac) != nil
        if !byUser && autoReconnect {
            autoReconnectingMacs.insert(mac)
            appLog("App: connection lost, auto reconnecting: \(mac)", level: "W", profile: profile)
            if currentContext === ctx {
                statusText = "Connection lost, auto reconnecting ..."
            }
            syncMirrors()
            return
        }
        autoReconnectingMacs.remove(mac)
        let wasCurrent = currentContext === ctx
        appLog("App: device disconnected, removed from UI: \(mac)", profile: profile)
        ctx.ntfStates = [:]
        ctx.filterStates = [:]
        ctx.ntfSupported = nil
        ctx.filterSupported = nil
        ctx.eegSampleRateOptions = []
        ctx.eegSampleRate = 0
        ctx.emgSampleRateOptions = []
        ctx.emgSampleRate = 0
        ctx.imuSampleRateOptions = []
        ctx.imuSampleRate = 0
        ctx.ppgSampleRateOptions = []
        ctx.ppgSampleRate = 0
        ctx.streaming = false
        contextsLock.lock()
        contexts.removeValue(forKey: mac)
        contextOrder.removeAll { $0 == mac }
        contextsLock.unlock()
        if selectedMac == mac {
            selectedMac = nil
        }
        if wasCurrent {
            statusText = "Disconnected (device)"
            rateText = ""
        }
        syncMirrors()
    }

    /// SDK auto-reconnect query: the app drives the normal connect flow itself.
    func onAutoReconnect(_ profile: SensorProfile, hasLastSession: Bool, answer: (Bool) -> Void) {
        profile.log("App: auto reconnect callback received, restore=\(hasLastSession)")
        let mac = profile.device.mac
        onMain { self.pressConnectForAutoReconnect(mac, restore: hasLastSession) }
        answer(true)
    }

    /// Auto-reconnect: selects the row and drives the normal connect flow.
    private func pressConnectForAutoReconnect(_ mac: String, restore: Bool) {
        if devices.contains(where: { $0.mac == mac }) {
            selectedMac = mac
        }
        connect(mac: mac, restoreParams: restore)
    }

    func onError(_ profile: SensorProfile, err: Error) {
        profile.log("App: error callback: \(err.localizedDescription)", level: "E")
        onMain { self.statusText = err.localizedDescription }
    }

    func onPowerChanged(_ profile: SensorProfile, power: Int32) {
        onMain {
            guard let ctx = self.context(for: profile.device.mac) else { return }
            let level = Int(power)
            guard level >= 0 else { return }
            ctx.batteryLevel = level
            ctx.batteryText = "Power: \(level)%"
            if ctx === self.currentContext {
                self.batteryText = ctx.batteryText
            }
        }
    }

    /// Data stream on/off push.
    func onDataTransferStateChange(_ profile: SensorProfile, isTransferring: Bool) {
        appLog("App: data stream \(isTransferring ? "ON" : "OFF") \(profile.device.mac)", profile: profile)
        onMain {
            guard let ctx = self.context(for: profile.device.mac) else { return }
            ctx.streaming = isTransferring
            self.syncMirrors()
            let mac = profile.device.mac
            guard self.replayProfiles[mac] != nil else { return }
            if !isTransferring {
                // Replay EOF (or a user stop): finish the member here.
                self.finishReplay(self.replayStopRequested ? "Replay stopped" : "Replay finished",
                                  mac: mac)
            }
        }
    }

    func onDeviceInfoUpdate(_ profile: SensorProfile, info: DeviceInfo) {        onMain {
            guard let ctx = self.context(for: profile.device.mac) else { return }
            ctx.info = info
            ctx.state.syncSampleRates(from: info)
            self.applyLinkInfo(info, for: ctx)
            if info.eegSampleRate > 0 && Int(info.eegSampleRate) != ctx.eegSampleRate {
                ctx.eegSampleRate = Int(info.eegSampleRate)
            }
            if info.emgSampleRate > 0 && Int(info.emgSampleRate) != ctx.emgSampleRate {
                ctx.emgSampleRate = Int(info.emgSampleRate)
            }
            if info.accSampleRate > 0 && Int(info.accSampleRate) != ctx.imuSampleRate {
                ctx.imuSampleRate = Int(info.accSampleRate)
            }
            if info.ppgSampleRate > 0 && Int(info.ppgSampleRate) != ctx.ppgSampleRate {
                ctx.ppgSampleRate = Int(info.ppgSampleRate)
            }
            self.syncMirrors()
        }
    }

}
