# Syphon as a Swift package (Metal and OpenGL)

This branch (`swiftpm-metal`) of Kaiyou Digital's fork adds a `Package.swift` so an app can depend on Syphon's Metal or OpenGL servers and clients through Swift Package Manager, without building `Syphon.xcodeproj` and without the Metal Toolchain. Everything else in the repository is upstream's, unchanged. Syphon is © bangnoise (Tom Butterworth) & vade (Anton Marini) and the Metal code © Maxime Touroute & Philippe Chaurand (Millumin); the licence is upstream's 2-clause BSD, kept as `LICENSE.Syphon` and in every vendored file.

## Use

```swift
.package(url: "https://github.com/Kaiyou-Digital/Syphon-Framework.git", revision: "<commit on this branch>")
// target dependency: .product(name: "Syphon", package: "Syphon-Framework")      (Metal)
//                    .product(name: "SyphonGL", package: "Syphon-Framework")    (OpenGL, optional)
```

```swift
import Syphon
let server = SyphonMetalServer(name: "My app", device: device, options: nil)
server?.publishFrameTexture(texture, on: commandBuffer, imageRegion: NSRect(x: 0, y: 0, width: w, height: h), flipped: true) // see "Which way up a picture is"
```

macOS 13 or later. There are two products, so an app links only what it uses:

- **`Syphon`**: the Metal server and client (`SyphonMetalServer`, `SyphonMetalClient`), `SyphonServerDirectory`, and the base classes and messaging they share.
- **`SyphonGL`**: the OpenGL server, client and image (`SyphonOpenGLServer`, `SyphonOpenGLClient`, `SyphonOpenGLImage`, and the older names `SyphonServer`, `SyphonClient`, `SyphonImage`). It builds on `Syphon` and links OpenGL, which Apple deprecated; a Metal-only app never links it.

## Which way up a picture is

Measured (`GLInteropTests`), not assumed from the headers. The shared surface holds the picture **bottom row first**, as OpenGL stores it:

- An OpenGL server publishing an unflipped texture (`flipped: NO`, the ordinary case) makes that surface.
- A Metal texture is stored top row first. A Metal server that publishes with `flipped: YES` makes exactly the same surface as the OpenGL server, so OpenGL apps show its picture right way up. With `flipped: NO` the rows are copied as they are, and OpenGL clients would show the picture upside down.
- The Metal client gives the surface as it is, bottom row first: **a Metal client flips what it draws**.

So an app that wants to look right to the rest of the Syphon world publishes Metal frames with `flipped: YES` and flips what it receives. Two apps that both skip the flip agree with each other and are both upside down to everything else.

## What differs from upstream's files in `Sources/Syphon`

All changes are marked `KAIYOU:`.

- `SyphonServerRendererMetal.m` compiles its two shaders from source (`SyphonMetalShaderSource.m`, generated from `SyphonMetalShaders.metal` and `SyphonServerMetalTypes.h`) instead of loading `default.metallib` from the framework bundle. A package linked statically has no such bundle.
- `SyphonCFMessageReceiver.m` gives its `CFMessagePort` a box holding a weak reference to the receiver, where upstream passed an unretained `self`. A message already queued on the messaging thread when the receiver was freed used to be delivered to freed memory (a crash on the `info.v002.syphon.messaging` thread). With the weak box such a message finds nothing and is dropped. Measured with a test that frees a server while its frame is still in flight: 4 crashes in 25 runs before, 0 in 40 after.
- `SyphonPrivate.h` imports Cocoa, which upstream got from `Syphon_Prefix.pch`.
- `include/module.modulemap` replaces the framework module map; `Package.swift` defines `SYPHONLOG` as empty, as the prefix header did outside debug builds.

`SwiftPM/assemble.py` regenerates `Sources/Syphon`, `Package.swift` and `Tests/` from upstream's files in this repository (`python3 SwiftPM/assemble.py . .`), so moving to a newer upstream commit is a rebase plus one run. `swift test` runs one round trip: a frame published by a `SyphonMetalServer` is read back from a `SyphonMetalClient` in the same process.

## Known limits (upstream behaviour, measured here)

- **Let the last frame finish before `stop()`.** Stopping and freeing a server while the command buffer that publishes its newest frame is still running can crash (in `publishNewFrame` on Metal's completion queue, or in `SyphonServerConnectionManager`'s destructor). Wait for that command buffer (`waitUntilCompleted()`, or the completion handler) first.
- **A rare trap in CoreFoundation when servers are torn down.** With the contract above, about 1.5% of runs of the 300-teardown test (roughly 1 teardown in 15,000) still trap in `CFMessagePort` deallocation, called from `SyphonCFMessageReceiver dealloc`. It happens with and without this fork's change and is not understood. Not a concern for an app that starts and stops a server occasionally; it matters if you create and destroy servers in a loop.

Based on upstream `f4761677` (2026-09-21).
