import AppKit
import Metal
import MetalKit
import NanopicCore

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 m0;   // a, b, c, d  (canvas → view の線形部分)
    float4 m1;   // tx, ty, viewW, viewH
    float4 m2;   // canvasW, canvasH, checkerSize(px), unused
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut vmain(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 uv = corners[vid];
    float2 c = uv * u.m2.xy;
    float2 v = float2(u.m0.x * c.x + u.m0.z * c.y + u.m1.x,
                      u.m0.y * c.x + u.m0.w * c.y + u.m1.y);
    VOut o;
    o.position = float4(v.x / u.m1.z * 2.0 - 1.0, 1.0 - v.y / u.m1.w * 2.0, 0, 1);
    o.uv = uv;
    return o;
}

fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                      sampler smp [[sampler(0)]], constant Uniforms& u [[buffer(0)]]) {
    float4 c = tex.sample(smp, in.uv);
    float2 p = floor(in.position.xy / u.m2.z);
    float k = fmod(p.x + p.y, 2.0) < 0.5 ? 1.0 : 0.82;
    return float4(c.rgb + float3(k) * (1.0 - c.a), 1.0);
}
"""

struct RenderUniforms {
    var m0: SIMD4<Float>
    var m1: SIMD4<Float>
    var m2: SIMD4<Float>
}

/// 合成結果をテクスチャに保持し、変更された領域だけ再合成・転送して表示する
final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState
    private var texture: MTLTexture?
    private var composite: UnsafeMutablePointer<UInt8>?
    private var texSize = (0, 0)
    private var needsMipmaps = false
    private var lastCommand: MTLCommandBuffer?
    private var lastOnionVersion = -1
    weak var canvas: CanvasView?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Metal pipeline error: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToZero
        sd.tAddressMode = .clampToZero
        linearSampler = device.makeSamplerState(descriptor: sd)!
        sd.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: sd)!
        super.init()
        view.device = device
    }

    deinit {
        composite?.deallocate()
    }

    private func ensureTexture(width: Int, height: Int) -> Bool {
        if texSize == (width, height), texture != nil { return false }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        texture = device.makeTexture(descriptor: desc)
        composite?.deallocate()
        composite = .allocate(capacity: width * height * 4)
        composite!.initialize(repeating: 0, count: width * height * 4)
        texSize = (width, height)
        return true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// premultiplied の over 合成（rect の中だけ）
    private func blendOver(_ top: [UInt8], into dst: UnsafeMutablePointer<UInt8>, rect: IntRect, width w: Int) {
        top.withUnsafeBufferPointer { src in
            let s = src.baseAddress!
            for y in rect.minY..<rect.maxY {
                for x in rect.minX..<rect.maxX {
                    let o = (y * w + x) * 4
                    let a = Int(s[o + 3])
                    if a == 0 { continue }
                    let k = 255 - a
                    for c in 0..<4 { dst[o + c] = UInt8(min(255, Int(s[o + c]) + (Int(dst[o + c]) * k + 127) / 255)) }
                }
            }
        }
    }

    func draw(in view: MTKView) {
        guard let canvas else { return }
        let editor = canvas.editor
        // ポーズ中はデフォーマをかけた絵を出す
        let doc = editor.displayDoc
        let w = doc.width, h = doc.height
        var dirty = editor.takeDirtyRect()
        if ensureTexture(width: w, height: h) {
            dirty = doc.bounds
        }
        guard let texture, let composite else { return }
        // オニオンスキン（再生中は出さない）。作り直したら全体を描き直す
        let onion = canvas.state.isPlaying ? nil : editor.onionSkinImage()
        let onionVersion = onion == nil ? -1 : editor.onionSkinVersion
        if onionVersion != lastOnionVersion {
            dirty = doc.bounds
            lastOnionVersion = onionVersion
        }

        if !dirty.isEmpty {
            // タイル境界に揃えて合成（並列化の単位）
            Compositor.composite(doc, rect: dirty, options: editor.compositeOptions(), into: composite, bufferWidth: w)
            if let onion, onion.count == w * h * 4 { blendOver(onion, into: composite, rect: dirty, width: w) }
            // 前フレームの GPU 読み出しが終わってから書き換える
            lastCommand?.waitUntilCompleted()
            texture.replace(region: MTLRegionMake2D(dirty.x, dirty.y, dirty.width, dirty.height), mipmapLevel: 0,
                            withBytes: composite + (dirty.y * w + dirty.x) * 4, bytesPerRow: w * 4)
            needsMipmaps = true
        }

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        if needsMipmaps, let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            needsMipmaps = false
        }
        let bg = canvas.backgroundGray
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: bg, green: bg, blue: bg, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let t = canvas.canvasToView
        let vs = view.bounds.size
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        var u = RenderUniforms(
            m0: SIMD4(Float(t.a), Float(t.b), Float(t.c), Float(t.d)),
            m1: SIMD4(Float(t.tx), Float(t.ty), Float(vs.width), Float(vs.height)),
            m2: SIMD4(Float(w), Float(h), 8 * scale, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        // 拡大表示ではピクセルをくっきり見せる
        enc.setFragmentSamplerState(canvas.zoom >= 2 ? nearestSampler : linearSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        lastCommand = cmd
    }
}
