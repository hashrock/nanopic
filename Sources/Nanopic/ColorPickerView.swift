import AppKit
import NanopicCore
import SwiftUI

struct HSV: Equatable {
    var h: Double  // 0...1
    var s: Double
    var v: Double

    init(h: Double, s: Double, v: Double) {
        self.h = h
        self.s = s
        self.v = v
    }

    init(rgb c: SIMD3<Float>, keepHue: Double) {
        let r = Double(c.x), g = Double(c.y), b = Double(c.z)
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        v = mx
        s = mx <= 0 ? 0 : d / mx
        if d <= 1e-6 {
            h = keepHue
        } else if mx == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6) / 6
        } else if mx == g {
            h = ((b - r) / d + 2) / 6
        } else {
            h = ((r - g) / d + 4) / 6
        }
        if h < 0 { h += 1 }
    }

    var rgb: SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch Int(i) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return SIMD3(Float(r), Float(g), Float(b))
    }
}

extension SIMD3 where Scalar == Float {
    var swiftUIColor: Color { Color(.sRGB, red: Double(x), green: Double(y), blue: Double(z)) }
    var hex: String {
        String(format: "%02X%02X%02X", Int((x * 255).rounded()), Int((y * 255).rounded()), Int((z * 255).rounded()))
    }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
}

struct ColorPickerView: View {
    @Bindable var editor: Editor
    @State private var hsv = HSV(h: 0, s: 0, v: 0)
    @State private var hexText = ""
    @State private var lastSet: SIMD3<Float>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                svSquare
                hueBar
            }
            HStack(spacing: 10) {
                swatches
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("#").foregroundStyle(.secondary)
                        TextField("RRGGBB", text: $hexText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit {
                                if let c = SIMD3<Float>(hex: hexText) { setColor(c) }
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                    }
                    Text(String(format: "H %.0f° S %.0f%% V %.0f%%", hsv.h * 360, hsv.s * 100, hsv.v * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { syncFromEditor() }
        .onChange(of: editor.mainColor) { _, _ in syncFromEditor() }
    }

    private func syncFromEditor() {
        let c = editor.mainColor
        if lastSet != c {
            hsv = HSV(rgb: c, keepHue: hsv.h)
        }
        hexText = c.hex
    }

    private func setColor(_ c: SIMD3<Float>) {
        lastSet = c
        editor.mainColor = c
        hsv = HSV(rgb: c, keepHue: hsv.h)
        hexText = c.hex
    }

    private func setHSV(_ n: HSV) {
        hsv = n
        let c = n.rgb
        lastSet = c
        editor.mainColor = c
        hexText = c.hex
    }

    private var svSquare: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Rectangle().fill(HSV(h: hsv.h, s: 1, v: 1).rgb.swiftUIColor)
                Rectangle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(hsv.v > 0.5 ? Color.black : Color.white, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .position(x: hsv.s * size.width, y: (1 - hsv.v) * size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var n = hsv
                n.s = min(max(g.location.x / size.width, 0), 1)
                n.v = 1 - min(max(g.location.y / size.height, 0), 1)
                setHSV(n)
            })
        }
        .frame(height: 150)
    }

    private var hueBar: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                LinearGradient(colors: (0...12).map { HSV(h: Double($0) / 12, s: 1, v: 1).rgb.swiftUIColor },
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Rectangle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(height: 4)
                    .offset(y: hsv.h * h - 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var n = hsv
                n.h = min(max(g.location.y / h, 0), 0.9999)
                setHSV(n)
            })
        }
        .frame(width: 18, height: 150)
    }

    private var swatches: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(editor.subColor.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray))
                .frame(width: 28, height: 28)
                .offset(x: 16, y: 16)
                .onTapGesture { editor.swapColors() }
            RoundedRectangle(cornerRadius: 3)
                .fill(editor.mainColor.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray))
                .frame(width: 28, height: 28)
        }
        .frame(width: 46, height: 46, alignment: .topLeading)
        .help("メインカラー / サブカラー（クリックまたは X で入れ替え）")
    }
}
