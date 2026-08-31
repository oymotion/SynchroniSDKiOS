import SwiftUI

/// One spectrum strip's compute scheduler and latest result.
final class SpectrumModel: ObservableObject {
    @Published private(set) var freqs: [Float] = []
    @Published private(set) var mags: [[Float]] = []

    /// Shared single worker for every strip.
    private static let queue = DispatchQueue(label: "SensorDemoSwift.Spectrum", qos: .userInitiated)
    private var busy = false
    private var lastSubmit = Date.distantPast
    private var lastRing: ObjectIdentifier?
    private var lastChannel: Int?

    func maybeCompute(ring: RingBuffer, channel: Int? = nil, state: DeviceState) {
        let ringId = ObjectIdentifier(ring)
        if lastRing != ringId || lastChannel != channel {
            lastRing = ringId
            lastChannel = channel
            freqs = []
            mags = []
        }
        guard !busy, Date().timeIntervalSince(lastSubmit) >= 0.2 else { return }
        let rate = ring.sampleRate
        guard rate > 0, ring.filled >= 16 else { return }
        let snapshot: [[Float]]
        if let channel = channel {
            guard channel >= 0, channel < ring.channelCount else { return }
            snapshot = [ring.snapshot(channel: channel)]
        } else {
            let channels = ring.channelCount
            guard channels > 0 else { return }
            snapshot = (0..<channels).map { ring.snapshot(channel: $0) }
        }
        let epoch = state.currentEpoch()
        busy = true
        lastSubmit = Date()
        Self.queue.async { [weak self] in
            let result = SpectrumCompute.compute(channels: snapshot, rate: rate)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                // Stale source (device / channel changed mid-compute).
                guard self.lastRing == ringId, self.lastChannel == channel,
                      epoch == state.currentEpoch() else { return }
                self.freqs = result.freqs
                self.mags = result.mags
            }
        }
    }
}

/// Spectrum strip under one IMU waveform, or the left half of one bio
/// channel row.
struct SpectrumView: View {
    let title: String
    let ring: RingBuffer
    let state: DeviceState
    /// Channel labels shown top-left in the curve colors.
    var labels: [String] = []
    /// nil = all channels overlaid; otherwise only this channel.
    var channel: Int? = nil
    /// nil = the curve color follows the snapshot channel index.
    var colorIndex: Int? = nil
    /// true = the canvas fills the offered height (bio rows).
    var fillHeight = false

    @StateObject private var spectrum = SpectrumModel()
    /// Tick driver; the value itself is not read.
    @EnvironmentObject private var ticker: PlotTicker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                var ctx = context
                draw(context: &ctx, size: size)
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(minHeight: 48, maxHeight: fillHeight ? nil : 72)
        }
        .onReceive(ticker.$tick) { _ in
            spectrum.maybeCompute(ring: ring, channel: channel, state: state)
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        // Bottom strip below the plot area carries the axis texts.
        let plot = CGRect(x: 2, y: 2,
                          width: max(0, size.width - 4),
                          height: max(0, size.height - 16))
        context.stroke(Path(plot), with: .color(.gray.opacity(0.6)), lineWidth: 0.5)

        let freqs = spectrum.freqs
        let mags = spectrum.mags
        guard freqs.count >= 2, !mags.isEmpty else {
            context.draw(Text("Waiting for data ...").font(.caption2)
                            .foregroundColor(Color(white: 0.6)),
                         at: CGPoint(x: plot.midX, y: plot.midY))
            return
        }
        let fMax = Double(freqs[freqs.count - 1])
        guard fMax > 0, plot.width >= 2, plot.height >= 2 else { return }

        // Auto Y range across all channels.
        var peak: Float = 0
        for row in mags {
            for v in row { peak = max(peak, v) }
        }
        let yMax = peak > 0 ? Double(peak) * 1.1 : 1.0

        for (ch, row) in mags.enumerated() {
            let color = WaveformView.palette[(colorIndex ?? ch) % WaveformView.palette.count]
            var path = Path()
            let count = min(row.count, freqs.count)
            for i in 0..<count {
                let x = plot.minX + CGFloat(Double(freqs[i]) / fMax) * (plot.width - 1)
                let y = plot.maxY - 1 - CGFloat(Double(row[i]) / yMax) * (plot.height - 2)
                let point = CGPoint(x: x, y: y)
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 1)

            let label = ch < labels.count ? labels[ch] : "ch\(ch)"
            context.draw(Text(label).font(.system(size: 9)).foregroundColor(color),
                         at: CGPoint(x: plot.minX + 18, y: plot.minY + 8 + CGFloat(ch) * 11))
        }

        // Frequency axis endpoints.
        let axisColor = Color(white: 0.6)
        let axisY = plot.maxY + 7
        context.draw(Text("0").font(.system(size: 9)).foregroundColor(axisColor),
                     at: CGPoint(x: plot.minX + 6, y: axisY))
        context.draw(Text(String(format: "%.1f Hz", fMax)).font(.system(size: 9))
                        .foregroundColor(axisColor),
                     at: CGPoint(x: plot.maxX - 24, y: axisY))
    }
}
