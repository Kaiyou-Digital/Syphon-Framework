"""Assemble a Swift package of Syphon's Metal subset from upstream's source (BSD 2-Clause).
usage: assemble_syphon.py <upstream checkout> <out dir>
Changes to upstream, all marked `KAIYOU:`: the Metal shaders are compiled from inlined source at run time (a statically linked package has no
default.metallib), and the package builds with SwiftPM alone (no Xcode project, no Metal Toolchain)."""
import os, re, shutil, sys

up, out = sys.argv[1], sys.argv[2]
src = os.path.join(out, "Sources", "Syphon")
inc = os.path.join(src, "include", "Syphon")
os.makedirs(inc, exist_ok=True)

PUBLIC = ["SyphonServerBase.h", "SyphonMetalServer.h", "SyphonClientBase.h", "SyphonMetalClient.h", "SyphonServerDirectory.h", "SyphonSubclassing.h"]
PRIVATE_H = ["SyphonCFMessageReceiver.h", "SyphonCFMessageSender.h", "SyphonClientConnectionManager.h", "SyphonDispatch.h", "SyphonMessageQueue.h",
             "SyphonMessageReceiver.h", "SyphonMessageSender.h", "SyphonMessaging.h", "SyphonPrivate.h", "SyphonServerConnectionManager.h",
             "SyphonServerMetalTypes.h", "SyphonServerRendererMetal.h"]
IMPL = ["SyphonCFMessageReceiver.m", "SyphonCFMessageSender.m", "SyphonClientBase.m", "SyphonClientConnectionManager.m", "SyphonDispatch.c",
        "SyphonMessageQueue.m", "SyphonMessageReceiver.m", "SyphonMessageSender.m", "SyphonMessaging.m", "SyphonMetalClient.m", "SyphonMetalServer.m",
        "SyphonPrivate.m", "SyphonServerBase.m", "SyphonServerConnectionManager.m", "SyphonServerDirectory.m", "SyphonServerRendererMetal.m"]

for f in PUBLIC: shutil.copy(os.path.join(up, f), os.path.join(inc, f))
for f in PRIVATE_H + IMPL: shutil.copy(os.path.join(up, f), os.path.join(src, f))
shutil.copy(os.path.join(up, "License.txt"), os.path.join(out, "LICENSE.Syphon"))

# the renderer: compile the shaders from source instead of loading default.metallib
renderer = os.path.join(src, "SyphonServerRendererMetal.m")
text = open(renderer).read()
old = """        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        id<MTLLibrary> defaultLibrary = [device newDefaultLibraryWithBundle:bundle error:&error];"""
new = """        // KAIYOU: compiled from source (SyphonMetalShaderSource.m); a Swift package has no default.metallib to load
        id<MTLLibrary> defaultLibrary = [device newLibraryWithSource:SyphonMetalShaderSource() options:nil error:&error];"""
assert old in text, "renderer source changed upstream"
text = text.replace(old, new).replace('#import "SyphonServerRendererMetal.h"', '#import "SyphonServerRendererMetal.h"\n#import "SyphonMetalShaderSource.h"', 1)
open(renderer, "w").write(text)

# the CFMessagePort callback was given an unretained `self`: a callback already queued on the messaging thread could run after the receiver was
# freed (invalidate stops new messages, not queued ones) and message a dangling object. The port now holds a box with a weak reference.
cf = os.path.join(src, "SyphonCFMessageReceiver.m")
ctext = open(cf).read()
cb_old = re.search(r"static CFDataRef MessageReturnCallback \(.*?\n\}\n", ctext, flags=re.S)
assert cb_old and "(__bridge SyphonMessageReceiver *)info" in cb_old.group(0), "SyphonCFMessageReceiver.m changed upstream"
cb_new = """// KAIYOU: the port's context is a box with a weak reference to the receiver (the port retains the box), not an unretained `self`:
// a callback queued before the receiver was freed finds nil and does nothing, instead of messaging freed memory.
@interface SyphonWeakReceiverBox : NSObject
@property (weak) SyphonMessageReceiver *target;
@end
@implementation SyphonWeakReceiverBox
@end

static const void *ReceiverBoxRetain(const void *info) { return CFRetain(info); }
static void ReceiverBoxRelease(const void *info) { CFRelease(info); }

static CFDataRef MessageReturnCallback (
								 CFMessagePortRef local,
								 SInt32 msgid,
								 CFDataRef data,
								 void *info
								 )
{
	SyphonMessageReceiver *receiver = ((__bridge SyphonWeakReceiverBox *)info).target;
	if (receiver == nil) return NULL;
	id <NSCoding> decoded;
	if (data && CFDataGetLength(data))
	{
        NSSet<Class> *classes = receiver.allowedClasses;
        decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:(__bridge  NSData *)data error:nil];
	} else {
		decoded = nil;
	}
	[receiver receiveMessageWithPayload:decoded ofType:msgid];
	return NULL;
}
"""
ctext = ctext.replace(cb_old.group(0), cb_new, 1)
ctx_old = "CFMessagePortContext context = (CFMessagePortContext){0,(__bridge void *)(self),NULL,NULL,NULL};"
assert ctx_old in ctext, "SyphonCFMessageReceiver.m context changed upstream"
ctext = ctext.replace(ctx_old, """SyphonWeakReceiverBox *box = [SyphonWeakReceiverBox new];
			box.target = self;
			CFMessagePortContext context = (CFMessagePortContext){0,(__bridge void *)box,ReceiverBoxRetain,ReceiverBoxRelease,NULL};""", 1)
open(cf, "w").write(ctext)

# upstream's prefix header imported Cocoa for every file; a package has none, so the private header that everything includes does it
private = os.path.join(src, "SyphonPrivate.h")
ptext = open(private).read()
assert "#import <stdatomic.h>" in ptext, "SyphonPrivate.h changed upstream"
open(private, "w").write(ptext.replace("#import <stdatomic.h>", "#import <Cocoa/Cocoa.h> // KAIYOU: upstream got this from Syphon_Prefix.pch\n#import <stdatomic.h>", 1))

# the shader source as one string: the shared types header, then the shaders (without their licence header and #includes)
types = open(os.path.join(up, "SyphonServerMetalTypes.h")).read()
shader = open(os.path.join(up, "SyphonMetalShaders.metal")).read()
shader = re.sub(r"/\*.*?\*/", "", shader, count=1, flags=re.S)
shader = shader.replace('#include "SyphonServerMetalTypes.h"', "")
body = "#include <metal_stdlib>\n#include <simd/simd.h>\n" + re.sub(r"/\*.*?\*/", "", types, count=1, flags=re.S) + shader
lit = "\n".join('    @"%s\\n"' % l.replace("\\", "\\\\").replace('"', '\\"') for l in body.split("\n"))
open(os.path.join(src, "SyphonMetalShaderSource.h"), "w").write("#import <Foundation/Foundation.h>\n// KAIYOU: the Metal shaders as source, from upstream's SyphonMetalShaders.metal.\nNSString * _Nonnull SyphonMetalShaderSource(void);\n")
open(os.path.join(src, "SyphonMetalShaderSource.m"), "w").write('#import "SyphonMetalShaderSource.h"\n\nNSString * SyphonMetalShaderSource(void)\n{\n    return\n' + lit + ";\n}\n")

open(os.path.join(src, "include", "module.modulemap"), "w").write("""module Syphon {
    header "Syphon/SyphonServerBase.h"
    header "Syphon/SyphonMetalServer.h"
    header "Syphon/SyphonClientBase.h"
    header "Syphon/SyphonMetalClient.h"
    header "Syphon/SyphonServerDirectory.h"
    export *
}
""")
# The OpenGL half is a second target, SyphonGL, that builds on the Metal target's base classes and messaging; an app that only uses Metal never links OpenGL.
glsrc = os.path.join(out, "Sources", "SyphonGL")
glinc = os.path.join(glsrc, "include", "Syphon")
os.makedirs(glinc, exist_ok=True)
GL_PUBLIC = ["SyphonOpenGLServer.h", "SyphonOpenGLClient.h", "SyphonOpenGLImage.h", "SyphonImageBase.h", "SyphonServer.h", "SyphonClient.h", "SyphonImage.h"]
GL_PRIVATE_H = ["SyphonCGL.h", "SyphonOpenGLFunctions.h", "SyphonGLShader.h", "SyphonGLVertices.h", "SyphonServerGLShader.h", "SyphonServerGLVertices.h",
                "SyphonServerRendererGL.h", "SyphonServerRendererCoreGL.h", "SyphonServerRendererLegacyGL.h", "SyphonIOSurfaceImageCore.h", "SyphonIOSurfaceImageLegacy.h"]
GL_IMPL = ["SyphonOpenGLServer.m", "SyphonOpenGLClient.m", "SyphonOpenGLImage.m", "SyphonImageBase.m", "SyphonServer.m", "SyphonClient.m", "SyphonImage.m",
           "SyphonCGL.c", "SyphonOpenGLFunctions.c", "SyphonGLShader.m", "SyphonGLVertices.m", "SyphonServerGLShader.m", "SyphonServerGLVertices.m",
           "SyphonServerRendererGL.m", "SyphonServerRendererCoreGL.m", "SyphonServerRendererLegacyGL.m", "SyphonIOSurfaceImageCore.m", "SyphonIOSurfaceImageLegacy.m"]
for f in GL_PUBLIC: shutil.copy(os.path.join(up, f), os.path.join(glinc, f))
for f in GL_PRIVATE_H + GL_IMPL: shutil.copy(os.path.join(up, f), os.path.join(glsrc, f))
open(os.path.join(glsrc, "include", "module.modulemap"), "w").write("""module SyphonGL {
    header "Syphon/SyphonOpenGLServer.h"
    header "Syphon/SyphonOpenGLClient.h"
    header "Syphon/SyphonOpenGLImage.h"
    export *
}
""")

open(os.path.join(out, "Package.swift"), "w").write("""// swift-tools-version: 5.9
import PackageDescription

// Syphon (https://github.com/Syphon/Syphon-Framework, BSD 2-Clause, LICENSE.Syphon), built by SwiftPM alone.
//   Syphon   the Metal server and client, with the base classes, messaging and server directory they share.
//   SyphonGL the OpenGL server, client and image (and the older SyphonServer, SyphonClient and SyphonImage names for them), on top of Syphon.
let package = Package(
    name: "Syphon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Syphon", targets: ["Syphon"]),
        .library(name: "SyphonGL", targets: ["SyphonGL"]),
    ],
    targets: [
        .target(
            name: "Syphon",
            exclude: [],
            cSettings: [.headerSearchPath("."), .headerSearchPath("include/Syphon"), .define("SYPHONLOG(...)", to: "")],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOSurface"), .linkedFramework("Metal")]
        ),
        .target(
            name: "SyphonGL",
            dependencies: ["Syphon"],
            cSettings: [.headerSearchPath("."), .headerSearchPath("include/Syphon"), .headerSearchPath("../Syphon"), .headerSearchPath("../Syphon/include/Syphon"), .define("SYPHONLOG(...)", to: "")],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOSurface"), .linkedFramework("OpenGL")]
        ),
        .testTarget(name: "SyphonTests", dependencies: ["Syphon"]),
        .testTarget(name: "SyphonGLTests", dependencies: ["Syphon", "SyphonGL"]),
    ]
)
""")
os.makedirs(os.path.join(out, "Tests", "SyphonTests"), exist_ok=True)
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "RoundTripTests.swift"), os.path.join(out, "Tests", "SyphonTests", "RoundTripTests.swift"))
os.makedirs(os.path.join(out, "Tests", "SyphonGLTests"), exist_ok=True)
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "GLInteropTests.swift"), os.path.join(out, "Tests", "SyphonGLTests", "GLInteropTests.swift"))
print("assembled", len(PUBLIC), "public,", len(PRIVATE_H), "private headers,", len(IMPL), "implementation files")
