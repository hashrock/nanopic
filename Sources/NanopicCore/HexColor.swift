import Foundation

/// "#RRGGBB" と色の変換
public enum HexColor {
    public static func parse(_ s: String) -> SIMD3<Float>? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return SIMD3(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }

    public static func format(_ c: SIMD3<Float>) -> String {
        func b(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.x), b(c.y), b(c.z))
    }
}
