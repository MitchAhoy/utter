import SwiftUI

/// Layered, flowing sine waves that swell with the microphone level.
/// Waves taper to a point at both ends, so the shape reads as sound rather than a chart.
struct VoiceWaveView: View {
    /// Meter level, 0...1 (roughly -60 dB to 0 dB).
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room noise sits around 0.2, so ignore it; normal speech should fill most of the height.
    private var amplitude: Double {
        let speech = (Double(level) - 0.25) / 0.5
        return 0.08 + 0.92 * min(1, max(0, speech))
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Self.layers.indices, id: \.self) { index in
                    let layer = Self.layers[index]
                    WaveShape(amplitude: amplitude * layer.scale,
                              frequency: layer.frequency,
                              phase: reduceMotion ? layer.offset : time * layer.speed + layer.offset)
                        .stroke(layer.color.opacity(layer.opacity),
                                style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
            .animation(.interpolatingSpring(stiffness: 170, damping: 18), value: amplitude)
        }
        .drawingGroup()
    }

    private struct Layer {
        let color: Color, scale: Double, frequency: Double, speed: Double, offset: Double, width: CGFloat, opacity: Double
    }
    private static let layers: [Layer] = [
        Layer(color: Color(red: 0.36, green: 0.55, blue: 1.0), scale: 0.55, frequency: 1.6, speed: -2.4, offset: 2.1, width: 1.5, opacity: 0.55),
        Layer(color: Color(red: 0.93, green: 0.36, blue: 0.85), scale: 0.75, frequency: 2.3, speed: 3.1, offset: 0.9, width: 1.5, opacity: 0.65),
        Layer(color: Color(red: 0.25, green: 0.88, blue: 0.95), scale: 1.0, frequency: 1.9, speed: 4.2, offset: 0, width: 2.2, opacity: 0.95),
    ]
}

private struct WaveShape: Shape {
    var amplitude: Double
    let frequency: Double
    let phase: Double

    /// Lets SwiftUI glide between meter readings (sent about 20 times a second) instead of jumping.
    var animatableData: Double {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let steps = max(24, Int(rect.width / 1.5))
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            // Bell-shaped envelope: flat at the ends, full height in the middle.
            let envelope = pow(sin(progress * .pi), 2)
            let y = mid + sin(progress * frequency * 2 * .pi + phase) * amplitude * envelope * rect.height / 2
            let point = CGPoint(x: rect.minX + progress * rect.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
