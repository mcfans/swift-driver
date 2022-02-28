import Foundation
import TSCBasic
import XCTest
@_spi(Testing) import SwiftDriver
import TestUtilities

final class RedirectingFileSystemTests: XCTestCase {
  let mockContent = "A SwiftModule"

  func testReadFile() throws {
    let underlyingFS = InMemoryFileSystem()
    let overlayFilePath = AbsolutePath("/a/overlay.yaml")
    let moduleFilePath = AbsolutePath("/a/b.swiftmodule")
    let overlayContent = VFSOverlayInputs.overlayContent(rootDir: "/a/", pathMap: [("a.swiftmodule", "b.swiftmodule")])
    try underlyingFS.writeFileContents(overlayFilePath) {
      $0 <<< overlayContent
    }
    try underlyingFS.writeFileContents(moduleFilePath) {
      $0 <<< mockContent
    }
    let redirectFS = try RedirectingFileSystem.init(yamlFilePath: .absolute(overlayFilePath), fs: underlyingFS)
    let overlayFS = OverlayFileSystem.init(fsList: [redirectFS, underlyingFS])
    XCTAssertEqual(try overlayFS.readFileContents(AbsolutePath("/a/a.swiftmodule")), ByteString.init(encodingAsUTF8: mockContent))
    XCTAssertEqual(try overlayFS.readFileContents(overlayFilePath), ByteString(encodingAsUTF8: overlayContent))
  }

  func testReadFileRelativePath() throws {
    let underlyingFS = InMemoryFileSystem()
    let overlayFilePath = AbsolutePath("/a/b/c/overlay.yaml")
    let moduleFilePath = AbsolutePath("/a/b.swiftmodule")
    let overlayContent = VFSOverlayInputs.overlayContent(rootDir: "/a/", pathMap: [("a.swiftmodule", "../../b.swiftmodule")])
    try underlyingFS.writeFileContents(overlayFilePath) {
      $0 <<< overlayContent
    }
    try underlyingFS.writeFileContents(moduleFilePath) {
      $0 <<< mockContent
    }
    let redirectFS = try RedirectingFileSystem.init(yamlFilePath: .absolute(overlayFilePath), fs: underlyingFS)
    let overlayFS = OverlayFileSystem.init(fsList: [redirectFS, underlyingFS])
    XCTAssertEqual(try overlayFS.readFileContents(AbsolutePath("/a/a.swiftmodule")), ByteString.init(encodingAsUTF8: mockContent))
    XCTAssertEqual(try overlayFS.readFileContents(overlayFilePath), ByteString(encodingAsUTF8: overlayContent))
  }
}
