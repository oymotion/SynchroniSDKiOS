import Foundation

/// Per-device stream state.

enum BioMode {
    case none, emg, eeg, ppg
}

final class RingBuffer {
    private let lock = NSLock()
    private var buf: [Float] = []
    private(set) var channelCount = 0
    private(set) var capacity = 0
    /// Sample rate the buffer was allocated for.
    private(set) var sampleRate: Float = 0
    private var writeIndex = 0
    private(set) var filled = 0

    func ensure(channels: Int, capacity: Int, rate: Float) {
        guard channels > 0, capacity > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if channels != channelCount || capacity != self.capacity {
            channelCount = channels
            self.capacity = capacity
            sampleRate = rate
            buf = [Float](repeating: 0, count: channels * capacity)
            writeIndex = 0
            filled = 0
        }
    }

    /// Rebuilds the buffer at a new sample rate.
    @discardableResult
    func reallocate(rate: Float, seconds: Int) -> Bool {
        guard rate > 0 else { return false }
        let newCapacity = max(1, Int(rate.rounded()) * max(1, seconds))
        lock.lock()
        defer { lock.unlock() }
        guard channelCount > 0, capacity > 0, newCapacity != capacity else { return false }
        capacity = newCapacity
        sampleRate = rate
        buf = [Float](repeating: 0, count: channelCount * capacity)
        writeIndex = 0
        filled = 0
        return true
    }

    /// Appends one sample column (one value per channel).
    func appendColumn(_ values: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard channelCount > 0, capacity > 0 else { return }
        for ch in 0..<channelCount {
            buf[ch * capacity + writeIndex] = ch < values.count ? values[ch] : 0
        }
        writeIndex = (writeIndex + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// Ordered oldest -> newest samples of one channel (for drawing).
    func snapshot(channel ch: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard ch >= 0, ch < channelCount, filled > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(filled)
        let start = (writeIndex - filled + capacity) % capacity
        for i in 0..<filled {
            out.append(buf[ch * capacity + (start + i) % capacity])
        }
        return out
    }

    /// back = 0 -> newest sample.
    func value(ch: Int, back: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard ch >= 0, ch < channelCount, back >= 0, back < filled, capacity > 0 else { return 0 }
        return buf[ch * capacity + (writeIndex - 1 - back + capacity) % capacity]
    }

    func latest(_ ch: Int) -> Float { value(ch: ch, back: 0) }

    /// Zeroes the content and rewinds the write index.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard capacity > 0 else { return }
        buf = [Float](repeating: 0, count: channelCount * capacity)
        writeIndex = 0
        filled = 0
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buf = []
        channelCount = 0
        capacity = 0
        sampleRate = 0
        writeIndex = 0
        filled = 0
    }
}

/// Latest gesture record (NTF_GEST).
struct GestureRecord {
    var gesture = -1
    var rawGesture = -1
    var possibility = -1
    var strength = -1
}

final class DeviceState {
    private let lock = NSLock()

    // IMU rings
    let acc = RingBuffer()
    let gyro = RingBuffer()
    let euler = RingBuffer()
    let quat = RingBuffer() // channels w, x, y, z
    // bio rings
    let emg = RingBuffer()
    let eeg = RingBuffer()
    let ecg = RingBuffer()
    let brth = RingBuffer()
    let ppg = RingBuffer()
    let spo2 = RingBuffer()

    private(set) var bioMode: BioMode = .none
    private(set) var gesture = GestureRecord()
    /// Impedance per stream (NotifyDataType raw value) per channel, Ohm-ish units as delivered.
    private(set) var impedance: [Int: [Float]] = [:]

    /// Live Filter: bandpass applied to the bio streams.
    let liveFilter = LiveFilter()
    /// Bumped by every reset().
    private var epoch = 0

    // counters
    private(set) var batchCount = 0
    private(set) var sampleTotal = 0
    private(set) var lostPackages = 0

    // Per-type accounting for the stats/rate labels.
    private var rateCounts: [Int: Int64] = [:]     // valid samples in the current window
    private var actualRates: [Int: Double] = [:]   // rotated once per second
    private var nominalRates: [Int: Float] = [:]   // batch-reported sample rate
    private var nominalChannels: [Int: Int] = [:]  // batch-reported channel count
    private var lostCounts: [Int: Int] = [:]       // latest per-type lostPackageCount
    private var rateWindowStart = Date()
    /// Stream-start wall clock (Unix seconds) and first-packet delay (ms).
    private var streamStartTimeSec: Double = 0
    private var streamDelayMs: UInt32 = 0

    /// Per-type stats display order and labels.
    static let typeDisplayOrder: [(NotifyDataType, String)] = [
        (.NTF_ACC, "ACC"), (.NTF_GYRO, "Gyro"), (.NTF_IMU, "IMU"),
        (.NTF_QUATERNION, "Quat"), (.NTF_EULER, "Euler"), (.NTF_EMG, "EMG"),
        (.NTF_EEG, "EEG"), (.NTF_PPG, "PPG"), (.NTF_SPO2, "SpO2"),
        (.NTF_ECG, "ECG"), (.NTF_BRTH, "BRTH"), (.NTF_GEST, "GEST"),
    ]

    private static let startTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let bioSeconds = 1
    private static let imuSeconds = 5

    func reset() {
        lock.lock()
        bioMode = .none
        gesture = GestureRecord()
        impedance = [:]
        batchCount = 0
        sampleTotal = 0
        lostPackages = 0
        rateCounts = [:]
        actualRates = [:]
        nominalRates = [:]
        nominalChannels = [:]
        lostCounts = [:]
        rateWindowStart = Date()
        streamStartTimeSec = 0
        streamDelayMs = 0
        epoch += 1
        lock.unlock()
        liveFilter.reset()
        for ring in [acc, gyro, euler, quat, emg, eeg, ecg, brth, ppg, spo2] {
            ring.reset()
        }
    }

    /// Zeroes every ring's content and drops the impedance / gesture
    /// readouts.
    func clearBuffers() {
        for ring in [acc, gyro, euler, quat, emg, eeg, ecg, brth, ppg, spo2] {
            ring.clear()
        }
        lock.lock()
        impedance = impedance.mapValues { [Float](repeating: -1, count: $0.count) }
        gesture = GestureRecord()
        lock.unlock()
    }

    func currentEpoch() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Seeds the bio mode from DeviceInfo (PPG > EEG > EMG).
    func seedBioMode(from info: DeviceInfo) {
        lock.lock()
        defer { lock.unlock() }
        if info.ppgSampleRate > 0 {
            bioMode = .ppg
        } else if info.eegSampleRate > 0 && info.eegChannelCount > 0 {
            bioMode = .eeg
        } else if info.emgSampleRate > 0 && info.emgChannelCount > 0 {
            bioMode = .emg
        }
    }

    func append(_ batches: [SensorData]) {
        for b in batches {
            lock.lock()
            batchCount += 1
            sampleTotal += Int(b.channelCount) * Int(b.sampleCount)
            lostPackages += Int(b.lostPackageCount)
            lock.unlock()
            accountBatch(b)
            route(b)
        }
    }

    /// Per-type stats bookkeeping for one batch.
    private func accountBatch(_ b: SensorData) {
        let fresh = b.isDataValid()
        lock.lock()
        defer { lock.unlock() }
        let type = Int(b.dataType.rawValue)
        if b.lostPackageCount > 0 {
            lostCounts[type] = Int(b.lostPackageCount)
        }
        if b.samplesPointer != nil && b.sampleCount > 0 && b.channelCount > 0 {
            let enabled = b.isChannelEnabled(atChannel: 0)
            var valid = 0
            for i in 0..<Int(b.sampleCount) {
                if fresh && enabled && !b.isLost(atChannel: 0, index: Int32(i)) {
                    valid += 1
                }
            }
            if valid > 0 {
                rateCounts[type] = (rateCounts[type] ?? 0) + Int64(valid)
            }
        }
        if b.sampleRate > 0 {
            nominalRates[type] = b.sampleRate
        }
        if b.channelCount > 0 {
            nominalChannels[type] = Int(b.channelCount)
        }
        if b.startTimeSec > 0 {
            streamStartTimeSec = b.startTimeSec
        }
        if b.delay > 0 {
            streamDelayMs = b.delay
        }
    }

    /// Per-segment rate bookkeeping of an NTF_IMU aggregate batch.
    private func accountImuSegments(_ b: SensorData, fresh: Bool) {
        let segs: [(NotifyDataType, Int, Int)] = [
            (.NTF_ACC, 0, 3), (.NTF_GYRO, 3, 3), (.NTF_EULER, 6, 3), (.NTF_QUATERNION, 9, 4),
        ]
        let sampleCount = Int(b.sampleCount)
        guard b.samplesPointer != nil, sampleCount > 0 else { return }
        let enabled = b.isChannelEnabled(atChannel: 0)
        lock.lock()
        defer { lock.unlock() }
        for (type, offset, count) in segs {
            guard Int(b.channelCount) >= offset + count else { continue }
            var valid = 0
            for i in 0..<sampleCount {
                if fresh && enabled && !b.isLost(atChannel: Int32(offset), index: Int32(i)) {
                    valid += 1
                }
            }
            let t = Int(type.rawValue)
            if valid > 0 {
                rateCounts[t] = (rateCounts[t] ?? 0) + Int64(valid)
            }
            if b.sampleRate > 0 {
                nominalRates[t] = b.sampleRate
            }
            nominalChannels[t] = count
        }
    }

    /// Rotates the accumulated per-type sample counts into actualRates; call
    /// once per second.
    func updateActualRates() {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        let elapsed = now.timeIntervalSince(rateWindowStart)
        guard elapsed > 0 else { return }
        actualRates.removeAll()
        for (t, c) in rateCounts {
            actualRates[t] = Double(c) / elapsed
        }
        rateCounts.removeAll()
        rateWindowStart = now
    }

    private static func hzText(_ rate: Float) -> String {
        String(format: "%g", rate)
    }

    /// Status line.
    func buildStatusText(head: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        var parts = [head]
        for (type, label) in DeviceState.typeDisplayOrder {
            let t = Int(type.rawValue)
            let rate = nominalRates[t] ?? 0
            let ch = nominalChannels[t] ?? 0
            guard rate > 0 || ch > 0 else { continue }
            parts.append(ch > 0
                ? "\(label) \(ch)ch @ \(DeviceState.hzText(rate))Hz"
                : "\(label) @ \(DeviceState.hzText(rate))Hz")
        }
        return parts.joined(separator: " | ")
    }

    /// Measured-vs-nominal rate line.
    func buildRateText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var entries: [String] = []
        for (type, label) in DeviceState.typeDisplayOrder {
            let t = Int(type.rawValue)
            guard let actual = actualRates[t] else { continue }
            let nominal = nominalRates[t] ?? 0
            let nominalText = nominal > 0 ? DeviceState.hzText(nominal) : "--"
            entries.append("\(label) \(String(format: "%.1f", actual)) / \(nominalText)Hz")
        }
        if streamStartTimeSec > 0 {
            let start = Date(timeIntervalSince1970: streamStartTimeSec)
            entries.append("start \(DeviceState.startTimeFormatter.string(from: start))")
        }
        if streamDelayMs > 0 {
            entries.append("delay \(streamDelayMs)ms")
        }
        return entries.isEmpty ? "" : "Actual: " + entries.joined(separator: " | ")
    }

    /// Packet-loss line.
    func lostPacketText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !lostCounts.isEmpty else { return "Packet Loss Stats: None" }
        let parts = lostCounts
            .map { (DeviceState.typeName($0.key), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0): \($0.1)" }
        return "Packet Loss Stats: " + parts.joined(separator: "  ")
    }

    /// Short label for a NotifyDataType raw value.
    static func typeName(_ rawValue: Int) -> String {
        guard let type = NotifyDataType(rawValue: rawValue) else {
            return "TYPE_\(rawValue)"
        }
        switch type {
        case .NTF_ACC: return "ACC"
        case .NTF_GYRO: return "GYRO"
        case .NTF_EULER: return "EULER"
        case .NTF_QUATERNION: return "QUAT"
        case .NTF_GEST: return "GEST"
        case .NTF_EMG: return "EMG"
        case .NTF_MAG_ANGLE: return "MAG"
        case .NTF_EEG: return "EEG"
        case .NTF_PPG: return "PPG"
        case .NTF_SPO2: return "SPO2"
        case .NTF_ECG: return "ECG"
        case .NTF_IMPEDANCE: return "IMP"
        case .NTF_IMU: return "IMU"
        case .NTF_ADS: return "ADS"
        case .NTF_BRTH: return "BRTH"
        case .NTF_IMPEDANCE_EXT: return "IMP_EXT"
        default: return "TYPE_\(rawValue)"
        }
    }

    func countersText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "batches: \(batchCount), samples: \(sampleTotal), lost packages: \(lostPackages)"
    }

    func currentBioMode() -> BioMode {
        lock.lock()
        defer { lock.unlock() }
        return bioMode
    }

    func currentGesture() -> GestureRecord {
        lock.lock()
        defer { lock.unlock() }
        return gesture
    }

    func impedance(for type: NotifyDataType) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return impedance[type.rawValue] ?? []
    }

    // MARK: - routing

    private func route(_ b: SensorData) {
        switch b.dataType {
        case .NTF_IMU:
            // Aggregate: acc 0-2 / gyro 3-5 / euler 6-8 / quat 9-12 (w,x,y,z).
            accountImuSegments(b, fresh: b.isDataValid())
            feedSegment(b, ring: acc, firstChannel: 0, channels: 3, seconds: DeviceState.imuSeconds)
            feedSegment(b, ring: gyro, firstChannel: 3, channels: 3, seconds: DeviceState.imuSeconds)
            if b.channelCount >= 13 {
                feedSegment(b, ring: euler, firstChannel: 6, channels: 3, seconds: DeviceState.imuSeconds)
                feedSegment(b, ring: quat, firstChannel: 9, channels: 4, seconds: DeviceState.imuSeconds)
            }
        case .NTF_ACC:
            feedSegment(b, ring: acc, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds)
        case .NTF_GYRO:
            feedSegment(b, ring: gyro, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds)
        case .NTF_EULER:
            feedSegment(b, ring: euler, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds)
        case .NTF_QUATERNION:
            feedSegment(b, ring: quat, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds)
        case .NTF_EMG:
            feedSegment(b, ring: emg, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.bioSeconds, bio: true)
            captureImpedance(b, type: .NTF_EMG)
            repairBioMode(.emg)
        case .NTF_EEG:
            feedSegment(b, ring: eeg, firstChannel: 0, channels: Int(b.channelCount),
                        seconds: eegWindowSeconds(), bio: true)
            captureImpedance(b, type: .NTF_EEG)
            repairBioMode(.eeg)
        case .NTF_ECG:
            feedSegment(b, ring: ecg, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.bioSeconds, bio: true)
            captureImpedance(b, type: .NTF_ECG)
        case .NTF_BRTH:
            feedSegment(b, ring: brth, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.bioSeconds, bio: true)
        case .NTF_PPG:
            feedSegment(b, ring: ppg, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds, bio: true)
            repairBioMode(.ppg)
        case .NTF_SPO2:
            feedSegment(b, ring: spo2, firstChannel: 0, channels: Int(b.channelCount), seconds: DeviceState.imuSeconds, bio: true)
            repairBioMode(.ppg)
        case .NTF_IMPEDANCE, .NTF_IMPEDANCE_EXT:
            captureImpedance(b, type: b.dataType)
        case .NTF_GEST:
            captureGesture(b)
        default:
            break
        }
    }

    /// Copies `channels` consecutive channels starting at `firstChannel` of
    /// the batch into the ring, column by column.
    private func feedSegment(_ b: SensorData, ring: RingBuffer, firstChannel: Int,
                             channels: Int, seconds: Int, bio: Bool = false) {
        let sampleCount = Int(b.sampleCount)
        guard channels > 0, sampleCount > 0, firstChannel + channels <= Int(b.channelCount) else { return }
        let rate = max(1, Int(b.sampleRate.rounded()))
        ring.ensure(channels: channels, capacity: rate * max(1, seconds), rate: b.sampleRate)
        let fresh = b.isDataValid()
        var enabled = [Bool](repeating: false, count: channels)
        for c in 0..<channels {
            enabled[c] = b.isChannelEnabled(atChannel: Int32(firstChannel + c))
        }
        var column = [Float](repeating: 0, count: channels)
        if bio {
            var channelValues = [[Float]]()
            channelValues.reserveCapacity(channels)
            for c in 0..<channels {
                var vals = [Float](repeating: 0, count: sampleCount)
                if fresh && enabled[c] {
                    for i in 0..<sampleCount {
                        vals[i] = b.getData(atChannel: Int32(firstChannel + c), index: Int32(i))
                    }
                }
                liveFilter.apply(dataType: Int(b.dataType.rawValue), channel: c,
                                 vals: &vals, sampleRate: b.sampleRate)
                channelValues.append(vals)
            }
            for i in 0..<sampleCount {
                for c in 0..<channels {
                    column[c] = channelValues[c][i]
                }
                ring.appendColumn(column)
            }
        } else {
            for i in 0..<sampleCount {
                for c in 0..<channels {
                    column[c] = (fresh && enabled[c])
                        ? b.getData(atChannel: Int32(firstChannel + c), index: Int32(i))
                        : 0
                }
                ring.appendColumn(column)
            }
        }
    }

    private func captureImpedance(_ b: SensorData, type: NotifyDataType) {
        guard b.sampleCount > 0, b.isDataValid() else { return }
        let last = b.sampleCount - 1
        var values = [Float]()
        for ch in 0..<b.channelCount {
            values.append(b.getImpedance(atChannel: ch, index: last))
        }
        lock.lock()
        impedance[type.rawValue] = values
        lock.unlock()
    }

    private func captureGesture(_ b: SensorData) {
        guard b.sampleCount > 0, b.isDataValid(), b.isChannelEnabled(atChannel: 0) else { return }
        let last = b.sampleCount - 1
        guard let s = b.getChannelSample(atChannel: 0, index: last) else { return }
        var g = GestureRecord()
        g.gesture = Int(s.data)
        g.rawGesture = Int(s.rawData)
        g.possibility = Int(s.impedance)
        g.strength = Int(s.saturation)
        lock.lock()
        gesture = g
        lock.unlock()
    }

    /// Rebuilds the rings whose stream sample rate changed in DeviceInfo.
    func syncSampleRates(from info: DeviceInfo) {
        eeg.reallocate(rate: info.eegSampleRate, seconds: eegWindowSeconds())
        ecg.reallocate(rate: info.ecgSampleRate, seconds: DeviceState.bioSeconds)
        acc.reallocate(rate: info.accSampleRate, seconds: DeviceState.imuSeconds)
        gyro.reallocate(rate: info.gyroSampleRate, seconds: DeviceState.imuSeconds)
        euler.reallocate(rate: info.eulerSampleRate, seconds: DeviceState.imuSeconds)
        quat.reallocate(rate: info.quatSampleRate, seconds: DeviceState.imuSeconds)
    }

    /// EEG ring time window in seconds.
    private func eegWindowSeconds() -> Int {
        currentBioMode() == .ppg ? DeviceState.imuSeconds : DeviceState.bioSeconds
    }

    /// Data-driven bio-mode repair.
    private func repairBioMode(_ observed: BioMode) {
        lock.lock()
        defer { lock.unlock() }
        switch observed {
        case .ppg:
            bioMode = .ppg
        case .eeg:
            if bioMode != .ppg { bioMode = .eeg }
        case .emg:
            if bioMode == .none { bioMode = .emg }
        case .none:
            break
        }
    }
}
