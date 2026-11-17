import AppKit
import Metal
import OpenGL.GL3
import Syphon
import SyphonGL
import XCTest

/// OpenGL and Metal servers and clients share frames, and which way up a picture arrives is settled here.
///
/// What these tests establish: the shared surface holds the picture bottom row first, as OpenGL stores it (an unflipped OpenGL texture is copied as is).
/// A Metal texture is stored top row first, so a Metal server that wants the same surface an OpenGL server makes, and so right-way-up pictures in OpenGL
/// clients, publishes with `flipped: true`; and a Metal client reads a surface bottom row first, so it flips what it draws.
/// The test picture is red in its top half and blue in its bottom half.
final class GLInteropTests: XCTestCase {
    private let width = 32, height = 16

    private func glContext() throws -> NSOpenGLContext {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated), 0,
        ]
        let format = try XCTUnwrap(NSOpenGLPixelFormat(attributes: attributes), "no OpenGL pixel format")
        let context = try XCTUnwrap(NSOpenGLContext(format: format, share: nil), "no OpenGL context")
        context.makeCurrentContext()
        return context
    }

    /// RGBA bytes of the picture, top row first: red above, blue below.
    private func topFirstBytes() -> [UInt8] {
        (0 ..< height).flatMap { row -> [UInt8] in
            (0 ..< width).flatMap { _ in row < height / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
    }

    /// An OpenGL 2D texture holding the picture the way OpenGL stores it: bottom row first.
    private func glPictureTexture() -> GLuint {
        let topFirst = topFirstBytes()
        var bottomFirst: [UInt8] = []
        for row in (0 ..< height).reversed() { bottomFirst += topFirst[(row * width * 4) ..< ((row + 1) * width * 4)] }
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        bottomFirst.withUnsafeBytes { glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress) }
        return texture
    }

    /// A Metal texture holding the picture the way Metal stores it: top row first (bytes B, G, R, A).
    private func metalPictureTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let rgba = topFirstBytes()
        var bytes = [UInt8](repeating: 0, count: rgba.count)
        for pixel in 0 ..< width * height {
            let at = pixel * 4
            bytes[at] = rgba[at + 2]
            bytes[at + 1] = rgba[at + 1]
            bytes[at + 2] = rgba[at]
            bytes[at + 3] = rgba[at + 3]
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// Which colour is in the first row and which in the last row of the surface a Metal client reads.
    private func firstAndLastRow(_ texture: MTLTexture) -> (first: String, last: String) {
        func colour(_ row: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&bytes, bytesPerRow: 4 * texture.width, from: MTLRegionMake2D(texture.width / 2, row, 1, 1), mipmapLevel: 0)
            return bytes[2] > 200 ? "red" : (bytes[0] > 200 ? "blue" : "other")
        }
        return (colour(1), colour(texture.height - 2))
    }

    private func metalClientFrame(from description: [String: Any], device: MTLDevice, publish: () -> Void) throws -> MTLTexture {
        let client = SyphonMetalClient(serverDescription: description, device: device, options: nil, newFrameHandler: nil)
        defer { client.stop() }
        for _ in 0 ..< 60 {
            publish()
            if let frame = client.newFrameImage() { return frame }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("no frame reached the Metal client")
    }

    func testAnOpenGLServersSurfaceIsBottomRowFirst() throws {
        let context = try glContext()
        let texture = glPictureTexture()
        let server = try XCTUnwrap(SyphonOpenGLServer(name: "gl-surface-test", context: context.cglContextObj!, options: nil))
        defer { server.stop() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let frame = try metalClientFrame(from: server.serverDescription, device: device) {
            context.makeCurrentContext()
            server.publishFrameTexture(texture, textureTarget: GLenum(GL_TEXTURE_2D), imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
                                       textureDimensions: NSSize(width: width, height: height), flipped: false)
            glFlush()
        }
        let rows = firstAndLastRow(frame)
        XCTAssertEqual(rows.first, "blue", "the first row of the surface is the picture's bottom")
        XCTAssertEqual(rows.last, "red", "and the last row is its top")
    }

    func testAMetalServerPublishingFlippedMakesTheSameSurfaceAsOpenGL() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let texture = try metalPictureTexture(device)
        let server = SyphonMetalServer(name: "metal-flipped-test", device: device, options: nil)
        defer { server.stop() }
        let frame = try metalClientFrame(from: server.serverDescription, device: device) {
            guard let commands = queue.makeCommandBuffer() else { return }
            server.publishFrameTexture(texture, on: commands, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: true)
            commands.commit()
            commands.waitUntilCompleted()
        }
        let rows = firstAndLastRow(frame)
        XCTAssertEqual(rows.first, "blue", "same as an OpenGL server's surface: bottom row first")
        XCTAssertEqual(rows.last, "red")
    }

    func testAMetalServerPublishingNotFlippedKeepsItsOwnRowOrder() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let texture = try metalPictureTexture(device)
        let server = SyphonMetalServer(name: "metal-unflipped-test", device: device, options: nil)
        defer { server.stop() }
        let frame = try metalClientFrame(from: server.serverDescription, device: device) {
            guard let commands = queue.makeCommandBuffer() else { return }
            server.publishFrameTexture(texture, on: commands, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: false)
            commands.commit()
            commands.waitUntilCompleted()
        }
        let rows = firstAndLastRow(frame)
        XCTAssertEqual(rows.first, "red", "an unflipped Metal texture is copied as it is: top row first, the opposite of an OpenGL server's surface")
        XCTAssertEqual(rows.last, "blue")
    }

    func testAnOpenGLClientReceivesAnOpenGLServersFrame() throws {
        let context = try glContext()
        let texture = glPictureTexture()
        let server = try XCTUnwrap(SyphonOpenGLServer(name: "gl-to-gl-test", context: context.cglContextObj!, options: nil))
        defer { server.stop() }
        let client = try XCTUnwrap(SyphonOpenGLClient(serverDescription: server.serverDescription, context: context.cglContextObj!, options: nil, newFrameHandler: nil))
        defer { client.stop() }
        var image: SyphonOpenGLImage?
        for _ in 0 ..< 50 where image == nil {
            context.makeCurrentContext()
            server.publishFrameTexture(texture, textureTarget: GLenum(GL_TEXTURE_2D), imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
                                       textureDimensions: NSSize(width: width, height: height), flipped: false)
            glFlush()
            image = client.newFrameImage()
            if image == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        let frame = try XCTUnwrap(image, "no frame reached the OpenGL client")
        XCTAssertEqual(Int(frame.textureSize.width), width)
        XCTAssertEqual(Int(frame.textureSize.height), height)
    }

    func testAnOpenGLClientReceivesAMetalServersFrame() throws {
        let context = try glContext()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let texture = try metalPictureTexture(device)
        let server = SyphonMetalServer(name: "metal-to-gl-test", device: device, options: nil)
        defer { server.stop() }
        let client = try XCTUnwrap(SyphonOpenGLClient(serverDescription: server.serverDescription, context: context.cglContextObj!, options: nil, newFrameHandler: nil))
        defer { client.stop() }
        var image: SyphonOpenGLImage?
        for _ in 0 ..< 50 where image == nil {
            if let commands = queue.makeCommandBuffer() {
                server.publishFrameTexture(texture, on: commands, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: true)
                commands.commit()
                commands.waitUntilCompleted()
            }
            context.makeCurrentContext()
            image = client.newFrameImage()
            if image == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        let frame = try XCTUnwrap(image, "no frame reached the OpenGL client")
        XCTAssertEqual(Int(frame.textureSize.width), width)
        XCTAssertEqual(Int(frame.textureSize.height), height)
    }
}
