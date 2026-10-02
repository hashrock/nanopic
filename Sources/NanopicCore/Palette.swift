import Foundation

/// 登録した色（パレット）
extension Editor {
    public static let defaultPalette: [SIMD3<Float>] = [
        "1A1A1F", "4A4A52", "8E8E96", "D4D4DA", "FFFFFF", "E5484D", "F2994A", "F2C94C",
        "6FCF97", "2D9C6B", "56CCF2", "2F80ED", "9B51E0", "F28FB1", "FBE3D3", "8B5A3C",
    ].compactMap(AgentToolbox.parseColor)

    /// 同じ色がまだなければ末尾に足す
    public func addToPalette(_ c: SIMD3<Float>) {
        guard !palette.contains(where: { Self.sameColor($0, c) }) else { return }
        palette.append(c)
    }

    public func removeFromPalette(at i: Int) {
        guard palette.indices.contains(i) else { return }
        palette.remove(at: i)
    }

    public func replacePaletteColor(at i: Int, with c: SIMD3<Float>) {
        guard palette.indices.contains(i) else { return }
        palette[i] = c
    }

    /// 8bit に丸めて同じなら同じ色
    public static func sameColor(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        AgentToolbox.hex(a) == AgentToolbox.hex(b)
    }
}
