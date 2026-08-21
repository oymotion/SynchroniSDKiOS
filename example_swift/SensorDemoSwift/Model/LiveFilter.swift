import Foundation

/// Minimal double-precision complex number for the DSP math below.
struct DspComplex {
    var re = 0.0
    var im = 0.0

    static let zero = DspComplex(re: 0, im: 0)

    static func polar(_ r: Double, _ theta: Double) -> DspComplex {
        DspComplex(re: r * cos(theta), im: r * sin(theta))
    }

    static func + (a: DspComplex, b: DspComplex) -> DspComplex {
        DspComplex(re: a.re + b.re, im: a.im + b.im)
    }

    static func - (a: DspComplex, b: DspComplex) -> DspComplex {
        DspComplex(re: a.re - b.re, im: a.im - b.im)
    }

    static func * (a: DspComplex, b: DspComplex) -> DspComplex {
        DspComplex(re: a.re * b.re - a.im * b.im,
                   im: a.re * b.im + a.im * b.re)
    }

    static func * (a: DspComplex, s: Double) -> DspComplex {
        DspComplex(re: a.re * s, im: a.im * s)
    }

    static func / (a: DspComplex, b: DspComplex) -> DspComplex {
        let d = b.re * b.re + b.im * b.im
        return DspComplex(re: (a.re * b.re + a.im * b.im) / d,
                          im: (a.im * b.re - a.re * b.im) / d)
    }

    var conj: DspComplex { DspComplex(re: re, im: -im) }

    var abs: Double { (re * re + im * im).squareRoot() }

    /// Principal square root.
    func sqrt() -> DspComplex {
        let r = abs
        let u = ((r + re) / 2).squareRoot()
        let v = ((r - re) / 2).squareRoot() * (im < 0 ? -1 : 1)
        return DspComplex(re: u, im: v)
    }
}

/// Real-time band filter for the bio waveforms (EMG/EEG/ECG/BRTH/PPG/SpO2).
final class LiveFilter {
    struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    private struct StreamState {
        var band = 0
        var rate: Float = 0
        var sections: [Biquad] = []
        var zi0: [[Double]] = []
        /// channel -> per-section running state.
        var channels: [Int: [[Double]]] = [:]
    }

    /// Band index 0 is Off.
    static let bandLabels = [
        "Off",
        "\u{03B4} 0.5-4Hz",
        "\u{03B8} 4-8Hz",
        "\u{03B1} 8-13Hz",
        "\u{03B2} 13-30Hz",
        "\u{03B3} 30-45Hz",
    ]
    private static let bands: [(lo: Double, hi: Double)] = [
        (0.0, 0.0), (0.5, 4.0), (4.0, 8.0), (8.0, 13.0), (13.0, 30.0), (30.0, 45.0),
    ]
    private static let order = 4

    private let lock = NSLock()
    private var band = 0
    private var streams: [Int: StreamState] = [:]   // key: NotifyDataType raw value

    /// Sets the band.
    func setBand(_ bandIndex: Int) {
        lock.lock()
        band = bandIndex > 0 && bandIndex < LiveFilter.bands.count ? bandIndex : 0
        streams.removeAll()
        lock.unlock()
    }

    /// Drops all designed filters and channel states.
    func reset() {
        lock.lock()
        streams.removeAll()
        lock.unlock()
    }

    /// Filters one channel batch in place.
    func apply(dataType: Int, channel: Int, vals: inout [Float], sampleRate: Float) {
        if vals.isEmpty { return }
        lock.lock()
        defer { lock.unlock() }
        if band == 0 { return }
        var st = streams[dataType] ?? StreamState()
        if st.band != band || st.rate != sampleRate {
            st.sections = []
            st.zi0 = []
            st.channels = [:]
            st.band = band
            st.rate = sampleRate
            if let sections = LiveFilter.design(bandIndex: band, fs: Double(sampleRate)) {
                st.sections = sections
                var u = 1.0
                for s in sections {
                    let g = (s.b0 + s.b1 + s.b2) / (1.0 + s.a1 + s.a2)
                    let y = g * u
                    st.zi0.append([y - s.b0 * u, s.b2 * u - s.a2 * y])
                    u = y
                }
            }
        }
        if st.sections.isEmpty {
            streams[dataType] = st
            return
        }
        var chState = st.channels[channel] ?? st.zi0
        for i in vals.indices {
            var x = Double(vals[i])
            for s in st.sections.indices {
                let q = st.sections[s]
                let y = q.b0 * x + chState[s][0]
                chState[s][0] = q.b1 * x - q.a1 * y + chState[s][1]
                chState[s][1] = q.b2 * x - q.a2 * y
                x = y
            }
            vals[i] = Float(x)
        }
        st.channels[channel] = chState
        streams[dataType] = st
    }

    /// Butterworth bandpass design (order 4).
    private static func design(bandIndex: Int, fs: Double) -> [Biquad]? {
        guard bandIndex > 0, bandIndex < bands.count, fs > 0 else { return nil }
        let lo = bands[bandIndex].lo
        let hi = bands[bandIndex].hi
        guard hi < fs / 2.0 else { return nil }

        let w1 = 2.0 * fs * tan(.pi * lo / fs)
        let w2 = 2.0 * fs * tan(.pi * hi / fs)
        let bw = w2 - w1
        let wo = (w1 * w2).squareRoot()
        let fs2 = 2.0 * fs

        var poles: [DspComplex] = []
        var zeros: [DspComplex] = []
        for k in 0..<order {
            let ang = Double.pi * (2.0 * Double(k) + 1 + Double(order)) / (2.0 * Double(order))
            let p = DspComplex.polar(1.0, ang)
            let mid = p * (0.5 * bw)
            let disc = (mid * mid - DspComplex(re: wo * wo, im: 0)).sqrt()
            let sp1 = mid + disc
            let sp2 = mid - disc
            let f = DspComplex(re: fs2, im: 0)
            poles.append((f + sp1) / (f - sp1))
            poles.append((f + sp2) / (f - sp2))
        }
        for _ in 0..<order {
            zeros.append(DspComplex(re: 1, im: 0))
            zeros.append(DspComplex(re: -1, im: 0))
        }
        let gain = pow(bw, Double(order)) * pow(fs2, Double(order))
        var denom = DspComplex(re: 1, im: 0)
        for k in 0..<order {
            let ang = Double.pi * (2.0 * Double(k) + 1 + Double(order)) / (2.0 * Double(order))
            let p = DspComplex.polar(1.0, ang)
            let mid = p * (0.5 * bw)
            let disc = (mid * mid - DspComplex(re: wo * wo, im: 0)).sqrt()
            denom = denom * (DspComplex(re: fs2, im: 0) - (mid + disc))
            denom = denom * (DspComplex(re: fs2, im: 0) - (mid - disc))
        }
        let kz = gain * denom.re / (denom.abs * denom.abs)

        var sections: [Biquad] = []
        while let p = poles.popLast() {
            var best = 0
            for i in 1..<poles.count {
                if (poles[i] - p.conj).abs < (poles[best] - p.conj).abs {
                    best = i
                }
            }
            let pc = poles[best]
            poles.remove(at: best)
            var zpair = [DspComplex.zero, DspComplex.zero]
            for j in 0..<2 {
                var bz = 0
                for i in 1..<zeros.count {
                    let d = min((zeros[i] - p).abs, (zeros[i] - pc).abs)
                    let db = min((zeros[bz] - p).abs, (zeros[bz] - pc).abs)
                    if d < db { bz = i }
                }
                zpair[j] = zeros[bz]
                zeros.remove(at: bz)
            }
            var s = Biquad()
            s.a1 = -(p + pc).re
            s.a2 = (p * pc).re
            s.b0 = 1.0
            s.b1 = -(zpair[0] + zpair[1]).re
            s.b2 = (zpair[0] * zpair[1]).re
            sections.append(s)
        }
        sections[0].b0 *= kz
        sections[0].b1 *= kz
        sections[0].b2 *= kz
        return sections
    }
}
