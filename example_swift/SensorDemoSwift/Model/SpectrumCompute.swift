import Foundation

/// Hann-windowed one-sided magnitude spectrum of ring-snapshot channels.
enum SpectrumCompute {
    /// channels: per-channel snapshots ordered oldest -> newest.
    static func compute(channels: [[Float]], rate: Float) -> (freqs: [Float], mags: [[Float]]) {
        guard let first = channels.first, rate > 0 else { return ([], []) }
        let n = first.count
        guard n >= 16 else { return ([], []) }
        var nfft = 1
        while nfft < n { nfft <<= 1 }

        var window = [Double](repeating: 0, count: n)
        var winSum = 0.0
        for i in 0..<n {
            window[i] = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
            winSum += window[i]
        }

        var freqs = [Float](repeating: 0, count: nfft / 2 + 1)
        for k in 0...nfft / 2 {
            freqs[k] = Float(k) * rate / Float(nfft)
        }

        var mags: [[Float]] = []
        mags.reserveCapacity(channels.count)
        var buf = [DspComplex](repeating: .zero, count: nfft)
        let norm = max(winSum, 1e-12)
        for ch in channels {
            let m = min(n, ch.count)
            for i in 0..<nfft {
                buf[i] = i < m ? DspComplex(re: Double(ch[i]) * window[i], im: 0) : .zero
            }
            fft(&buf)
            var row = [Float](repeating: 0, count: nfft / 2 + 1)
            for k in 0...nfft / 2 {
                row[k] = Float(2.0 * buf[k].abs / norm)
            }
            mags.append(row)
        }
        return (freqs, mags)
    }

    /// In-place iterative radix-2 FFT. buf.count must be a power of two.
    private static func fft(_ buf: inout [DspComplex]) {
        let n = buf.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j { buf.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2.0 * Double.pi / Double(len)
            let wlen = DspComplex(re: cos(ang), im: sin(ang))
            var i = 0
            while i < n {
                var w = DspComplex(re: 1, im: 0)
                for k in 0..<len / 2 {
                    let u = buf[i + k]
                    let v = buf[i + k + len / 2] * w
                    buf[i + k] = u + v
                    buf[i + k + len / 2] = u - v
                    w = w * wlen
                }
                i += len
            }
            len <<= 1
        }
    }
}
