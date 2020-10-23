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

// Two phases of render text
// Determine which glyphs will be used to represent the string and how they’ll be positioned relative to one another. We'll use a text engine (CoreText)
//Then, the rendering engine is responsible for turning the abstract description of the glyphs into text on the screen.

// Text layout is unimaginably complex because of language, writing directions glyph sizes
// I use CoreText to handle the text layout & then I'll render the glyphs with the rendering engine

// Labels are backed by CoreText
// Core Text is a Unicode text layout engine that integrates tightly with Quartz 2D (Core Graphics) to lay out and render text.



// Different approaches to text rendering

// Dynamic Rasterization
// - Rasterize (convert to image of pixels) the glyphs for the string value each time the strings change.
// - Send that texture to the gpu. Texture would be the string.
// - Cost of redrawing the string anytime the string changes
// - When zoomed in, glyphs will become blury

// Font atlases
// - Draw all the glyphs into one texture and pass that texture along with coordinate information for the string value.
// - Don't need to rasterize glyphs on demand
// - When zoomed in, glyphs will become blury

// Signed-Distance Fields
// - Not covering this. Too complicated.

struct ValidGlyphDescriptor {
    let glyphIndex: CGGlyph
    let topLeftTexCoord: CGPoint // Coords inside the font atlas
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
    
    var glyphDescriptors: [GlyphDescriptor]!
    var atlasTexture: MTLTexture!
    private var indexGlyphs: [(CGGlyph, CGRect)] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // First thing we're going to do is get our renderer in place.
        
        
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
        
        metalView.clearColor = MTLClearColor(red: 1.0, green: 0.6,
                                             blue: 0.8, alpha: 1)
        
        metalView.delegate = self
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        
//         Shader functions are small programs that run on the GPU
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

//        Sets the information for the draw, such as which shader functions to use, what depth and color settings to use and how to read the vertex data.
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
//
        (atlasTexture, glyphDescriptors) = createFontAtlas()
        createIndexedGlyphs(stringValue: "Hello WTA", font: fontNameString, fontSize: fontSize, drawableSize: metalView.drawableSize)
        
        mtkView(metalView, drawableSizeWillChange: metalView.drawableSize)
    }
    
    // Create a font atlas along with an array of descriptor objects that describe each glyph. ie bounding rect and position in atlas.
    
    func createFontAtlas() -> (MTLTexture, [GlyphDescriptor]) {

        // take for granted - don't build something if its already perfected
        // no limits
        // the hierarchy of metal throught to UIkit

        // better cpu vs gpu answer
        
        // 4096 X 4096
        // it's better to render it at as high a resolution as possible in order to capture all of the fine details.
        let atlasSize: CGFloat = 4096

        // Use gray scale here because we attach color in the fragment shader
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
        // When we're rolling through glyphs we can increase Y to get to the next line in the atlas
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

        // Estimated margin - use this when creating the glyph descriptor - rect / position
        let glyphMargin = CGFloat(ceilf(Float(NSString(string: "A").size(withAttributes: [.font: font]).width)))

        // Set fill color of glyphs
        context.setFillColor(UIColor.black.cgColor)

        // Container for all our generated glyphs
        var mutableGlyphs = [GlyphDescriptor]()

        // Calculating distance to next line
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

            // A glyph is just an index value into a font table.
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

            // Calculated origin of the glyph inside the atlas
            let glyphOriginX: CGFloat = origin.x - boundingRect.origin.x + (glyphMargin * 0.5);
            let glyphOriginY: CGFloat = origin.y + (glyphMargin * 0.5);

            // 3x3 matrix represents scale, rotation & translation

//             [1,             0,           0]
//             [0,            -1,           0] -> -1 Value flips the glyph right side up
//             [glyphOriginX, glyphOriginY, 1]
            // The fourth row / column would be the projection

//             glyphOrigins represent the translation of the glyph

//            Apple Doc
//            The rightmost column of the matrix always contains the constant values 0, 0, 1. Mathematically, this third column is required to allow                   concatenation
            var glyphTransform: CGAffineTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: glyphOriginX, ty: glyphOriginY)

            // Create the path for the character - draws path using the translation above
            guard let path: CGPath = CTFontCreatePathForGlyph(ctFont, glyph, &glyphTransform) else {
                // In order to keep the correct index of glyphs, we need to add placeholder glyphs with fonts with empty spaces. aka spaces
                mutableGlyphs.append(.empty)
                return
            }

            // Add glyph to the context to draw at the translation above
            context.addPath(path)
            context.fillPath()

            var glyphPathBoundingRect = path.boundingBoxOfPath

            // The null rect (i.e., the bounding rect of an empty path) is problematic
            // So we just set it to zero here
            if glyphPathBoundingRect.equalTo(.null) {
                glyphPathBoundingRect = .zero;
            }


            // Texture coordinates are beetween 0 & 1
            // This transforms the glyph coords to the correct position inside the atlas
            let texCoordLeft = glyphPathBoundingRect.origin.x / atlasSize;
            let texCoordRight = (glyphPathBoundingRect.origin.x + glyphPathBoundingRect.size.width) / atlasSize;
            let texCoordTop = (glyphPathBoundingRect.origin.y) / atlasSize;
            let texCoordBottom = (glyphPathBoundingRect.origin.y + glyphPathBoundingRect.size.height) / atlasSize;

            // Add Glyph descriptors that we'll eventually turn in to vertices and send to gpu
            let validGlyph: GlyphDescriptor = .valid(ValidGlyphDescriptor(glyphIndex: glyph,
                                                                          topLeftTexCoord: CGPoint(x: texCoordLeft,
                                                                                                   y: texCoordTop),
                                                                          bottomRightTexCoord: CGPoint(x: texCoordRight,
                                                                                                       y: texCoordBottom), yOrigin: origin.y))
            mutableGlyphs.append(validGlyph)

            // Update our origin for the next glyph in line
            origin.x += boundingRect.width + glyphMargin;
        }


        let contextImage = context.makeImage()!
        // The texture is created by wrapping the glyphs left to right and top to bottom.
        // Could reserve some space by using an optimal packing order
        let fontImage = UIImage(cgImage: contextImage)
        let imageData = fontImage.pngData()!


        // Create atlast texture that we'll pass to the GPU
        let textureLoaderOptions: [MTKTextureLoader.Option: Any] = [.origin: MTKTextureLoader.Origin.topLeft, .SRGB: false, .generateMipmaps: NSNumber(booleanLiteral: false)]
        let textureLoader = MTKTextureLoader(device: device)

        do {
            return (try textureLoader.newTexture(data: imageData, options: textureLoaderOptions), mutableGlyphs)
        } catch {
            fatalError("*** error creating texture \(error.localizedDescription)")
        }
    }
    
    
    // Purpose of this is to take our string & extract out the glyphs. aka - get the index into the font table we're working with.
    
//     We'll end up with two arrays. One array of our strings characters translated in to glyphs (indices into font table)
//     And one array with all of the glyphs in the font. This array will include information on how to
//     find the coordinates for the character in our texture atlas.
    
    func createIndexedGlyphs(stringValue: String, font: String, fontSize: CGFloat, drawableSize: CGSize) {


        UIGraphicsBeginImageContext(CGSize(width: 1, height: 1))
        let context = UIGraphicsGetCurrentContext()

        let font = UIFont(name: font, size: fontSize)!
        let richText = NSAttributedString(string: stringValue, attributes: [.font: font])

        // Sets the glyphs on the CTFrame for the string passed in
        let frameSetter = CTFramesetterCreateWithAttributedString(richText)
        let setterSize = CTFramesetterSuggestFrameSizeWithConstraints(frameSetter, CFRangeMake(0, 0), nil, drawableSize, nil)

        let rect = CGRect(origin: CGPoint(x: -setterSize.width / 2, y: 0), size: setterSize)
        let rectPath = CGPath(rect: rect, transform: nil)

        // CTFramesetterCreateFrame creates a frame full of glyphs at the rectPath. Fills the frame with the glyphs from the frameSetter.

        // We need to dig down to the lowest level in order to extract the glyphs
        // CTFrame -> CTLines -> CTRuns -> CGGlyphs

        let frame = CTFramesetterCreateFrame(frameSetter, CFRangeMake(0, 0), rectPath, nil)

        // Now we have a frame filled with our string glyphs.

        let framePath = CTFrameGetPath(frame)
        let frameBoundingRect = framePath.boundingBoxOfPath


        // We grab the first line in the frame for simplicity's sake

        // CTLine is a line of text
        let line: CTLine = (CTFrameGetLines(frame) as! Array<CTLine>).first!

        // Use this below
        let lineOriginBuffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: 1)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), lineOriginBuffer)

        // CTRun is a run of consecutive glyphs with the same attributes.
        // Will be mutliple runs per CTLine.
        // Again for simplicity's sake - we just grab the first run.
        let run: CTRun = (CTLineGetGlyphRuns(line) as! Array<CTRun>).first!
        let glyphBuffer = UnsafeMutablePointer<CGGlyph>.allocate(capacity: stringValue.count)

        // Get our list of glyphs in a buffer
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphBuffer)

        let glyphCount = CTRunGetGlyphCount(run)
        let glyphPositionBuffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: glyphCount)
        CTRunGetPositions(run, CFRangeMake(0, 0), glyphPositionBuffer)

        let glyphs = UnsafeMutableBufferPointer(start: glyphBuffer, count: glyphCount)
        let positions = UnsafeMutableBufferPointer(start: glyphPositionBuffer, count: glyphCount)

        
        for (index, (glyph, glyphOrigin)) in zip(glyphs, positions).enumerated()  {

            let glyphRect = CTRunGetImageBounds(run, context, CFRangeMake(index, 1))

            let boundsTranslationX = frameBoundingRect.origin.x + lineOriginBuffer.pointee.x
            let boundsTranslationY = frameBoundingRect.height + frameBoundingRect.origin.y - lineOriginBuffer.pointee.y + glyphOrigin.y

            let pathTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: boundsTranslationX, ty: boundsTranslationY)

            // This is the rect around the glyph
            let finalRect = glyphRect.applying(pathTransform)

            // Adding the glyph for this character to our data arary.
            indexGlyphs.append((glyph, finalRect))
        }
    }
}

extension ViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
//        aspectRatio = size.width / size.height
    }
    
    // gpu <- commandQueeu <- CommandBuffer <- renderEncoder
    
    func draw(in view: MTKView) {
        // Describes attributes of this render pass - such as what texture to draw to.
        // The main render pass will use the view descriptor so we render to the view.
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        // This stores all the commands that you’ll ask the GPU to run.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Encodes commands for the gpu which the command buffer manages
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Render pipeline states will have information for the gpu to use until
        // the pipeline state is changed.
        // Such as which vertex & fragment shaders to use. Pixel formats etc.
        renderEncoder.setRenderPipelineState(pipelineState)

        // Send our created atlas texture to the GPU so the shader can
        // render the frame of each glyph.
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)

        // index glyphs = "Hello WTA"
        for indexGlyph in indexGlyphs {

            let idx = Int(indexGlyph.0)
            guard glyphDescriptors.indices.contains(idx) else { continue }

            let descriptor = glyphDescriptors[idx]
            guard case let .valid(glyphDescriptor) = descriptor else { continue }

            let vertices: [TextVertex]

            let vec = indexGlyph.1

            // This will be our main data array that is used by the shader functions.
            vertices = [
                // Top Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float, vec.maxY.float),
                           textureCoordinate: [glyphDescriptor.bottomRightTexCoord.x.float, glyphDescriptor.topLeftTexCoord.y.float]),
                // Top Left
                TextVertex(position: SIMD2<Float>(vec.minX.float, vec.maxY.float),
                           textureCoordinate: [glyphDescriptor.topLeftTexCoord.x.float, glyphDescriptor.topLeftTexCoord.y.float]),
                // Bottom Left
                TextVertex(position: SIMD2<Float>(vec.minX.float,  vec.minY.float),
                           textureCoordinate: [glyphDescriptor.topLeftTexCoord.x.float, glyphDescriptor.bottomRightTexCoord.y.float]),

                // Top Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float, vec.maxY.float),
                           textureCoordinate: [glyphDescriptor.bottomRightTexCoord.x.float, glyphDescriptor.topLeftTexCoord.y.float]),
                // Bottom Left
                TextVertex(position: SIMD2<Float>(vec.minX.float,  vec.minY.float),
                           textureCoordinate: [glyphDescriptor.topLeftTexCoord.x.float, glyphDescriptor.bottomRightTexCoord.y.float]),
                // Bottom Right
                TextVertex(position: SIMD2<Float>(vec.maxX.float,  vec.minY.float),
                           textureCoordinate: [glyphDescriptor.bottomRightTexCoord.x.float, glyphDescriptor.bottomRightTexCoord.y.float])
            ]


            // Passing our data array to the gpu
            renderEncoder.setVertexBytes(vertices, length: MemoryLayout<TextVertex>.stride * vertices.count, index: 17)

            // Setting the dimensions for our gpu to render to
            // For simplicity - I hardcoded it to landscape
            var viewPort = vector_uint2(x: UInt32(2436.0), y: UInt32(1125.0))
            // Passing that to the vertex shader for computing positions
            renderEncoder.setVertexBytes(&viewPort, length: MemoryLayout<vector_uint2>.size, index: 18)

            // Encoding the draw call
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)

        }

        // We've finished our render pass.
        // The render encodder has completed
        renderEncoder.endEncoding()

        // Commannd buffer now has the encoded commands & will be added to the commandQueue to be executed.
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}


extension CGFloat {
    var float: Float {
        return Float(self)
    }
}
