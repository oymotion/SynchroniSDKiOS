import SwiftUI

/// Bio page: 8 fixed slots; EMG/EEG channel rows, the mag-angle Angle row,
/// the EEG mode's ECG row and the PPG mode's EEG/PPG rows split into a left
/// FFT spectrum half and a right time-domain waveform half.
struct BioPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Live Filter.
                #if os(macOS)
                HStack(spacing: 12) {
                    Text("Live Filter:")
                    ForEach(0..<LiveFilter.bandLabels.count, id: \.self) { i in
                        Button {
                            model.liveFilterBand = i
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.liveFilterBand == i
                                      ? "circle.inset.filled" : "circle")
                                Text(LiveFilter.bandLabels[i])
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                #else
                HStack {
                    Text("Live Filter:")
                    Picker("Live Filter:", selection: $model.liveFilterBand) {
                        ForEach(0..<LiveFilter.bandLabels.count, id: \.self) { i in
                            Text(LiveFilter.bandLabels[i]).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                #endif
                // EEG paging controls.
                if model.bioMode == .eeg && model.bioPageCount > 1 {
                    HStack {
                        Button("Prev") { model.bioPage(-1) }
                            .disabled(model.bioPageIndex <= 0)
                        Text("Page \(model.bioPageIndex + 1) / \(model.bioPageCount)")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                        Button("Next") { model.bioPage(1) }
                            .disabled(model.bioPageIndex >= model.bioPageCount - 1)
                    }
                }
                switch model.bioMode {
                case .emg:
                    emgPlots
                case .eeg:
                    eegPlots
                case .ppg:
                    ppgPlots
                case .none:
                    Text(model.currentMac != nil ? "Waiting for data ..." : "Not connected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
    }

    private var waitingText: String {
        model.currentMac != nil ? "Waiting for data ..." : "Not connected"
    }

    /// Impedance side text and color for one channel; blank while the device
    /// has no impedance capability or the NTF_IMPEDANCE switch is off.
    private func impedanceSide(_ values: [Float], _ ch: Int) -> (String, Color) {
        guard model.ntfStates["NTF_IMPEDANCE"] ?? false else { return ("", .secondary) }
        guard ch < values.count, values[ch] >= 0 else { return ("", .secondary) }
        let kOhm = values[ch] / 1000.0
        let color: Color = kOhm <= 500 ? .green : (kOhm <= 999 ? .orange : .red)
        return (String(format: "%.2f KOhm", kOhm), color)
    }

    /// Angle row: fixed 0-180 degree Y range, splits with a spectrum.
    private func angleRow(widgetIndex i: Int) -> some View {
        HStack(spacing: 8) {
            SpectrumView(title: "", ring: model.deviceState.magAngle,
                         state: model.deviceState, labels: ["Angle"],
                         channel: 0, colorIndex: i, fillHeight: true)
                .frame(maxWidth: .infinity)
            WaveformView(title: "Angle", ring: model.deviceState.magAngle,
                         channel: 0, fixedY: 0...180, colorIndex: i,
                         placeholder: waitingText)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
    }

    @ViewBuilder
    private var emgPlots: some View {
        let imp = model.deviceState.impedance(for: .NTF_EMG)
        let reported = Int(model.deviceInfo?.emgChannelCount ?? 0)
        let observed = model.deviceState.emg.channelCount
        let channels = max(reported, observed)
        let hasMag = Int(model.deviceInfo?.magAngleChannelCount ?? 0) > 0
            || model.deviceState.magAngle.channelCount > 0
        let emgRows = channels > 0 ? min(channels, 8 - (hasMag ? 1 : 0)) : (hasMag ? 0 : 8)
        ForEach(0..<emgRows, id: \.self) { ch in
            let (text, color) = impedanceSide(imp, ch)
            // Left: channel FFT spectrum. Right: time-domain waveform.
            HStack(spacing: 8) {
                SpectrumView(title: "", ring: model.deviceState.emg,
                             state: model.deviceState, labels: ["ch\(ch)"],
                             channel: ch, colorIndex: ch, fillHeight: true)
                    .frame(maxWidth: .infinity)
                WaveformView(title: "EMG ch\(ch)", ring: model.deviceState.emg,
                             channel: ch, sideText: text, sideColor: color,
                             placeholder: waitingText)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 90)
        }
        if hasMag {
            angleRow(widgetIndex: emgRows)
        }
    }

    /// EEG mode plots.
    @ViewBuilder
    private var eegPlots: some View {
        let state = model.deviceState
        let info = model.deviceInfo
        let imp = state.impedance(for: .NTF_EEG)
        let hasECG = Int(info?.ecgChannelCount ?? 0) > 0 || state.ecg.channelCount > 0
        let hasBRTH = Int(info?.brthChannelCount ?? 0) > 0 || state.brth.channelCount > 0
        let hasMag = Int(info?.magAngleChannelCount ?? 0) > 0 || state.magAngle.channelCount > 0
        let perPage = AppModel.bioSlotCount - (hasECG ? 1 : 0) - (hasBRTH ? 1 : 0) - (hasMag ? 1 : 0)
        let reported = Int(info?.eegChannelCount ?? 0)
        let total = reported > 0 ? reported : state.eeg.channelCount
        let pages = perPage > 0 && total > 0 ? max(1, (total + perPage - 1) / perPage) : 1
        let page = min(model.bioPageIndex, pages - 1)
        let startCh = page * perPage
        let ecgIndex = AppModel.bioSlotCount - 1 - (hasBRTH ? 1 : 0)
        let brthIndex = AppModel.bioSlotCount - 1
        let magIndex = ecgIndex - (hasECG ? 1 : 0)
        ForEach(0..<AppModel.bioSlotCount, id: \.self) { i in
            let ch = startCh + i
            if i < perPage && ch < total {
                let (text, color) = impedanceSide(imp, ch)
                // Left: channel FFT spectrum. Right: time-domain waveform.
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.eeg, state: state,
                                 labels: ["ch\(ch)"], channel: ch,
                                 colorIndex: ch, fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "EEG ch\(ch)", ring: state.eeg, channel: ch,
                                 sideText: text, sideColor: color,
                                 placeholder: waitingText)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
            } else if hasECG && i == ecgIndex {
                // Left: channel FFT spectrum. Right: time-domain waveform.
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.ecg, state: state,
                                 labels: ["ECG"], channel: 0,
                                 colorIndex: 2, fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "ECG", ring: state.ecg, channel: 0,
                                 colorIndex: 2, placeholder: waitingText)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
            } else if hasBRTH && i == brthIndex {
                WaveformView(title: "BRTH", ring: state.brth, channel: 0,
                             colorIndex: 3, placeholder: waitingText)
                    .frame(minHeight: 90)
            } else if hasMag && i == magIndex {
                angleRow(widgetIndex: i)
            } else {
                // Blank slot.
                let noSuchChannel = i < perPage && ch >= total
                WaveformView(title: "", ring: nil,
                             placeholder: noSuchChannel ? "" : waitingText)
                    .frame(minHeight: 90)
            }
        }
    }

    /// PPG mode plots.
    @ViewBuilder
    private var ppgPlots: some View {
        let imp = model.deviceState.impedance(for: .NTF_EEG)
        let fp1 = impedanceSide(imp, 0)
        let fp2 = impedanceSide(imp, 1)
        // Left: channel FFT spectrum. Right: time-domain waveform.
        HStack(spacing: 8) {
            SpectrumView(title: "", ring: model.deviceState.eeg,
                         state: model.deviceState, labels: ["fp1"],
                         channel: 0, colorIndex: 0, fillHeight: true)
                .frame(maxWidth: .infinity)
            WaveformView(title: "EEG fp1", ring: model.deviceState.eeg, channel: 0,
                         colorIndex: 0, sideText: fp1.0, sideColor: fp1.1,
                         placeholder: waitingText)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
        HStack(spacing: 8) {
            SpectrumView(title: "", ring: model.deviceState.eeg,
                         state: model.deviceState, labels: ["fp2"],
                         channel: 1, colorIndex: 1, fillHeight: true)
                .frame(maxWidth: .infinity)
            WaveformView(title: "EEG fp2", ring: model.deviceState.eeg, channel: 1,
                         colorIndex: 1, sideText: fp2.0, sideColor: fp2.1,
                         placeholder: waitingText)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
        HStack(spacing: 8) {
            SpectrumView(title: "", ring: model.deviceState.ppg,
                         state: model.deviceState, labels: ["red_led"],
                         channel: 0, colorIndex: 2, fillHeight: true)
                .frame(maxWidth: .infinity)
            WaveformView(title: "PPG red_led", ring: model.deviceState.ppg, channel: 0,
                         colorIndex: 2, placeholder: waitingText)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
        HStack(spacing: 8) {
            SpectrumView(title: "", ring: model.deviceState.ppg,
                         state: model.deviceState, labels: ["ir_led"],
                         channel: 1, colorIndex: 3, fillHeight: true)
                .frame(maxWidth: .infinity)
            WaveformView(title: "PPG ir_led", ring: model.deviceState.ppg, channel: 1,
                         colorIndex: 3, placeholder: waitingText)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
        WaveformView(title: "SpO2 spo2", ring: model.deviceState.spo2, channel: 0,
                     colorIndex: 4, placeholder: waitingText)
            .frame(minHeight: 90)
        WaveformView(title: "SpO2 heart_rate", ring: model.deviceState.spo2, channel: 1,
                     colorIndex: 5, placeholder: waitingText)
            .frame(minHeight: 90)
    }
}
