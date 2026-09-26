import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NanopicCore

/// 他のソフト（ImageIO）が書いた PSD を読めるか
final class ForeignPSDTests: XCTestCase {
    func testReadImageIOWrittenPSD() throws {
        let w = 64, h = 48
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let a = x < 32 ? 255 : 128
                buf[o] = UInt8(x * 4 * a / 255); buf[o + 1] = UInt8(y * 5 * a / 255); buf[o + 2] = UInt8(100 * a / 255); buf[o + 3] = UInt8(a)
            }
        }
        let img = ImageUtil.makeImage(premultiplied: buf, width: w, height: h)!
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.adobe.photoshop-image" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (data as Data).write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "imageio.psd"))
        // ImageIO 自身が読み戻した値（ImageIO は合成画像を読む）
        let src = CGImageSourceCreateWithData(data, nil)!
        let back = ImageUtil.loadPremultiplied(CGImageSourceCreateImageAtIndex(src, 0, nil)!)!
        let doc = try PSD.read(data as Data)
        XCTAssertEqual(doc.width, w)
        XCTAssertEqual(doc.height, h)
        XCTAssertFalse(doc.layers.isEmpty)
        let composite = Compositor.compositeFull(doc)
        // 不透明部分の色が一致
        let o = (10 * w + 10) * 4
        XCTAssertEqual(Int(composite[o]), 40, accuracy: 2)
        XCTAssertEqual(Int(composite[o + 1]), 50, accuracy: 2)
        XCTAssertEqual(Int(composite[o + 3]), 255)
        // 既知の値
        let expected: [(Int, Int, [Int])] = [(0, 0, [0, 0, 100, 255]), (20, 30, [80, 150, 100, 255]),
                                             (10, 10, [40, 50, 100, 255])]
        for (x, y, e) in expected {
            let q = (y * w + x) * 4
            for c in 0..<4 { XCTAssertEqual(Int(composite[q + c]), e[c], accuracy: 2, "(\(x),\(y)) ch\(c)") }
        }
        // 全ピクセルが元バッファ（premultiplied）と一致すること（アルファは完全一致）。
        // 注: ImageIO 自身の読み戻しは半透明部分を二重に premultiply する（(40,10) で [40,13,25,128]）ため、
        // 比較対象は元バッファにする。ファイル内のストレート値は 128 (x=32) で、元の premultiplied 64 に対応する。
        for y in 0..<h {
            for x in 0..<w {
                let q = (y * w + x) * 4
                XCTAssertEqual(composite[q + 3], buf[q + 3], "alpha (\(x),\(y))")
                for c in 0..<3 where abs(Int(composite[q + c]) - Int(buf[q + c])) > 2 {
                    XCTFail("(\(x),\(y)) ch\(c): ours \(composite[q + c]) source \(buf[q + c])")
                }
            }
        }
        let q = (10 * w + 40) * 4
        XCTAssertEqual(Array(composite[q..<q + 4]).map(Int.init), [80, 25, 50, 128])
        // ImageIO の合成画像のアルファは一致する
        XCTAssertEqual(composite[q + 3], back.buffer[q + 3])
    }
}
