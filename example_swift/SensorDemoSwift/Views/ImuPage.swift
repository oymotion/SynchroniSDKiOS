import SwiftUI

/// IMU page: ACC / GYRO / EULER / QUATERNION rows, each split into a left
/// FFT spectrum half and a right 2D waveform half, plus a "Real-time
/// Values" panel and the 3D quaternion cube.
struct ImuPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let state = model.deviceState
        let waiting = model.currentMac != nil ? "Waiting for data ..." : "Not connected"
        ScrollView {
            VStack(spacing: 8) {
                valuesPanel(state)
                // Left: FFT spectrum. Right: time-domain waveform.
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.acc, state: state,
                                 labels: ["ACC-X", "ACC-Y", "ACC-Z"], fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "ACC", ring: state.acc, fixedY: -8...8,
                                 placeholder: waiting)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.gyro, state: state,
                                 labels: ["GYRO-X", "GYRO-Y", "GYRO-Z"], fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "GYRO", ring: state.gyro, fixedY: -2000...2000,
                                 placeholder: waiting)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.euler, state: state,
                                 labels: ["Pitch(Y)", "Roll(X)", "Yaw(Z)"], fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "EULER (deg)", ring: state.euler, fixedY: -180...180,
                                 placeholder: waiting)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
                HStack(spacing: 8) {
                    SpectrumView(title: "", ring: state.quat, state: state,
                                 labels: ["W", "X", "Y", "Z"], fillHeight: true)
                        .frame(maxWidth: .infinity)
                    WaveformView(title: "QUATERNION", ring: state.quat, fixedY: -1...1,
                                 placeholder: waiting)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 90)
                CubeView(quat: state.quat)
                    .frame(minHeight: 220)
            }
            .padding()
        }
    }

    /// Latest sample per channel of each IMU type.
    private func valuesPanel(_ state: DeviceState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Real-time Values").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                valueRow(ring: state.acc, labels: ["ACC-X", "ACC-Y", "ACC-Z"])
                valueRow(ring: state.gyro, labels: ["GYRO-X", "GYRO-Y", "GYRO-Z"])
                valueRow(ring: state.euler, labels: ["Pitch(Y)", "Roll(X)", "Yaw(Z)"])
                valueRow(ring: state.quat, labels: ["W", "X", "Y", "Z"])
            }
        }
    }

    private func valueRow(ring: RingBuffer, labels: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(labels.enumerated()), id: \.offset) { ch, label in
                Text("\(label): \(valueText(ring, ch))")
                    .font(.system(.caption2, design: .monospaced))
            }
            Spacer()
        }
    }

    private func valueText(_ ring: RingBuffer, _ ch: Int) -> String {
        guard ch < ring.channelCount, ring.filled > 0 else { return "--" }
        return String(format: "%+.4f", ring.latest(ch))
    }
}
