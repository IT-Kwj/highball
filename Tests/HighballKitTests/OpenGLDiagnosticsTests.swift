import XCTest
@testable import HighballKit

final class OpenGLDiagnosticsTests: XCTestCase {
    private let textureError = #"OpenGL error 0x0501 in ..\renderer\CCTexture2D.cpp cocos2d::Texture2D::initWithMipmaps 669"#

    func testReportKeepsOpenGLIdentityAndErrorsBeforeTheTail() {
        let identities = ["gl.version: 4.6.0 Compatibility Profile", "gl.vendor: Mesa", "gl.renderer: zink Vulkan Apple M3"]
        let text = (identities + [textureError, textureError] + (0..<100).map { "chatter \($0)" }).joined(separator: "\n")
        let digest = BugReport.digest(text)
        for identity in identities { XCTAssertTrue(digest.contains(identity)) }
        XCTAssertTrue(digest.contains(textureError + "  (x2)"))
        XCTAssertEqual(digest.components(separatedBy: "initWithMipmaps").count - 1, 1)
    }

    func testHeaderKeepsOnlyNamedOpenGLSwitches() {
        let env = ["GALLIUM_DRIVER": "zink", "LIBGL_ALWAYS_SOFTWARE": "0", "MESA_LOADER_DRIVER_OVERRIDE": "zink",
                   "MESA_SHADER_CACHE_DIR": "/private/path", "GALLIUM_TOKEN": "secret", "SECRET": "secret"]
        XCTAssertEqual(WineRunner.headerSwitchLines(env),
                       "# GALLIUM_DRIVER=zink\n# LIBGL_ALWAYS_SOFTWARE=0\n# MESA_LOADER_DRIVER_OVERRIDE=zink\n")
    }
}
