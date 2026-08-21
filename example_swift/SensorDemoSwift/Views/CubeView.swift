import SwiftUI

/// 3D quaternion cube.
struct CubeView: View {
    /// Redraw driver; the value itself is not read.
    @EnvironmentObject private var ticker: PlotTicker

    /// Quaternion ring, channels w, x, y, z.
    let quat: RingBuffer

    private static let cameraDist: Float = 4.5
    private static let axisLength: Float = 1.5
    /// Draw scale (fraction of the smaller canvas dimension per unit length).
    private static let drawScale: Float = 0.36

    private static let faces: [[Int]] = [
        [4, 5, 7, 6], // +X
        [0, 2, 3, 1], // -X
        [2, 6, 7, 3], // +Y
        [0, 1, 5, 4], // -Y
        [1, 3, 7, 5], // +Z
        [0, 4, 6, 2], // -Z
    ]
    private static let faceColors: [Color] = [
        .red, .orange, .green, .cyan, .blue, .purple
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Quaternion Cube").font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                var ctx = context
                draw(context: &ctx, size: size)
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        var w = quat.latest(0)
        var x = quat.latest(1)
        var y = quat.latest(2)
        var z = quat.latest(3)
        let norm = sqrt(w * w + x * x + y * y + z * z)
        guard norm > 1e-6 else { return }
        w /= norm
        x /= norm
        y /= norm
        z /= norm

        let r: [[Float]] = [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
        func rotate(_ v: (Float, Float, Float)) -> (Float, Float, Float) {
            (r[0][0] * v.0 + r[0][1] * v.1 + r[0][2] * v.2,
             r[1][0] * v.0 + r[1][1] * v.1 + r[1][2] * v.2,
             r[2][0] * v.0 + r[2][1] * v.1 + r[2][2] * v.2)
        }

        // 8 unit-cube vertices
        var vertices: [(Float, Float, Float)] = []
        for i in 0..<8 {
            let vx: Float = (i & 1) != 0 ? 1 : -1
            let vy: Float = (i & 2) != 0 ? 1 : -1
            let vz: Float = (i & 4) != 0 ? 1 : -1
            vertices.append(rotate((vx, vy, vz)))
        }

        let scale = CubeView.drawScale * Float(min(size.width, size.height))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        func project(_ v: (Float, Float, Float)) -> CGPoint {
            let factor = CubeView.cameraDist / (CubeView.cameraDist - v.2)
            return CGPoint(x: center.x + CGFloat(v.0 * factor * scale),
                           y: center.y - CGFloat(v.1 * factor * scale))
        }

        let order = CubeView.faces.indices.sorted { a, b in
            let za = CubeView.faces[a].map { vertices[$0].2 }.reduce(0, +)
            let zb = CubeView.faces[b].map { vertices[$0].2 }.reduce(0, +)
            return za < zb
        }
        for faceIndex in order {
            var path = Path()
            let corners = CubeView.faces[faceIndex].map { project(vertices[$0]) }
            path.addLines(corners)
            path.closeSubpath()
            context.fill(path, with: .color(CubeView.faceColors[faceIndex].opacity(0.85)))
            context.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 0.5)
        }

        // body axes from the origin
        let origin = project((0, 0, 0))
        let axes: [((Float, Float, Float), Color)] = [
            ((CubeView.axisLength, 0, 0), .red),
            ((0, CubeView.axisLength, 0), .green),
            ((0, 0, CubeView.axisLength), .blue),
        ]
        for (dir, color) in axes {
            var path = Path()
            path.move(to: origin)
            path.addLine(to: project(rotate(dir)))
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }
}
