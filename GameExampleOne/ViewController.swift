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

//Drawing a string of text consists of at least two distinct phases.
//First, the text layout engine determines which glyphs will be used to represent the string and how they’ll be positioned relative to one another. Then, the rendering engine is responsible for turning the abstract description of the glyphs into text on the screen.

// Labels are backed by CoreText
// Core Text is a Unicode text layout engine that integrates tightly with Quartz 2D (Core Graphics) to lay out and render text.

// Text layout is unimaginably complex because of language, writing directions glyph sizes
// I use CoreText to handle the text layout & then I'll render the glyphs with the rendering engine



// Different approaches to text rendering

// Dynamic Rasterization


// Font atlases


// Signed Distance Fields

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

    var pipelineState: MTLRenderPipelineState!
    
    var aspectRatio: CGFloat = 1.0
    
    // Text
    let fontNameString = "Arial"
    let fontSize: CGFloat = 136
    
    var glyphs: [GlyphDescriptor]!
    var atlasTexture: MTLTexture!
    private var indexGlyphs: [(CGGlyph, CGRect)] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // MTKView part of MetalKit which includes conveniences like the draw and resize methods below. 
        let metalView = view as! MTKView
        // The software reference to the GPU hardware device.
        self.device  = MTLCreateSystemDefaultDevice()!
//        Responsible for creating and organizing MTLCommandBuffers
//        each frame.
//        A serial queue of command buffers to be executed by the device.
        self.commandQueue = device.makeCommandQueue()!
        
        // Contains the source code from your vertex and fragment shader functions.
        self.library = device.makeDefaultLibrary()!
        
        
        metalView.device = device
        metalView.depthStencilPixelFormat = .depth32Float
        
        metalView.clearColor = MTLClearColor(red: 0.0, green: 0.6,
                                             blue: 0.8, alpha: 1)
        
        metalView.delegate = self
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        
        // Shader functions are small programs that run on the GPU
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

//        Sets the information for the draw, such as which shader functions to use, what depth and color settings to use and how to read the vertex data.
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        (atlasTexture, glyphs) = createFontAtlas()
        createIndexedGlyphs(stringValue: "Hello WTA", font: fontNameString, fontSize: fontSize, drawableSize: metalView.drawableSize)
        
        mtkView(metalView, drawableSizeWillChange: metalView.drawableSize)
    }
    
    func createFontAtlas() -> (MTLTexture, [GlyphDescriptor]) {
        
        // 4096 X 4096
        // it's better to render it at as high a resolution as possible in order to capture all of the fine details.
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

        // Create core text font
        let font = UIFont(name: fontNameString, size: fontSize)!
        let ctFont = CTFontCreateWithName(font.fontName as CFString, fontSize, nil)

        // Glyph(Character) count for our font 'Arial'
        let fontGlyphCount: CFIndex = CTFontGetGlyphCount(ctFont)

        // Estimated margin
        let glyphMargin = CGFloat(ceilf(Float(NSString(string: "A").size(withAttributes: [.font: font]).width)))

        // Set fill color so that glyphs are solid white
        context.setFillColor(UIColor.black.cgColor)
        
        // Container for all our generated glyphs
        var mutableGlyphs = [GlyphDescriptor]()

        // Distance from baseline to top of tallest glyph
        let fontAscent = CTFontGetAscent(ctFont)
        // Distance from baseline to the lowest point in glyphs
        let fontDescent = CTFontGetDescent(ctFont)
        
        // Y origin for each line. The top left of each line.
        var origin = CGPoint(x: 0, y: fontAscent)
        var maxYCoordForLine: CGFloat = -1

        // Iterate through all the glyphs in the font
        (0..<fontGlyphCount).forEach { (index) in
            // The Glyph!
            var glyph: CGGlyph = UInt16(index)
            // Rect of glyph
            let boundingRect = CTFontGetBoundingRectsForGlyphs(ctFont,
                                            CTFontOrientation.horizontal,
                                            &glyph,
                                            nil,
                                            1)

            // If we've reached the far right side of our atlas start a new line
            if origin.x + boundingRect.maxX + glyphMargin > atlasSize {
                origin.x = 0
                // Using the max y coord to find the start of the next line
                origin.y = CGFloat(maxYCoordForLine) + glyphMargin + fontDescent
                maxYCoordForLine = -1
            }

            // Getting the maximum y coord of all the glyphs for this line
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
        // The texture is created by wrapping the glyphs left to right and top to bottom.
        // Could reserve some space by using an optimal packing order
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
    
    // Creating glyphs with Core text
    func createIndexedGlyphs(stringValue: String, font: String, fontSize: CGFloat, drawableSize: CGSize) {
        UIGraphicsBeginImageContext(CGSize(width: 1, height: 1))
        let context = UIGraphicsGetCurrentContext()

        let font = UIFont(name: font, size: fontSize)!
        let richText = NSAttributedString(string: stringValue, attributes: [.font: font])

        let frameSetter = CTFramesetterCreateWithAttributedString(richText)
        let setterSize = CTFramesetterSuggestFrameSizeWithConstraints(frameSetter, CFRangeMake(0, 0), nil, drawableSize, nil)

        let rect = CGRect(origin: CGPoint(x: -setterSize.width / 2, y: 0), size: setterSize)
        let rectPath = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(frameSetter, CFRangeMake(0, 0), rectPath, nil)

        let framePath = CTFrameGetPath(frame)
        let frameBoundingRect = framePath.boundingBoxOfPath
        let line: CTLine = (CTFrameGetLines(frame) as! Array<CTLine>).first!

        let lineOriginBuffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: 1)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), lineOriginBuffer)

        let run: CTRun = (CTLineGetGlyphRuns(line) as! Array<CTRun>).first!
        let glyphBuffer = UnsafeMutablePointer<CGGlyph>.allocate(capacity: stringValue.count)
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphBuffer)

        let glyphCount = CTRunGetGlyphCount(run)
        let glyphPositionBuffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: glyphCount)
        CTRunGetPositions(run, CFRangeMake(0, 0), glyphPositionBuffer)

        let glyphs = UnsafeMutableBufferPointer(start: glyphBuffer, count: glyphCount)
        let positions = UnsafeMutableBufferPointer(start: glyphPositionBuffer, count: glyphCount)

        for (index, (glyph, glyphOrigin)) in zip(glyphs, positions).enumerated()  {

            let glyphRect = CTRunGetImageBounds(run, context, CFRangeMake(index, 1))
            let boundsTransX = frameBoundingRect.origin.x + lineOriginBuffer.pointee.x
            print(lineOriginBuffer.pointee)
            let boundsTransY = frameBoundingRect.height + frameBoundingRect.origin.y - lineOriginBuffer.pointee.y + glyphOrigin.y
            let pathTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: boundsTransX, ty: boundsTransY)
            let finalRect = glyphRect.applying(pathTransform)

            indexGlyphs.append((glyph, finalRect))
        }
    }
}

extension ViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspectRatio = size.width / size.height
    }
    
    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        // This stores all the commands that you’ll ask the GPU to run.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // Encodes commands for the gpu which the command buffer manages
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Render Text
        renderEncoder.setRenderPipelineState(pipelineState)
        // Send texture to fragment shader
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)
        
        for indexGlyph in indexGlyphs {

            let idx = Int(indexGlyph.0)
            guard glyphs.indices.contains(idx) else { continue }

            let descriptor = glyphs[idx]
            guard case let .valid(glyph) = descriptor else { continue }
            
            let vertices: [TextVertex]
            
            let vec = indexGlyph.1
            vertices = [
                // Top Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float, vec.maxY.float),
                           textureCoordinate: [glyph.bottomRightTexCoord.x.float, glyph.topLeftTexCoord.y.float]),
                // Top Left
                TextVertex(position: SIMD2<Float>(vec.minX.float, vec.maxY.float),
                           textureCoordinate: [glyph.topLeftTexCoord.x.float, glyph.topLeftTexCoord.y.float]),
                // Bottom Left
                TextVertex(position: SIMD2<Float>(vec.minX.float,  vec.minY.float),
                           textureCoordinate: [glyph.topLeftTexCoord.x.float, glyph.bottomRightTexCoord.y.float]),
                
                // Top Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float, vec.maxY.float),
                           textureCoordinate: [glyph.bottomRightTexCoord.x.float, glyph.topLeftTexCoord.y.float]),
                // Bottom Left
                TextVertex(position: SIMD2<Float>(vec.minX.float,  vec.minY.float),
                           textureCoordinate: [glyph.topLeftTexCoord.x.float, glyph.bottomRightTexCoord.y.float]),
                // Bottom Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float,  vec.minY.float),
                           textureCoordinate: [glyph.bottomRightTexCoord.x.float, glyph.bottomRightTexCoord.y.float])
            ]
            
            
            renderEncoder.setVertexBytes(vertices, length: MemoryLayout<TextVertex>.stride * vertices.count, index: 17)
            var viewPort = vector_uint2(x: UInt32(2436.0), y: UInt32(1125.0))
            renderEncoder.setVertexBytes(&viewPort, length: MemoryLayout<vector_uint2>.size, index: 18)
            
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            
        }
        
        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}


extension CGFloat {
    var float: Float {
        return Float(self)
    }
}
