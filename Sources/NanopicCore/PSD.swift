import Compression
import Foundation

// MARK: - Public API

public enum PSDError: Error {
    case invalidSignature
    case unsupportedVersion
    case unsupportedColorMode(Int)
    case unsupportedDepth(Int)
    case corrupt(String)
}

/// Channel compression used for layer channel data when writing (internal; tests use it to exercise decoders).
enum PSDChannelCompression: UInt16 {
    case raw = 0
    case rle = 1
    case zip = 2
    case zipPrediction = 3
}

/// Internal write options. The public `PSD.write` always produces PSD v1 / 8-bit / RLE.
struct PSDWriteOptions {
    var psb = false
    var depth = 8
    var compression: PSDChannelCompression = .rle

    init(psb: Bool = false, depth: Int = 8, compression: PSDChannelCompression = .rle) {
        self.psb = psb
        self.depth = depth
        self.compression = compression
    }
}

/// Photoshop document (.psd / .psb) import and export.
///
/// Writing: PSD v1, RGB, 8-bit, 4 channels (RGB + transparency), layer tree with groups,
/// unicode names, blend modes, opacity, clipping, visibility, transparency lock, lock-all,
/// RLE compressed layer channels and merged image.
///
/// Reading: PSD v1 and PSB v2, RGB, 8/16-bit (16-bit is down-converted), raw / RLE / ZIP /
/// ZIP-with-prediction channel data, groups (lsct/lsdk), unicode names, user masks (-2).
public enum PSD {
    public static func write(_ doc: DocumentState) throws -> Data {
        try write(doc, options: PSDWriteOptions())
    }

    public static func read(_ data: Data) throws -> DocumentState {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { p in
            var reader = PSDReader(buf: p)
            return try reader.parse()
        }
    }

    // MARK: Write

    static func write(_ doc: DocumentState, options: PSDWriteOptions) throws -> Data {
        // 呼び出し側で振っていなくても、PSD には必ずレイヤー ID を入れる
        var doc = doc
        doc.assignPSDIDs()
        guard doc.width > 0, doc.height > 0 else { throw PSDError.corrupt("empty canvas") }
        guard options.depth == 8 || options.depth == 16 else { throw PSDError.unsupportedDepth(options.depth) }
        var w = PSDByteWriter()
        let psb = options.psb

        // Header
        w.ascii("8BPS")
        w.u16(psb ? 2 : 1)
        w.bytes([0, 0, 0, 0, 0, 0])
        w.u16(4)
        w.u32(UInt32(doc.height))
        w.u32(UInt32(doc.width))
        w.u16(UInt16(options.depth))
        w.u16(3)

        // Color mode data
        w.u32(0)

        // Image resources: resolution info (0x03ED)
        let resStart = w.placeholder(wide: false)
        w.ascii("8BIM")
        w.u16(0x03ED)
        w.bytes([0, 0]) // empty pascal name, padded to even
        w.u32(16)
        let dpi = doc.dpi > 0 ? doc.dpi : 72
        let fixed = UInt32(clamping: Int((dpi * 65536).rounded()))
        w.u32(fixed); w.u16(1); w.u16(1)
        w.u32(fixed); w.u16(1); w.u16(1)
        w.patch(resStart, wide: false)

        // Layer and mask information
        let canvas = doc.bounds
        var records: [PSDOutRecord] = []
        flatten(doc.layers, canvas: canvas, options: options, into: &records)

        let lmStart = w.placeholder(wide: psb)
        var layerInfo = PSDByteWriter()
        if !records.isEmpty {
            writeLayerInfo(records, options: options, into: &layerInfo)
        }
        if options.depth == 8 {
            if layerInfo.b.isEmpty {
                w.len(0, wide: psb)
            } else {
                w.len(layerInfo.b.count, wide: psb)
                w.bytes(layerInfo.b)
            }
            w.u32(0) // global layer mask info
        } else {
            // 16-bit: Photoshop stores the layer info in an 'Lr16' block.
            w.len(0, wide: psb)
            w.u32(0)
            if !layerInfo.b.isEmpty {
                w.ascii("8BIM")
                w.ascii("Lr16")
                w.len(layerInfo.b.count, wide: psb)
                w.bytes(layerInfo.b)
            }
        }
        w.patch(lmStart, wide: psb)

        // Merged image data (always RLE)
        let composite = Compositor.compositeFull(doc)
        let planes = composite.withUnsafeBufferPointer { p in
            straightPlanes(p.baseAddress!, stride: doc.width, rect: canvas)
        }
        writeMerged(planes: [planes.r, planes.g, planes.b, planes.a], width: doc.width, height: doc.height,
                    options: options, into: &w)
        return Data(w.b)
    }

    private static func flatten(_ nodes: [LayerNode], canvas: IntRect, options: PSDWriteOptions,
                                into out: inout [PSDOutRecord]) {
        for n in nodes {
            switch n.kind {
            case .folder:
                var div = PSDOutRecord(name: "</Layer group>")
                div.sectionType = 3
                div.flags = 0x18
                div.channels = emptyChannels()
                out.append(div)
                flatten(n.children, canvas: canvas, options: options, into: &out)
                var rec = PSDOutRecord(name: n.name)
                rec.sectionType = n.expanded ? 1 : 2
                rec.sectionBlend = n.blendMode.psdKey
                rec.blendKey = n.blendMode == .passThrough ? "norm" : n.blendMode.psdKey
                applyCommon(n, &rec)
                rec.flags |= 0x18
                rec.channels = emptyChannels()
                out.append(rec)
            case .raster:
                var rec = PSDOutRecord(name: n.name)
                rec.blendKey = n.blendMode == .passThrough ? "norm" : n.blendMode.psdKey
                applyCommon(n, &rec)
                let r = n.tiles.contentBounds()?.intersection(canvas) ?? .zero
                if r.isEmpty {
                    rec.channels = emptyChannels()
                } else {
                    rec.rect = r
                    let p = extractPlanes(n.tiles, rect: r)
                    rec.channels = [
                        (-1, encodeChannel(p.a, width: r.width, height: r.height, options: options)),
                        (0, encodeChannel(p.r, width: r.width, height: r.height, options: options)),
                        (1, encodeChannel(p.g, width: r.width, height: r.height, options: options)),
                        (2, encodeChannel(p.b, width: r.width, height: r.height, options: options)),
                    ]
                }
                out.append(rec)
            }
        }
    }

    private static func applyCommon(_ n: LayerNode, _ rec: inout PSDOutRecord) {
        rec.layerID = n.psdID == 0 ? nil : n.psdID
        rec.opacity = UInt8(clamping: Int((min(max(n.opacity, 0), 1) * 255).rounded()))
        rec.clipping = n.clipping ? 1 : 0
        var f: UInt8 = 0
        if n.lockAlpha { f |= 0x01 }
        if !n.visible { f |= 0x02 }
        rec.flags = f
        if n.locked || n.lockAlpha {
            var p: UInt32 = 0
            if n.lockAlpha { p |= 1 }
            if n.locked { p |= 0x8000_0000 }
            rec.protection = p
        }
    }

    private static func emptyChannels() -> [(Int16, [UInt8])] {
        [(-1, [0, 0]), (0, [0, 0]), (1, [0, 0]), (2, [0, 0])]
    }

    private static func writeLayerInfo(_ records: [PSDOutRecord], options: PSDWriteOptions, into w: inout PSDByteWriter) {
        let psb = options.psb
        // Negative count: the first alpha channel of the merged image is its transparency.
        w.i16(-Int16(clamping: records.count))
        for rec in records {
            w.i32(Int32(rec.rect.minY)); w.i32(Int32(rec.rect.minX))
            w.i32(Int32(rec.rect.maxY)); w.i32(Int32(rec.rect.maxX))
            w.u16(UInt16(rec.channels.count))
            for (id, data) in rec.channels {
                w.i16(id)
                w.len(data.count, wide: psb)
            }
            w.ascii("8BIM")
            w.ascii(rec.blendKey)
            w.u8(rec.opacity)
            w.u8(rec.clipping)
            w.u8(rec.flags)
            w.u8(0)
            let extraStart = w.placeholder(wide: false)
            w.u32(0) // layer mask data
            // Blending ranges: composite gray + 4 channels, full range.
            w.u32(40)
            for _ in 0..<10 { w.bytes([0, 0, 255, 255]) }
            // Legacy pascal name (MacRoman best effort), padded to a multiple of 4.
            var nameBytes = [UInt8](rec.name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data())
            if nameBytes.count > 255 { nameBytes = Array(nameBytes.prefix(255)) }
            let nameStart = w.b.count
            w.u8(UInt8(nameBytes.count))
            w.bytes(nameBytes)
            w.pad(to: 4, from: nameStart)
            // Unicode name
            let units = Array(rec.name.utf16)
            var luni = PSDByteWriter()
            luni.u32(UInt32(units.count))
            for u in units { luni.u16(u) }
            w.infoBlock("luni", luni.b)
            if let t = rec.sectionType {
                var s = PSDByteWriter()
                s.u32(t)
                if let k = rec.sectionBlend {
                    s.ascii("8BIM")
                    s.ascii(k)
                }
                w.infoBlock("lsct", s.b)
            }
            if let p = rec.protection {
                var s = PSDByteWriter()
                s.u32(p)
                w.infoBlock("lspf", s.b)
            }
            if let id = rec.layerID {
                var s = PSDByteWriter()
                s.u32(id)
                w.infoBlock("lyid", s.b)
            }
            w.patch(extraStart, wide: false)
        }
        for rec in records {
            for (_, data) in rec.channels { w.bytes(data) }
        }
        w.pad(to: 4, from: 0)
    }

    private static func writeMerged(planes: [[UInt8]], width: Int, height: Int, options: PSDWriteOptions,
                                    into w: inout PSDByteWriter) {
        let bps = options.depth / 8
        let rowBytes = width * bps
        w.u16(1)
        var counts = PSDByteWriter()
        var body: [UInt8] = []
        body.reserveCapacity(planes.count * height * rowBytes / 2)
        var row = [UInt8](repeating: 0, count: rowBytes)
        for plane in planes {
            plane.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    let before = body.count
                    let rp = src.baseAddress! + y * width
                    if bps == 1 {
                        packBits(UnsafeBufferPointer(start: rp, count: width), into: &body)
                    } else {
                        for x in 0..<width { row[x * 2] = rp[x]; row[x * 2 + 1] = rp[x] }
                        row.withUnsafeBufferPointer { packBits($0, into: &body) }
                    }
                    let n = body.count - before
                    if options.psb { counts.u32(UInt32(n)) } else { counts.u16(UInt16(n)) }
                }
            }
        }
        w.bytes(counts.b)
        w.bytes(body)
    }

    /// Encodes one channel including its 2-byte compression header.
    private static func encodeChannel(_ plane: [UInt8], width: Int, height: Int, options: PSDWriteOptions) -> [UInt8] {
        if width * height == 0 { return [0, 0] }
        let bps = options.depth / 8
        let rowBytes = width * bps
        var samples: [UInt8]
        if bps == 1 {
            samples = plane
        } else {
            samples = [UInt8](repeating: 0, count: plane.count * 2)
            samples.withUnsafeMutableBufferPointer { d in
                plane.withUnsafeBufferPointer { s in
                    for i in 0..<s.count { d[i * 2] = s[i]; d[i * 2 + 1] = s[i] }
                }
            }
        }
        var out: [UInt8] = []
        switch options.compression {
        case .raw:
            out = [0, 0]
            out.append(contentsOf: samples)
        case .rle:
            var counts = PSDByteWriter()
            var body: [UInt8] = []
            body.reserveCapacity(samples.count / 2)
            samples.withUnsafeBufferPointer { s in
                for y in 0..<height {
                    let before = body.count
                    packBits(UnsafeBufferPointer(start: s.baseAddress! + y * rowBytes, count: rowBytes), into: &body)
                    let n = body.count - before
                    if options.psb { counts.u32(UInt32(n)) } else { counts.u16(UInt16(n)) }
                }
            }
            out = [0, 1]
            out.append(contentsOf: counts.b)
            out.append(contentsOf: body)
        case .zip, .zipPrediction:
            if options.compression == .zipPrediction {
                samples.withUnsafeMutableBufferPointer { s in
                    let p = s.baseAddress!
                    for y in 0..<height {
                        if bps == 1 {
                            let r = p + y * rowBytes
                            var x = width - 1
                            while x > 0 { r[x] = r[x] &- r[x - 1]; x -= 1 }
                        } else {
                            let r = p + y * rowBytes
                            var x = width - 1
                            while x > 0 {
                                let cur = UInt16(r[x * 2]) << 8 | UInt16(r[x * 2 + 1])
                                let prev = UInt16(r[x * 2 - 2]) << 8 | UInt16(r[x * 2 - 1])
                                let d = cur &- prev
                                r[x * 2] = UInt8(d >> 8); r[x * 2 + 1] = UInt8(d & 0xFF)
                                x -= 1
                            }
                        }
                    }
                }
            }
            out = [0, UInt8(options.compression.rawValue)]
            out.append(contentsOf: zlibCompress(samples))
        }
        return out
    }

    /// Premultiplied tiles → straight planes for `rect`.
    private static func extractPlanes(_ tiles: TileMap, rect: IntRect) -> PSDPlanes {
        var out = PSDPlanes(count: rect.width * rect.height)
        let w = rect.width
        out.r.withUnsafeMutableBufferPointer { rp in
        out.g.withUnsafeMutableBufferPointer { gp in
        out.b.withUnsafeMutableBufferPointer { bp in
        out.a.withUnsafeMutableBufferPointer { ap in
            for key in rect.tileKeys {
                guard let t = tiles[key] else { continue }
                let tr = key.rect.intersection(rect)
                if tr.isEmpty { continue }
                for y in tr.minY..<tr.maxY {
                    let src = t.data + ((y - key.y * kTileSize) * kTileSize + (tr.minX - key.x * kTileSize)) * 4
                    let o = (y - rect.minY) * w + (tr.minX - rect.minX)
                    unpremultiplyRow(src, count: tr.width, r: rp.baseAddress! + o, g: gp.baseAddress! + o,
                                     b: bp.baseAddress! + o, a: ap.baseAddress! + o)
                }
            }
        }}}}
        return out
    }

    /// Premultiplied RGBA buffer (row stride `stride` pixels) → straight planes for `rect`.
    private static func straightPlanes(_ buf: UnsafePointer<UInt8>, stride: Int, rect: IntRect) -> PSDPlanes {
        var out = PSDPlanes(count: rect.width * rect.height)
        let w = rect.width
        out.r.withUnsafeMutableBufferPointer { rp in
        out.g.withUnsafeMutableBufferPointer { gp in
        out.b.withUnsafeMutableBufferPointer { bp in
        out.a.withUnsafeMutableBufferPointer { ap in
            for y in 0..<rect.height {
                let src = buf + ((rect.minY + y) * stride + rect.minX) * 4
                let o = y * w
                unpremultiplyRow(src, count: w, r: rp.baseAddress! + o, g: gp.baseAddress! + o,
                                 b: bp.baseAddress! + o, a: ap.baseAddress! + o)
            }
        }}}}
        return out
    }

    @inline(__always)
    private static func unpremultiplyRow(_ src: UnsafePointer<UInt8>, count: Int,
                                         r: UnsafeMutablePointer<UInt8>, g: UnsafeMutablePointer<UInt8>,
                                         b: UnsafeMutablePointer<UInt8>, a: UnsafeMutablePointer<UInt8>) {
        for x in 0..<count {
            let p = src + x * 4
            let al = Int(p[3])
            a[x] = UInt8(al)
            if al == 0 {
                r[x] = 0; g[x] = 0; b[x] = 0
            } else if al == 255 {
                r[x] = p[0]; g[x] = p[1]; b[x] = p[2]
            } else {
                let h = al / 2
                r[x] = UInt8(min(255, (Int(p[0]) * 255 + h) / al))
                g[x] = UInt8(min(255, (Int(p[1]) * 255 + h) / al))
                b[x] = UInt8(min(255, (Int(p[2]) * 255 + h) / al))
            }
        }
    }

    // MARK: PackBits

    /// PackBits-encodes `src` (one row) and appends to `out`.
    static func packBits(_ src: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) {
        let n = src.count
        guard n > 0, let s = src.baseAddress else { return }
        var i = 0
        while i < n {
            var j = i + 1
            while j < n && j - i < 128 && s[j] == s[i] { j += 1 }
            let run = j - i
            if run >= 3 {
                out.append(UInt8(truncatingIfNeeded: 1 - run))
                out.append(s[i])
                i = j
                continue
            }
            let start = i
            while i < n && i - start < 128 {
                if i + 2 < n && s[i] == s[i + 1] && s[i] == s[i + 2] { break }
                i += 1
            }
            out.append(UInt8(i - start - 1))
            out.append(contentsOf: UnsafeBufferPointer(start: s + start, count: i - start))
        }
    }

    static func packBitsEncode(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        src.withUnsafeBufferPointer { packBits($0, into: &out) }
        return out
    }

    /// Decodes PackBits data. Output is zero-padded / truncated to `expectedLength`.
    static func packBitsDecode(_ src: [UInt8], expectedLength: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expectedLength)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                guard let sp = s.baseAddress, let dp = d.baseAddress else { return }
                _ = unpackBits(sp, s.count, dp, expectedLength)
            }
        }
        return out
    }

    /// Returns bytes written.
    @discardableResult
    static func unpackBits(_ src: UnsafePointer<UInt8>, _ n: Int, _ dst: UnsafeMutablePointer<UInt8>, _ cap: Int) -> Int {
        var consumed = 0
        return unpackBits(src, n, dst, cap, consumed: &consumed)
    }

    /// Returns bytes written; `consumed` receives the number of source bytes actually used
    /// (may exceed `n` when the last packet claims more bytes than are available).
    @discardableResult
    static func unpackBits(_ src: UnsafePointer<UInt8>, _ n: Int, _ dst: UnsafeMutablePointer<UInt8>, _ cap: Int,
                           consumed: inout Int) -> Int {
        var i = 0, o = 0
        defer { consumed = i }
        while i < n && o < cap {
            let h = Int(Int8(bitPattern: src[i]))
            i += 1
            if h >= 0 {
                let c = min(h + 1, n - i, cap - o)
                if c <= 0 { break }
                (dst + o).update(from: src + i, count: c)
                i += h + 1
                o += c
            } else if h != -128 {
                guard i < n else { break }
                let c = min(1 - h, cap - o)
                (dst + o).update(repeating: src[i], count: c)
                i += 1
                o += c
            }
        }
        return o
    }
}

// MARK: - Writer helpers

private struct PSDPlanes {
    var r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8]
    init(count: Int) {
        r = [UInt8](repeating: 0, count: count)
        g = r; b = r; a = r
    }
}

private struct PSDOutRecord {
    var name: String
    var rect = IntRect.zero
    var blendKey = "norm"
    var opacity: UInt8 = 255
    var clipping: UInt8 = 0
    var flags: UInt8 = 0
    var sectionType: UInt32?
    var sectionBlend: String?
    var protection: UInt32?
    var layerID: UInt32?
    var channels: [(Int16, [UInt8])] = []

    init(name: String) { self.name = name }
}

private struct PSDByteWriter {
    var b: [UInt8] = []

    mutating func u8(_ v: UInt8) { b.append(v) }
    mutating func u16(_ v: UInt16) { b.append(UInt8(v >> 8)); b.append(UInt8(v & 0xFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        b.append(UInt8(v >> 24)); b.append(UInt8((v >> 16) & 0xFF))
        b.append(UInt8((v >> 8) & 0xFF)); b.append(UInt8(v & 0xFF))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func len(_ v: Int, wide: Bool) { if wide { u64(UInt64(v)) } else { u32(UInt32(v)) } }
    mutating func ascii(_ s: String) { b.append(contentsOf: Array(s.utf8)) }
    mutating func bytes(_ a: [UInt8]) { b.append(contentsOf: a) }

    mutating func placeholder(wide: Bool) -> Int {
        let p = b.count
        len(0, wide: wide)
        return p
    }

    /// Writes the length of everything after the placeholder at `at`.
    mutating func patch(_ at: Int, wide: Bool) {
        let size = wide ? 8 : 4
        let v = UInt64(b.count - at - size)
        for k in 0..<size {
            b[at + k] = UInt8((v >> UInt64((size - 1 - k) * 8)) & 0xFF)
        }
    }

    mutating func pad(to m: Int, from start: Int) {
        while (b.count - start) % m != 0 { b.append(0) }
    }

    mutating func infoBlock(_ key: String, _ data: [UInt8]) {
        ascii("8BIM")
        ascii(key)
        var d = data
        while d.count % 4 != 0 { d.append(0) }
        u32(UInt32(d.count))
        bytes(d)
    }
}

private func psdAdler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    data.withUnsafeBufferPointer { p in
        var i = 0
        let n = p.count
        while i < n {
            let end = min(i + 5552, n)
            while i < end {
                a &+= UInt32(p[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
    }
    return (b << 16) | a
}

/// zlib stream (header + raw deflate + adler32).
private func zlibCompress(_ src: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x9C]
    if !src.isEmpty {
        let cap = src.count + src.count / 8 + 1024
        var buf = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBufferPointer { s in
            buf.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, cap, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        out.append(contentsOf: buf.prefix(n))
    } else {
        out.append(contentsOf: [0x03, 0x00])
    }
    let ad = psdAdler32(src)
    out.append(contentsOf: [UInt8(ad >> 24), UInt8((ad >> 16) & 0xFF), UInt8((ad >> 8) & 0xFF), UInt8(ad & 0xFF)])
    return out
}

// MARK: - Reader

private struct PSDInRecord {
    var rect = IntRect.zero
    var channels: [(id: Int, length: Int)] = []
    var blendKey = "norm"
    var opacity: UInt8 = 255
    var clipping: UInt8 = 0
    var flags: UInt8 = 0
    var name = ""
    var unicodeName: String?
    var sectionType: UInt32?
    var sectionBlend: String?
    var protection: UInt32?
    var layerID: UInt32?
    var fillOpacity: UInt8?
    var maskRect = IntRect.zero
    var maskDefault: UInt8 = 0
    var maskFlags: UInt8 = 0
    var hasMask = false
    var planes: [Int: [UInt8]] = [:]
}

private let psbWideKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph",
                                        "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

private struct PSDReader {
    let buf: UnsafeBufferPointer<UInt8>
    var pos = 0
    var psb = false
    var depth = 8
    var width = 0
    /// Set when some RLE/ZIP pixel data did not decode cleanly (e.g. ImageIO-written PSDs have broken layer channels).
    var pixelDataInconsistent = false
    var height = 0

    init(buf: UnsafeBufferPointer<UInt8>) { self.buf = buf }

    // MARK: primitives

    func need(_ n: Int) throws {
        if n < 0 || pos + n > buf.count { throw PSDError.corrupt("unexpected end of data at \(pos)") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return buf[pos]
    }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(buf[pos]) << 8 | UInt16(buf[pos + 1])
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(buf[pos]) << 24 | UInt32(buf[pos + 1]) << 16 | UInt32(buf[pos + 2]) << 8 | UInt32(buf[pos + 3])
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func u64() throws -> UInt64 {
        let hi = UInt64(try u32())
        return hi << 32 | UInt64(try u32())
    }

    mutating func length(wide: Bool) throws -> Int {
        let v = wide ? try u64() : UInt64(try u32())
        guard v <= UInt64(buf.count) else { throw PSDError.corrupt("length out of range") }
        return Int(v)
    }

    mutating func ascii4() throws -> String {
        try need(4)
        defer { pos += 4 }
        return String(decoding: buf[pos..<pos + 4], as: UTF8.self)
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }

    func peekSig(_ at: Int) -> Bool {
        guard at + 4 <= buf.count else { return false }
        let s = (buf[at], buf[at + 1], buf[at + 2], buf[at + 3])
        return s == (0x38, 0x42, 0x49, 0x4D) || s == (0x38, 0x42, 0x36, 0x34) // 8BIM / 8B64
    }

    /// Moves to the next signature allowing up to 3 bytes of padding. Returns false if none found.
    mutating func alignToSig(end: Int) -> Bool {
        for k in 0...3 where pos + k + 12 <= end && peekSig(pos + k) {
            pos += k
            return true
        }
        return false
    }

    // MARK: document

    mutating func parse() throws -> DocumentState {
        guard buf.count >= 26 else { throw PSDError.invalidSignature }
        guard try ascii4() == "8BPS" else { throw PSDError.invalidSignature }
        let version = try u16()
        guard version == 1 || version == 2 else { throw PSDError.unsupportedVersion }
        psb = version == 2
        try skip(6)
        let channels = Int(try u16())
        height = Int(try u32())
        width = Int(try u32())
        depth = Int(try u16())
        let mode = Int(try u16())
        guard mode == 3 else { throw PSDError.unsupportedColorMode(mode) }
        guard depth == 8 || depth == 16 else { throw PSDError.unsupportedDepth(depth) }
        guard width > 0, height > 0, width <= 300_000, height <= 300_000, channels >= 1 else {
            throw PSDError.corrupt("bad dimensions")
        }

        // Color mode data
        try skip(Int(try u32()))

        // Image resources
        var dpi: Double = 72
        let resLen = Int(try u32())
        try need(resLen)
        let resEnd = pos + resLen
        while pos + 12 <= resEnd {
            _ = try ascii4()
            let id = try u16()
            let nl = Int(try u8())
            try skip(nl + ((nl + 1) % 2))
            let size = Int(try u32())
            let dataStart = pos
            guard dataStart + size <= resEnd else { break }
            if id == 0x03ED && size >= 16 {
                let h = Double(try u32()) / 65536
                let unit = try u16()
                if h > 0 { dpi = unit == 2 ? h * 2.54 : h }
            }
            pos = dataStart + size + (size % 2)
        }
        pos = resEnd

        // Layer and mask info
        let lmLen = try length(wide: psb)
        try need(lmLen)
        let lmEnd = pos + lmLen
        var records: [PSDInRecord] = []
        var mergedHasAlpha = false
        if lmLen > 0 {
            let liLen = try length(wide: psb)
            try need(liLen)
            let liEnd = pos + liLen
            if liLen > 0 {
                (records, mergedHasAlpha) = try parseLayerInfo(end: liEnd)
            }
            pos = liEnd
            if pos + 4 <= lmEnd {
                let gm = Int(try u32())
                pos = min(lmEnd, pos + gm)
            }
            while alignToSig(end: lmEnd) {
                try skip(4)
                let key = try ascii4()
                let len = try length(wide: psb && psbWideKeys.contains(key))
                let start = pos
                guard start + len <= lmEnd else { break }
                if records.isEmpty && ((key == "Lr16" && depth == 16) || (key == "Layr" && depth == 8)) && len > 0 {
                    (records, mergedHasAlpha) = try parseLayerInfo(end: start + len)
                }
                pos = start + len
            }
        }
        pos = lmEnd

        var doc = DocumentState(width: width, height: height)
        doc.dpi = dpi
        var layers = buildTree(records)
        let layerDataBroken = pixelDataInconsistent
        var flatName = "背景"
        var mergedPlanes: [[UInt8]]?
        if !layers.isEmpty && layerDataBroken {
            // Layer channel data is malformed (some writers, notably ImageIO, emit bogus layer channels
            // alongside a correct merged image). Fall back to the merged image if it decodes cleanly.
            pixelDataInconsistent = false
            let keep = min(channels, 4)
            if let planes = try? decodeImageData(start: pos, end: buf.count, width: width, height: height,
                                                 planeCount: channels, keep: keep), !pixelDataInconsistent {
                mergedPlanes = planes
                if layers.count == 1 && !layers[0].isFolder { flatName = layers[0].name }
                layers = []
            }
        }
        if layers.isEmpty {
            // Flat image: use the merged image data.
            let keep = min(channels, 4)
            var planes = try mergedPlanes ?? decodeImageData(start: pos, end: buf.count, width: width, height: height,
                                                             planeCount: channels, keep: keep)
            if !(mergedHasAlpha && channels >= 4) {
                if planes.count >= 4 { planes.removeLast(planes.count - 3) }
            }
            var node = LayerNode(name: flatName)
            let n = width * height
            let r = planes.count > 0 ? planes[0] : [UInt8](repeating: 0, count: n)
            let g = planes.count > 2 ? planes[1] : r
            let b = planes.count > 2 ? planes[2] : r
            let a = planes.count > 3 ? planes[3] : [UInt8](repeating: 255, count: n)
            node.tiles = PSDReader.buildTiles(r: r, g: g, b: b, a: a, rect: doc.bounds, canvas: doc.bounds)
            doc.layers = [node]
        } else {
            doc.layers = layers
        }
        doc.activeLayerID = PSDReader.topmostRaster(doc.layers)
        return doc
    }

    private static func topmostRaster(_ nodes: [LayerNode]) -> UUID? {
        for n in nodes.reversed() {
            if n.isFolder {
                if let id = topmostRaster(n.children) { return id }
            } else {
                return n.id
            }
        }
        return nil
    }

    // MARK: layer info

    mutating func parseLayerInfo(end: Int) throws -> ([PSDInRecord], Bool) {
        let count = Int(try i16())
        let n = abs(count)
        var records: [PSDInRecord] = []
        records.reserveCapacity(n)
        for _ in 0..<n {
            var rec = PSDInRecord()
            let top = Int(try i32()), left = Int(try i32()), bottom = Int(try i32()), right = Int(try i32())
            rec.rect = (bottom > top && right > left) ? IntRect(minX: left, minY: top, maxX: right, maxY: bottom) : .zero
            let nch = Int(try u16())
            guard nch <= 56 else { throw PSDError.corrupt("too many channels") }
            for _ in 0..<nch {
                let id = Int(try i16())
                let len = try length(wide: psb)
                rec.channels.append((id, len))
            }
            _ = try ascii4()
            rec.blendKey = try ascii4()
            rec.opacity = try u8()
            rec.clipping = try u8()
            rec.flags = try u8()
            try skip(1)
            let extraLen = Int(try u32())
            try need(extraLen)
            let extraEnd = pos + extraLen

            // Layer mask data
            let maskLen = Int(try u32())
            let maskStart = pos
            if maskLen >= 18 && maskStart + maskLen <= extraEnd {
                let t = Int(try i32()), l = Int(try i32()), b = Int(try i32()), r = Int(try i32())
                rec.maskRect = (b > t && r > l) ? IntRect(minX: l, minY: t, maxX: r, maxY: b) : .zero
                rec.maskDefault = try u8()
                rec.maskFlags = try u8()
                rec.hasMask = true
            }
            pos = maskStart + maskLen
            // Blending ranges
            let brLen = Int(try u32())
            try skip(brLen)
            // Pascal name padded to 4
            if pos < extraEnd {
                let nl = Int(try u8())
                try need(nl)
                rec.name = String(data: Data(buf[pos..<pos + nl]), encoding: .macOSRoman)
                    ?? String(decoding: buf[pos..<pos + nl], as: UTF8.self)
                let total = (nl + 1 + 3) & ~3
                pos += total - 1
            }
            // Additional layer information
            while pos < extraEnd && alignToSig(end: extraEnd) {
                try skip(4)
                let key = try ascii4()
                let len = try length(wide: psb && psbWideKeys.contains(key))
                let start = pos
                guard start + len <= extraEnd else { break }
                switch key {
                case "luni":
                    if len >= 4 {
                        let cnt = Int(try u32())
                        if cnt * 2 <= len - 4 {
                            var units = [UInt16]()
                            units.reserveCapacity(cnt)
                            for _ in 0..<cnt { units.append(try u16()) }
                            while units.last == 0 { units.removeLast() }
                            rec.unicodeName = String(decoding: units, as: UTF16.self)
                        }
                    }
                case "lsct", "lsdk":
                    if len >= 4 {
                        rec.sectionType = try u32()
                        if len >= 12 {
                            _ = try ascii4()
                            rec.sectionBlend = try ascii4()
                        }
                    }
                case "lspf":
                    if len >= 4 { rec.protection = try u32() }
                case "lyid":
                    if len >= 4 { rec.layerID = try u32() }
                case "iOpa":
                    if len >= 1 { rec.fillOpacity = try u8() }
                default:
                    break
                }
                pos = start + len
            }
            pos = extraEnd
            records.append(rec)
        }

        // Channel image data
        for i in 0..<records.count {
            let isGroup = records[i].sectionType.map { $0 != 0 } ?? false
            for ch in records[i].channels {
                let start = pos
                guard start + ch.length <= buf.count else { throw PSDError.corrupt("channel data out of range") }
                defer { pos = start + ch.length }
                if isGroup { continue }
                let r: IntRect
                switch ch.id {
                case -1, 0, 1, 2: r = records[i].rect
                case -2: r = records[i].maskRect
                default: continue
                }
                if r.isEmpty || ch.length < 2 { continue }
                do {
                    let planes = try decodeImageData(start: start, end: start + ch.length, width: r.width,
                                                     height: r.height, planeCount: 1, keep: 1)
                    records[i].planes[ch.id] = planes[0]
                } catch {
                    pixelDataInconsistent = true
                }
            }
        }
        _ = end
        return (records, count < 0)
    }

    // MARK: pixel data

    /// Reads a 2-byte compression code at `start` followed by `planeCount` planes; returns the first `keep` as 8-bit.
    mutating func decodeImageData(start: Int, end: Int, width w: Int, height h: Int, planeCount: Int, keep: Int) throws -> [[UInt8]] {
        guard start + 2 <= end, end <= buf.count else {
            return Array(repeating: [UInt8](repeating: 0, count: w * h), count: keep)
        }
        let comp = Int(buf[start]) << 8 | Int(buf[start + 1])
        let bps = depth / 8
        let rowBytes = w * bps
        let planeBytes = rowBytes * h
        let base = buf.baseAddress!
        var p = start + 2
        var raw = [[UInt8]](repeating: [], count: keep)
        var consistent = true
        switch comp {
        case 0:
            for c in 0..<keep {
                var plane = [UInt8](repeating: 0, count: planeBytes)
                let avail = max(0, min(planeBytes, end - p))
                if avail > 0 { plane.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base + p, count: avail) } }
                p += planeBytes
                raw[c] = plane
            }
        case 1:
            let cw = psb ? 4 : 2
            let rows = planeCount * h
            guard p + rows * cw <= end else { throw PSDError.corrupt("RLE counts out of range") }
            var data = p + rows * cw
            for c in 0..<planeCount {
                if c >= keep {
                    break
                }
                var plane = [UInt8](repeating: 0, count: planeBytes)
                plane.withUnsafeMutableBufferPointer { d in
                    for y in 0..<h {
                        let ci = p + (c * h + y) * cw
                        let len = cw == 2 ? (Int(base[ci]) << 8 | Int(base[ci + 1]))
                            : (Int(base[ci]) << 24 | Int(base[ci + 1]) << 16 | Int(base[ci + 2]) << 8 | Int(base[ci + 3]))
                        let avail = max(0, min(len, end - data))
                        var used = 0
                        let written = avail > 0
                            ? PSD.unpackBits(base + data, avail, d.baseAddress! + y * rowBytes, rowBytes, consumed: &used)
                            : 0
                        // A well-formed row decodes to exactly rowBytes without overrunning its byte count.
                        if written != rowBytes || used > len { consistent = false }
                        data += len
                    }
                }
                raw[c] = plane
            }

            p = end
        case 2, 3:
            let total = planeBytes * keep
            let all = try inflate(start: p, end: end, expected: planeBytes * planeCount, minimum: total)
            for c in 0..<keep {
                var plane = Array(all[c * planeBytes..<(c + 1) * planeBytes])
                if comp == 3 {
                    plane.withUnsafeMutableBufferPointer { s in
                        let q = s.baseAddress!
                        for y in 0..<h {
                            let r = q + y * rowBytes
                            if bps == 1 {
                                var x = 1
                                while x < w { r[x] = r[x] &+ r[x - 1]; x += 1 }
                            } else {
                                var x = 1
                                while x < w {
                                    let cur = UInt16(r[x * 2]) << 8 | UInt16(r[x * 2 + 1])
                                    let prev = UInt16(r[x * 2 - 2]) << 8 | UInt16(r[x * 2 - 1])
                                    let v = cur &+ prev
                                    r[x * 2] = UInt8(v >> 8); r[x * 2 + 1] = UInt8(v & 0xFF)
                                    x += 1
                                }
                            }
                        }
                    }
                }
                raw[c] = plane
            }
        default:
            throw PSDError.corrupt("unknown compression \(comp)")
        }
        if !consistent { pixelDataInconsistent = true }
        if bps == 1 { return raw }
        // 16-bit → 8-bit
        return raw.map { src in
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { d in
                src.withUnsafeBufferPointer { s in
                    for i in 0..<(w * h) {
                        let v = Int(s[i * 2]) << 8 | Int(s[i * 2 + 1])
                        d[i] = UInt8((v * 255 + 32767) / 65535)
                    }
                }
            }
            return out
        }
    }

    func inflate(start: Int, end: Int, expected: Int, minimum: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(expected, 1))
        guard end - start > 2 else { throw PSDError.corrupt("zip data too short") }
        let src = buf.baseAddress! + start + 2
        let n = out.withUnsafeMutableBufferPointer { d in
            compression_decode_buffer(d.baseAddress!, expected, src, end - start - 2, nil, COMPRESSION_ZLIB)
        }
        if n < minimum { throw PSDError.corrupt("zip decode failed") }
        return out
    }

    // MARK: tree

    private func buildTree(_ records: [PSDInRecord]) -> [LayerNode] {
        let canvas = IntRect(x: 0, y: 0, width: width, height: height)
        var stack: [[LayerNode]] = [[]]
        for rec in records {
            let st = rec.sectionType ?? 0
            if st == 3 {
                stack.append([])
                continue
            }
            var node: LayerNode
            if st == 1 || st == 2 {
                node = LayerNode(name: rec.unicodeName ?? rec.name, kind: .folder)
                node.children = stack.count > 1 ? stack.removeLast() : []
                node.expanded = st == 1
                let key = rec.sectionBlend ?? rec.blendKey
                node.blendMode = BlendMode(psdKey: key) ?? .passThrough
            } else {
                node = LayerNode(name: rec.unicodeName ?? rec.name, kind: .raster)
                var bm = BlendMode(psdKey: rec.blendKey) ?? .normal
                if bm == .passThrough { bm = .normal }
                node.blendMode = bm
                node.tiles = PSDReader.layerTiles(rec, canvas: canvas)
            }
            var op = Float(rec.opacity) / 255
            if node.kind == .raster, let f = rec.fillOpacity { op *= Float(f) / 255 }
            node.opacity = op
            node.clipping = rec.clipping != 0
            node.visible = rec.flags & 0x02 == 0
            let prot = rec.protection ?? 0
            node.lockAlpha = rec.flags & 0x01 != 0 || prot & 1 != 0
            node.locked = prot & 0x8000_0000 != 0 || prot & 0x6 == 0x6
            node.psdID = rec.layerID ?? 0
            stack[stack.count - 1].append(node)
        }
        // Unterminated groups: splice their contents into the parent.
        while stack.count > 1 {
            let top = stack.removeLast()
            stack[stack.count - 1].append(contentsOf: top)
        }
        return stack[0]
    }

    private static func layerTiles(_ rec: PSDInRecord, canvas: IntRect) -> TileMap {
        let r = rec.rect
        if r.isEmpty || r.intersection(canvas).isEmpty { return TileMap() }
        let n = r.width * r.height
        let zero = [UInt8](repeating: 0, count: n)
        let red = rec.planes[0] ?? zero
        let green = rec.planes[1] ?? zero
        let blue = rec.planes[2] ?? zero
        var alpha = rec.planes[-1] ?? [UInt8](repeating: 255, count: n)
        if rec.hasMask, rec.maskFlags & 0x02 == 0, let mask = rec.planes[-2] {
            applyMask(&alpha, rect: r, mask: mask, maskRect: rec.maskRect, defaultColor: rec.maskDefault)
        } else if rec.hasMask, rec.maskFlags & 0x02 == 0, rec.maskRect.isEmpty, rec.maskDefault == 0 {
            // Empty mask with black default hides everything.
            return TileMap()
        }
        return buildTiles(r: red, g: green, b: blue, a: alpha, rect: r, canvas: canvas)
    }

    private static func applyMask(_ alpha: inout [UInt8], rect r: IntRect, mask: [UInt8], maskRect mr: IntRect,
                                  defaultColor: UInt8) {
        alpha.withUnsafeMutableBufferPointer { ap in
            mask.withUnsafeBufferPointer { mp in
                for y in 0..<r.height {
                    let gy = r.minY + y
                    let row = ap.baseAddress! + y * r.width
                    let inY = gy >= mr.minY && gy < mr.maxY
                    for x in 0..<r.width {
                        let gx = r.minX + x
                        let m: Int
                        if inY && gx >= mr.minX && gx < mr.maxX {
                            m = Int(mp[(gy - mr.minY) * mr.width + (gx - mr.minX)])
                        } else {
                            m = Int(defaultColor)
                        }
                        if m == 255 { continue }
                        let t = Int(row[x]) * m + 128
                        row[x] = UInt8((t + (t >> 8)) >> 8)
                    }
                }
            }
        }
    }

    /// Straight planes covering `rect` → premultiplied tiles clipped to `canvas`.
    static func buildTiles(r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8], rect: IntRect, canvas: IntRect) -> TileMap {
        var map = TileMap()
        let clip = rect.intersection(canvas)
        if clip.isEmpty { return map }
        let w = rect.width
        r.withUnsafeBufferPointer { rp in
        g.withUnsafeBufferPointer { gp in
        b.withUnsafeBufferPointer { bp in
        a.withUnsafeBufferPointer { ap in
            for key in clip.tileKeys {
                let tr = key.rect.intersection(clip)
                if tr.isEmpty { continue }
                var tile: Tile?
                for y in tr.minY..<tr.maxY {
                    let o = (y - rect.minY) * w + (tr.minX - rect.minX)
                    let ar = ap.baseAddress! + o
                    var any = false
                    for x in 0..<tr.width where ar[x] != 0 { any = true; break }
                    if !any { continue }
                    let t: Tile
                    if let existing = tile { t = existing } else { t = Tile(gen: 0); tile = t }
                    let rr = rp.baseAddress! + o, gr = gp.baseAddress! + o, br = bp.baseAddress! + o
                    let d = t.data + ((y - key.y * kTileSize) * kTileSize + (tr.minX - key.x * kTileSize)) * 4
                    for x in 0..<tr.width {
                        let al = Int(ar[x])
                        let q = d + x * 4
                        if al == 0 { continue }
                        if al == 255 {
                            q[0] = rr[x]; q[1] = gr[x]; q[2] = br[x]; q[3] = 255
                        } else {
                            var t0 = Int(rr[x]) * al + 128
                            q[0] = UInt8((t0 + (t0 >> 8)) >> 8)
                            t0 = Int(gr[x]) * al + 128
                            q[1] = UInt8((t0 + (t0 >> 8)) >> 8)
                            t0 = Int(br[x]) * al + 128
                            q[2] = UInt8((t0 + (t0 >> 8)) >> 8)
                            q[3] = UInt8(al)
                        }
                    }
                }
                if let t = tile { map.set(key, t) }
            }
        }}}}
        return map
    }
}
