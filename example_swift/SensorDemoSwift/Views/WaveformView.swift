import SwiftUI

/// Waveform view: dark panel, center line, one channel or all channels
/// overlaid, oldest samples at the left, fixed or auto Y range.
struct WaveformView: View {
    /// Redraw driver; the value itself is not read.
    @EnvironmentObject private var ticker: PlotTicker

    let title: String
    /// nil = unbound slot.
    let ring: RingBuffer?
    /// nil = all channels overlaid; otherwise only this channel.
    var channel: Int? = nil
    /// Fixed Y range (2D IMU views); nil = auto range (bio views).
    var fixedY: ClosedRange<Float>? = nil
    /// Decouples the curve color from the data channel.
    var colorIndex: Int? = nil
    /// Right-margin side text (impedance).
    var sideText: String = ""
    var sideColor: Color = .secondary
    /// Centered text shown while no samples are available ("" = blank).
    var placeholder: String = ""

    static let palette: [Color] = [
        .blue, .orange, .green, .red, .purple, .brown, .pink, .teal
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !sideText.isEmpty {
                    Text(sideText).font(.caption2).foregroundStyle(sideColor)
                }
            }
            Canvas { context, size in
                var ctx = context
                draw(context: &ctx, size: size)
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        // center line
        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: size.height / 2))
        mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(mid, with: .color(.gray.opacity(0.4)), lineWidth: 0.5)

        let channels: [Int]
        if let channel = channel {
            channels = [channel]
        } else {
            channels = Array(0..<max(0, ring?.channelCount ?? 0))
        }
        let series = channels.map { ($0, ring?.snapshot(channel: $0) ?? []) }

        // No drawable data: show the placeholder.
        if !series.contains(where: { $0.1.count > 1 }) {
            if !placeholder.isEmpty {
                context.draw(
                    Text(placeholder).font(.caption).foregroundColor(Color(white: 0.6)),
                    at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            return
        }

        guard let yRange = resolveYRange(series: series) else {
            return
        }
        let ySpan = max(yRange.upperBound - yRange.lowerBound, 1e-6)

        for (ch, data) in series where data.count > 1 {
            var path = Path()
            for (i, v) in data.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(data.count - 1)
                let norm = (CGFloat(v) - CGFloat(yRange.lowerBound)) / CGFloat(ySpan)
                let y = size.height * (1 - norm)
                let point = CGPoint(x: x, y: y)
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            let paletteIndex = (colorIndex ?? ch) % WaveformView.palette.count
            context.stroke(path, with: .color(WaveformView.palette[paletteIndex]), lineWidth: 1)
        }
    }

    private func resolveYRange(series: [(Int, [Float])]) -> ClosedRange<Float>? {
        if let fixedY = fixedY { return fixedY }
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for (_, data) in series {
            for v in data {
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }
        guard lo <= hi else { return nil }
        let margin = max((hi - lo) * 0.1, 1e-3)
        return (lo - margin)...(hi + margin)
    }
}
