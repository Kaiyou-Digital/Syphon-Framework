import Metal
import Syphon
import XCTest

/// A frame published by a SyphonMetalServer arrives, unchanged, at a SyphonMetalClient in the same process
/// (which also proves the shaders compile from source at run time: the server's renderer builds its pipeline on first publish).
final class RoundTripTests: XCTestCase {
    /// Stopping and freeing a server and its client while a message is in flight must not touch freed memory
    /// (the message receiver used to hand an unretained `self` to its port, so a queued callback could run after dealloc).
    func testStoppingAndFreeingServersWhileMessagesAreInFlightDoesNotCrash() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for round in 0 ..< 300 {
            autoreleasepool {
                let server = SyphonMetalServer(name: "teardown-\(round)", device: device, options: nil)
                let client = SyphonMetalClient(serverDescription: server.serverDescription, device: device, options: nil, newFrameHandler: { _ in })
                if let commands = queue.makeCommandBuffer() {
                    server.publishFrameTexture(source, on: commands, imageRegion: NSRect(x: 0, y: 0, width: 16, height: 16), flipped: false)
                    commands.commit()
                    commands.waitUntilCompleted() // the contract: let the last frame finish before stopping the server
                }
                server.stop()
                client.stop()
            }
        }
    }

    func testAFramePublishedByTheServerReachesAClient() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let (width, height) = (64, 32)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixel: [UInt8] = [10, 200, 30, 255] // B G R A
        let bytes = (0 ..< width * height).flatMap { _ in pixel }
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)

        let server = try XCTUnwrap(SyphonMetalServer(name: "round-trip-test", device: device, options: nil))
        defer { server.stop() }
        let client = try XCTUnwrap(SyphonMetalClient(serverDescription: server.serverDescription, device: device, options: nil, newFrameHandler: nil))
        defer { client.stop() }

        var received: MTLTexture?
        for _ in 0 ..< 50 where received == nil {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            server.publishFrameTexture(source, on: commands, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: false)
            commands.commit()
            commands.waitUntilCompleted()
            received = client.newFrameImage()
            if received == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        let frame = try XCTUnwrap(received, "no frame reached the client in 5 s")
        XCTAssertEqual(frame.width, width)
        XCTAssertEqual(frame.height, height)
        var back = [UInt8](repeating: 0, count: 4)
        frame.getBytes(&back, bytesPerRow: width * 4, from: MTLRegionMake2D(width / 2, height / 2, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(back, pixel, "the pixel arrives as it was sent")
    }
}
