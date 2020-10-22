//
//  ViewController.swift
//  GameExampleOne
//
//  Created by Scott Mehus on 10/12/20.
//

import UIKit
import CoreGraphics
import MetalKit
import CoreText

struct ValidGlyphDescriptor {
    let glyphIndex: CGGlyph
    let topLeftTexCoord: CGPoint
    let bottomRightTexCoord: CGPoint
    let yOrigin: CGFloat
}

enum GlyphDescriptor {
    case empty
    case valid(ValidGlyphDescriptor)
}

class ViewController: UIViewController {
    
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!
    var device: MTLDevice!
    
    private var mtkMesh: MTKMesh!
    private var mdlMesh: MDLMesh!
    
    var pipelineDescriptor: MTLRenderPipelineDescriptor!
    var pipelineState: MTLRenderPipelineState!
    
    var aspectRatio: CGFloat = 1.0
    
    // Text
    let fontNameString = "Arial"
    let fontSize: CGFloat = 144
    
    var glyphs: [GlyphDescriptor]!
    var atlasTexture: MTLTexture!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        

        let metalView = view as! MTKView
        self.device  = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        self.library = device.makeDefaultLibrary()!
        
        
        metalView.device = device
        metalView.depthStencilPixelFormat = .depth32Float
        
        metalView.clearColor = MTLClearColor(red: 0.0, green: 0.6,
                                             blue: 0.8, alpha: 1)
        
        metalView.delegate = self
        
        let allocator = MTKMeshBufferAllocator(device: device)
        mdlMesh = MDLMesh(boxWithExtent: [1, 1, 1],
                          segments: [1, 1, 1],
                          inwardNormals: false,
                          geometryType: .triangles,
                          allocator: allocator)
        
        mtkMesh = try! MTKMesh(mesh: mdlMesh, device: device)
        
        pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        pipelineDescriptor.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mtkMesh.vertexDescriptor)
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        mtkView(metalView, drawableSizeWillChange: metalView.drawableSize)
    }
    
    func setupText() {
        // Dynamic Rasterization
        // strings are rasterized on the CPU, and the resulting bitmap is uploaded as a texture to the GPU for drawing
        (atlasTexture, glyphs) = createFontAtlas()
        
    }
    
    func createFontAtlas() -> (MTLTexture, [GlyphDescriptor]) {
        // Should create largest
        let atlasSize: CGFloat = 4096
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo.alphaInfoMask.rawValue & CGImageAlphaInfo.none.rawValue
        let context = CGContext(data: nil,
                                width: Int(atlasSize),
                                height: Int(atlasSize),
                                bitsPerComponent: 8,
                                bytesPerRow: Int(atlasSize),
                                space: colorSpace,
                                bitmapInfo: bitmapInfo)!
        // Turn off antialiasing so we only get fully-on or fully-off pixels.
        // This implicitly disables subpixel antialiasing and hinting.
        context.setAllowsAntialiasing(false)

        // Flip context coordinate space so y increases downward
        context.translateBy(x: 0, y: atlasSize)
        context.scaleBy(x: 1, y: -1)

        // Fill background color
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: atlasSize, height: atlasSize))

        let font = UIFont(name: fontNameString, size: fontSize)!
        let ctFont = CTFontCreateWithName(font.fontName as CFString, fontSize, nil)

        let fontGlyphCount: CFIndex = CTFontGetGlyphCount(ctFont)

        let glyphMargin = CGFloat(ceilf(Float(NSString(string: "A").size(withAttributes: [.font: font]).width)))

        // Set fill color so that glyphs are solid white
        context.setFillColor(UIColor.black.cgColor)

        var mutableGlyphs = [GlyphDescriptor]()

        let fontAscent = CTFontGetAscent(ctFont)
        let fontDescent = CTFontGetDescent(ctFont)

        var origin = CGPoint(x: 0, y: fontAscent)
        var maxYCoordForLine: CGFloat = -1

        (0..<fontGlyphCount).forEach { (index) in
            var glyph: CGGlyph = UInt16(index)
            let boundingRect = CTFontGetBoundingRectsForGlyphs(ctFont,
                                            CTFontOrientation.horizontal,
                                            &glyph,
                                            nil,
                                            1)

            // If at the end of the line
            if origin.x + boundingRect.maxX + glyphMargin > atlasSize {
                origin.x = 0
                origin.y = CGFloat(maxYCoordForLine) + glyphMargin + fontDescent
                maxYCoordForLine = -1
            }

            // Add a new line i think
            if origin.y + boundingRect.maxY > maxYCoordForLine {
                maxYCoordForLine = origin.y + boundingRect.maxY;
            }

            let glyphOriginX: CGFloat = origin.x - boundingRect.origin.x + (glyphMargin * 0.5);
            let glyphOriginY: CGFloat = origin.y + (glyphMargin * 0.5);

            // gotta look up what this is doing...
            var glyphTransform: CGAffineTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: glyphOriginX, ty: glyphOriginY)

            guard let path: CGPath = CTFontCreatePathForGlyph(ctFont, glyph, &glyphTransform) else {
                // In order to keep the correct index of glyphs, we need to add placeholder glyphs with fonts with empty spaces. aka spaces
                mutableGlyphs.append(.empty)
                return
            }

            context.addPath(path)
            context.fillPath()

            var glyphPathBoundingRect = path.boundingBoxOfPath

            // The null rect (i.e., the bounding rect of an empty path) is problematic
                // because it has its origin at (+inf, +inf); we fix that up here
            if glyphPathBoundingRect.equalTo(.null)
                {
                    glyphPathBoundingRect = .zero;
                }


            // this creates coords between 0 & 1 for the texture
            let texCoordLeft = glyphPathBoundingRect.origin.x / atlasSize;
            let texCoordRight = (glyphPathBoundingRect.origin.x + glyphPathBoundingRect.size.width) / atlasSize;
            let texCoordTop = (glyphPathBoundingRect.origin.y) / atlasSize;
            let texCoordBottom = (glyphPathBoundingRect.origin.y + glyphPathBoundingRect.size.height) / atlasSize;

            // add glyphDescriptors
            // Not sure if needed if not doing signed-distance field

            let validGlyph: GlyphDescriptor = .valid(ValidGlyphDescriptor(glyphIndex: glyph,
                                                                          topLeftTexCoord: CGPoint(x: texCoordLeft,
                                                                                                   y: texCoordTop),
                                                                          bottomRightTexCoord: CGPoint(x: texCoordRight,
                                                                                                       y: texCoordBottom), yOrigin: origin.y))

            mutableGlyphs.append(validGlyph)

            origin.x += boundingRect.width + glyphMargin;
        }

        
        let contextImage = context.makeImage()!
        let fontImage = UIImage(cgImage: contextImage)
        let imageData = fontImage.pngData()!

        let textureLoaderOptions: [MTKTextureLoader.Option: Any] = [.origin: MTKTextureLoader.Origin.topLeft, .SRGB: false, .generateMipmaps: NSNumber(booleanLiteral: false)]

        let textureLoader = MTKTextureLoader(device: device)

        do {
            return (try textureLoader.newTexture(data: imageData, options: textureLoaderOptions), mutableGlyphs)
        } catch {
            fatalError("*** error creating texture \(error.localizedDescription)")
        }
    }
}

extension ViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspectRatio = size.width / size.height
    }
    
    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let projection = float4x4(perspectiveProjectionFov: Float(70).degreesToRadians,
                                  aspectRatio: Float(aspectRatio),
                                  nearZ: 0.001,
                                  farZ: 100.0)
        
        let translateMatrix = float4x4(translation: [0, 0, -2])
        let rotateMatrix = float4x4(rotation: [0, 0, 0])
        let scaleMatrix = float4x4(scaling: [1, 1, 1])
        // The world moves - not the camera. So we use inverse because if we want the camera to move right - the world needs to move left.
        let viewMatrix =  (translateMatrix * rotateMatrix * scaleMatrix).inverse
        
        // Model positioning
        let translation = float4x4(translation: [0, 0, 0])
        let rotation = float4x4(rotation: [0, 0, 0])
        let scale = float4x4(scaling: [1, 1, 1])
        
        // Used to calcluate position in shader
        var uniforms = Uniforms()
        uniforms.modelMatrix = translation * rotation * scale
        uniforms.viewMatrix = viewMatrix
        uniforms.projectionMatrix = projection
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Aligns with stage_in in the shader file.
        renderEncoder.setVertexBuffer(mtkMesh.vertexBuffers.first!.buffer, offset: 0, index: 0)
        
        let submesh = mtkMesh.submeshes.first!
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: submesh.indexCount,
                                            indexType: submesh.indexType,
                                            indexBuffer: submesh.indexBuffer.buffer,
                                            indexBufferOffset: submesh.indexBuffer.offset)
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}


import Foundation

typealias float2 = SIMD2<Float>
typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>

let π = Float.pi

extension Float {
    var radiansToDegrees: Float {
        (self / π) * 180
    }
    var degreesToRadians: Float {
        (self / 180) * π
    }
}

// MARK:- float4
extension float4x4 {
    // MARK:- Translate
    init(translation: float3) {
        let matrix = float4x4(
            [            1,             0,             0, 0],
            [            0,             1,             0, 0],
            [            0,             0,             1, 0],
            [translation.x, translation.y, translation.z, 1]
        )
        self = matrix
    }

    // MARK:- Scale
    init(scaling: float3) {
        let matrix = float4x4(
            [scaling.x,         0,         0, 0],
            [        0, scaling.y,         0, 0],
            [        0,         0, scaling.z, 0],
            [        0,         0,         0, 1]
        )
        self = matrix
    }

    init(scaling: Float) {
        self = matrix_identity_float4x4
        columns.3.w = 1 / scaling
    }

    // MARK:- Rotate
    init(rotationX angle: Float) {
        let matrix = float4x4(
            [1,           0,          0, 0],
            [0,  cos(angle), sin(angle), 0],
            [0, -sin(angle), cos(angle), 0],
            [0,           0,          0, 1]
        )
        self = matrix
    }

    init(rotationY angle: Float) {
        let matrix = float4x4(
            [cos(angle), 0, -sin(angle), 0],
            [         0, 1,           0, 0],
            [sin(angle), 0,  cos(angle), 0],
            [         0, 0,           0, 1]
        )
        self = matrix
    }

    init(rotationZ angle: Float) {
        let matrix = float4x4(
            [ cos(angle), sin(angle), 0, 0],
            [-sin(angle), cos(angle), 0, 0],
            [          0,          0, 1, 0],
            [          0,          0, 0, 1]
        )
        self = matrix
    }

    init(rotation angle: float3) {
        let rotationX = float4x4(rotationX: angle.x)
        let rotationY = float4x4(rotationY: angle.y)
        let rotationZ = float4x4(rotationZ: angle.z)
        self = rotationX * rotationY * rotationZ
    }

    init(rotationYXZ angle: float3) {
        let rotationX = float4x4(rotationX: angle.x)
        let rotationY = float4x4(rotationY: angle.y)
        let rotationZ = float4x4(rotationZ: angle.z)
        self = rotationY * rotationX * rotationZ
    }

    // MARK:- Identity
    static func identity() -> float4x4 {
        matrix_identity_float4x4
    }

    // MARK:- Upper left 3x3
    var upperLeft: float3x3 {
        let x = columns.0.xyz
        let y = columns.1.xyz
        let z = columns.2.xyz
        return float3x3(columns: (x, y, z))
    }
    
    init(perspectiveProjectionFov fovRadians: Float, aspectRatio aspect: Float, nearZ: Float, farZ: Float) {
        let yScale = 1 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = farZ - nearZ
        let zScale = (farZ + nearZ) / zRange
        let wzScale = -2 * farZ * nearZ / zRange

        let xx = xScale
        let yy = yScale
        let zz = zScale
        let zw = Float(1)
        let wz = wzScale

        self.init(float4(xx,  0,  0,  0),
                  float4( 0, yy,  0,  0),
                  float4( 0,  0, zz, zw),
                  float4( 0,  0, wz,  1))
    }

    // left-handed LookAt
    init(eye: float3, center: float3, up: float3) {
        let z = normalize(center-eye)
        let x = normalize(cross(up, z))
        let y = cross(z, x)

        let X = float4(x.x, y.x, z.x, 0)
        let Y = float4(x.y, y.y, z.y, 0)
        let Z = float4(x.z, y.z, z.z, 0)
        let W = float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)

        self.init()
        columns = (X, Y, Z, W)
    }

    // MARK:- Orthographic matrix
    init(orthoLeft left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
        let X = float4(2 / (right - left), 0, 0, 0)
        let Y = float4(0, 2 / (top - bottom), 0, 0)
        let Z = float4(0, 0, 1 / (far - near), 0)
        let W = float4((left + right) / (left - right),
                       (top + bottom) / (bottom - top),
                       near / (near - far),
                       1)
        self.init()
        columns = (X, Y, Z, W)
    }

    // convert double4x4 to float4x4
    init(_ m: matrix_double4x4) {
        self.init()
        let matrix: float4x4 = float4x4(float4(m.columns.0),
                                        float4(m.columns.1),
                                        float4(m.columns.2),
                                        float4(m.columns.3))
        self = matrix
    }
}

// MARK:- float3x3
extension float3x3 {
    init(normalFrom4x4 matrix: float4x4) {
        self.init()
        columns = matrix.upperLeft.inverse.transpose.columns
    }
}

// MARK:- float4
extension float4 {
    var xyz: float3 {
        get {
            float3(x, y, z)
        }
        set {
            x = newValue.x
            y = newValue.y
            z = newValue.z
        }
    }

    // convert from double4
    init(_ d: SIMD4<Double>) {
        self.init()
        self = [Float(d.x), Float(d.y), Float(d.z), Float(d.w)]
    }
}



// **** Generated Functions ***** \\


// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                         vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                         vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                         vector_float4(                  0,                   0,                   0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                         vector_float4(0, 1, 0, 0),
                                         vector_float4(0, 0, 1, 0),
                                         vector_float4(translationX, translationY, translationZ, 1)))
}

func matrix_perspective_right_hand(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4.init(columns:(vector_float4(xs,  0, 0,   0),
                                         vector_float4( 0, ys, 0,   0),
                                         vector_float4( 0,  0, zs, -1),
                                         vector_float4( 0,  0, zs * nearZ, 0)))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}
