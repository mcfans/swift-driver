//===--------------- SwiftDriverTests.swift - Swift Driver Tests -======---===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
@_spi(Testing) import SwiftDriver
import SwiftDriverExecution
import SwiftOptions
import TSCBasic
import XCTest
import TestUtilities

private func executableName(_ name: String) -> String {
#if os(Windows)
  if name.count > 4, name.suffix(from: name.index(name.endIndex, offsetBy: -4)) == ".exe" {
    return name
  }
  return "\(name).exe"
#else
  return name
#endif
}

private func rebase(_ arc: String, at base: AbsolutePath) -> String {
  base.appending(component: arc).nativePathString(escaped: false)
}

private func rebase(_ arcs: String..., at base: AbsolutePath) -> String {
  base.appending(components: arcs).nativePathString(escaped: false)
}

private var testInputsPath: AbsolutePath = {
  var root: AbsolutePath = AbsolutePath(#file)
  while root.basename != "Tests" {
    root = root.parentDirectory
  }
  return root.parentDirectory.appending(component: "TestInputs")
}()

final class SwiftDriverTests: XCTestCase {
  private var ld: AbsolutePath!

  override func setUp() {
    do {
      self.ld = try withTemporaryDirectory(removeTreeOnDeinit: false) {
        let ld = $0.appending(component: executableName("ld64.lld"))

        try localFileSystem.writeFileContents(ld) { $0 <<< "" }
        try localFileSystem.chmod(.executable, path: AbsolutePath(ld.nativePathString(escaped: false)))

        return ld
      }
    } catch {
      fatalError("unable to create stub 'ld' tool")
    }
  }

  deinit {
    try? localFileSystem.removeFileTree(AbsolutePath(validating: self.ld.dirname))
  }

  private var envWithFakeSwiftHelp: [String: String] {
    // During build-script builds, build products are not installed into the toolchain
    // until a project's tests pass. However, we're in the middle of those tests,
    // so there is no swift-help in the toolchain yet. Set the environment variable
    // as if we had found it for the purposes of testing build planning.
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_SWIFT_HELP_EXEC"] = "/tmp/.test-swift-help"
    return env
  }

  /// Determine if the test's execution environment has LLDB
  /// Used to skip tests that rely on LLDB in such environments.
  private func testEnvHasLLDB() throws -> Bool {
    let executor = try SwiftDriverExecutor(diagnosticsEngine: DiagnosticsEngine(),
                                           processSet: ProcessSet(),
                                           fileSystem: localFileSystem,
                                           env: ProcessEnv.vars)
    let toolchain: Toolchain
    #if os(macOS)
    toolchain = DarwinToolchain(env: ProcessEnv.vars, executor: executor)
    #elseif os(Windows)
    toolchain = WindowsToolchain(env: ProcessEnv.vars, executor: executor)
    #else
    toolchain = GenericUnixToolchain(env: ProcessEnv.vars, executor: executor)
    #endif
    do {
      _ = try toolchain.getToolPath(.lldb)
    } catch ToolchainError.unableToFind {
      return false
    }
    return true
  }

  func testInvocationRunModes() throws {

    let driver1 = try Driver.invocationRunMode(forArgs: ["swift"])
    XCTAssertEqual(driver1.mode, .normal(isRepl: false))
    XCTAssertEqual(driver1.args, ["swift"])

    let driver2 = try Driver.invocationRunMode(forArgs: ["swift", "-buzz"])
    XCTAssertEqual(driver2.mode, .normal(isRepl: false))
    XCTAssertEqual(driver2.args, ["swift", "-buzz"])

    let driver3 = try Driver.invocationRunMode(forArgs: ["swift", "/"])
    XCTAssertEqual(driver3.mode, .normal(isRepl: false))
    XCTAssertEqual(driver3.args, ["swift", "/"])

    let driver4 = try Driver.invocationRunMode(forArgs: ["swift", "./foo"])
    XCTAssertEqual(driver4.mode, .normal(isRepl: false))
    XCTAssertEqual(driver4.args, ["swift", "./foo"])

    let driver5 = try Driver.invocationRunMode(forArgs: ["swift", "repl"])
    XCTAssertEqual(driver5.mode, .normal(isRepl: true))
    XCTAssertEqual(driver5.args, ["swift", "-repl"])

    let driver6 = try Driver.invocationRunMode(forArgs: ["swift", "foo", "bar"])
    XCTAssertEqual(driver6.mode, .subcommand(executableName("swift-foo")))
    XCTAssertEqual(driver6.args, [executableName("swift-foo"), "bar"])

    let driver7 = try Driver.invocationRunMode(forArgs: ["swift", "-frontend", "foo", "bar"])
    XCTAssertEqual(driver7.mode, .subcommand(executableName("swift-frontend")))
    XCTAssertEqual(driver7.args, [executableName("swift-frontend"), "foo", "bar"])

    let driver8 = try Driver.invocationRunMode(forArgs: ["swift", "-modulewrap", "foo", "bar"])
    XCTAssertEqual(driver8.mode, .subcommand(executableName("swift-frontend")))
    XCTAssertEqual(driver8.args, [executableName("swift-frontend"), "-modulewrap", "foo", "bar"])
  }

  func testSubcommandsHandling() throws {

    XCTAssertNoThrow(try Driver(args: ["swift"]))
    XCTAssertNoThrow(try Driver(args: ["swift", "-I=foo"]))
    XCTAssertNoThrow(try Driver(args: ["swift", ".foo"]))
    XCTAssertNoThrow(try Driver(args: ["swift", "/foo"]))

    XCTAssertThrowsError(try Driver(args: ["swift", "foo"]))
  }

  func testDriverKindParsing() throws {
    func assertArgs(
      _ args: String...,
      parseTo driverKind: DriverKind,
      leaving remainingArgs: [String],
      file: StaticString = #file, line: UInt = #line
    ) throws {
      var args = args
      let result = try Driver.determineDriverKind(args: &args)

      XCTAssertEqual(result, driverKind, file: file, line: line)
      XCTAssertEqual(args, remainingArgs, file: file, line: line)
    }
    func assertArgsThrow(
      _ args: String...,
      file: StaticString = #file, line: UInt = #line
    ) throws {
      var args = args
      XCTAssertThrowsError(try Driver.determineDriverKind(args: &args))
    }

    try assertArgs("swift", parseTo: .interactive, leaving: [])
    try assertArgs("/path/to/swift", parseTo: .interactive, leaving: [])
    try assertArgs("swiftc", parseTo: .batch, leaving: [])
    try assertArgs(".build/debug/swiftc", parseTo: .batch, leaving: [])
    try assertArgs("swiftc", "--driver-mode=swift", parseTo: .interactive, leaving: [])
    try assertArgs("swift", "-zelda", parseTo: .interactive, leaving: ["-zelda"])
    try assertArgs("swiftc", "--driver-mode=swift", "swiftc",
                   parseTo: .interactive, leaving: ["swiftc"])
    try assertArgsThrow("driver")
    try assertArgsThrow("swiftc", "--driver-mode=blah")
    try assertArgsThrow("swiftc", "--driver-mode=")
  }

  func testCompilerMode() throws {
    do {
      let driver1 = try Driver(args: ["swift", "main.swift"])
      XCTAssertEqual(driver1.compilerMode, .immediate)

      let driver2 = try Driver(args: ["swift"])
      XCTAssertEqual(driver2.compilerMode, .intro)
    }

    do {
      let driver1 = try Driver(args: ["swiftc", "main.swift", "-whole-module-optimization"])
      XCTAssertEqual(driver1.compilerMode, .singleCompile)

      let driver2 = try Driver(args: ["swiftc", "main.swift", "-whole-module-optimization", "-no-whole-module-optimization"])
      XCTAssertEqual(driver2.compilerMode, .standardCompile)

      let driver3 = try Driver(args: ["swiftc", "main.swift", "-g"])
      XCTAssertEqual(driver3.compilerMode, .standardCompile)
    }
  }

  func testJoinedPathOptions() throws {
    var driver = try Driver(args: ["swiftc", "-c", "-I=/some/dir", "-F=other/relative/dir", "foo.swift"])
    let jobs = try driver.planBuild()
    XCTAssertTrue(jobs[0].commandLine.contains(.joinedOptionAndPath("-I=", .absolute(.init("/some/dir")))))
    XCTAssertTrue(jobs[0].commandLine.contains(.joinedOptionAndPath("-F=", .relative(.init("other/relative/dir")))))
  }

  func testRelativeOptionOrdering() throws {
    var driver = try Driver(args: ["swiftc", "foo.swift",
                                   "-F", "/path/to/frameworks",
                                   "-Fsystem", "/path/to/systemframeworks",
                                   "-F", "/path/to/more/frameworks"])
    let jobs = try driver.planBuild()
    XCTAssertEqual(jobs[0].kind, .compile)
    // The relative ordering of -F and -Fsystem options should be preserved.
    XCTAssertTrue(jobs[0].commandLine.contains(subsequence: [.flag("-F"), .path(.absolute(.init("/path/to/frameworks"))),
                                                             .flag("-Fsystem"), .path(.absolute(.init("/path/to/systemframeworks"))),
                                                             .flag("-F"), .path(.absolute(.init("/path/to/more/frameworks")))]))
  }

  func testBatchModeDiagnostics() throws {
      try assertNoDriverDiagnostics(args: "swiftc", "-enable-batch-mode") { driver in
        switch driver.compilerMode {
        case .batchCompile:
          break
        default:
          XCTFail("Expected batch compile, got \(driver.compilerMode)")
        }
      }

      try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization") { driver, diagnostics in
        XCTAssertEqual(driver.compilerMode, .singleCompile)
        diagnostics.expect(.warning("ignoring '-enable-batch-mode' because '-whole-module-optimization' was also specified"))
      }

      try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization", "-no-whole-module-optimization", "-index-file", "-module-name", "foo") { driver, diagnostics in
        XCTAssertEqual(driver.compilerMode, .singleCompile)
        diagnostics.expect(.warning("ignoring '-enable-batch-mode' because '-index-file' was also specified"))
      }

      try assertNoDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization", "-no-whole-module-optimization") { driver in
        switch driver.compilerMode {
        case .batchCompile:
          break
        default:
          XCTFail("Expected batch compile, got \(driver.compilerMode)")
        }
      }
  }

  func testHelp() throws {
    do {
      var driver = try Driver(args: ["swift", "--help"], env: envWithFakeSwiftHelp)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let helpJob = plannedJobs.first!
      XCTAssertTrue(helpJob.kind == .help)
      XCTAssertTrue(helpJob.requiresInPlaceExecution)
      XCTAssertTrue(helpJob.tool.name.hasSuffix("swift-help"))
      let expected: [Job.ArgTemplate] = [.flag("swift")]
      XCTAssertEqual(helpJob.commandLine, expected)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-help-hidden"], env: envWithFakeSwiftHelp)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let helpJob = plannedJobs.first!
      XCTAssertTrue(helpJob.kind == .help)
      XCTAssertTrue(helpJob.requiresInPlaceExecution)
      XCTAssertTrue(helpJob.tool.name.hasSuffix("swift-help"))
      let expected: [Job.ArgTemplate] = [.flag("swiftc"), .flag("-show-hidden")]
      XCTAssertEqual(helpJob.commandLine, expected)
    }
  }

  func testRuntimeCompatibilityVersion() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "a.swift", "-runtime-compatibility-version", "none")
  }

  func testInputFiles() throws {
    let driver1 = try Driver(args: ["swiftc", "a.swift", "/tmp/b.swift"])
    XCTAssertEqual(driver1.inputFiles,
                   [ TypedVirtualPath(file: VirtualPath.relative(RelativePath("a.swift")).intern(), type: .swift),
                     TypedVirtualPath(file: VirtualPath.absolute(AbsolutePath("/tmp/b.swift")).intern(), type: .swift) ])

    let workingDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/wobble", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")
    let tempDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/tmp", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")

    let driver2 = try Driver(args: ["swiftc", "a.swift", "-working-directory", workingDirectory.pathString, rebase("b.swift", at: tempDirectory)])
    XCTAssertEqual(driver2.inputFiles,
                   [ TypedVirtualPath(file: VirtualPath.absolute(AbsolutePath(rebase("a.swift", at: workingDirectory))).intern(), type: .swift),
                     TypedVirtualPath(file: VirtualPath.absolute(AbsolutePath(rebase("b.swift", at: tempDirectory))).intern(), type: .swift) ])

    let driver3 = try Driver(args: ["swift", "-"])
    XCTAssertEqual(driver3.inputFiles, [ TypedVirtualPath(file: .standardInput, type: .swift )])

    let driver4 = try Driver(args: ["swift", "-", "-working-directory" , "-wobble"])
    XCTAssertEqual(driver4.inputFiles, [ TypedVirtualPath(file: .standardInput, type: .swift )])
  }

  func testRecordedInputModificationDates() throws {
#if os(Windows)
    throw XCTSkip("TSCUtility.RelativePath failure")
#else
    try withTemporaryDirectory { path in
      guard let cwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      let main = path.appending(component: "main.swift")
      let util = path.appending(component: "util.swift")
      let utilRelative = util.relative(to: cwd)
      try localFileSystem.writeFileContents(main) { $0 <<< "print(hi)" }
      try localFileSystem.writeFileContents(util) { $0 <<< "let hi = \"hi\"" }

      let mainMDate = try localFileSystem.getFileInfo(main).modTime
      let utilMDate = try localFileSystem.getFileInfo(util).modTime
      let driver = try Driver(args: [
        "swiftc", main.pathString, utilRelative.pathString,
      ])
      XCTAssertEqual(driver.recordedInputModificationDates, [
        .init(file: VirtualPath.absolute(main).intern(), type: .swift) : mainMDate,
        .init(file: VirtualPath.relative(utilRelative).intern(), type: .swift) : utilMDate,
      ])
    }
#endif
  }

  func testPrimaryOutputKinds() throws {
    let driver1 = try Driver(args: ["swiftc", "foo.swift", "-emit-module"])
    XCTAssertEqual(driver1.compilerOutputType, .swiftModule)
    XCTAssertEqual(driver1.linkerOutputType, nil)

    let driver2 = try Driver(args: ["swiftc", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver2.compilerOutputType, .object)
    XCTAssertEqual(driver2.linkerOutputType, .dynamicLibrary)

    let driver3 = try Driver(args: ["swiftc", "-static", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver3.compilerOutputType, .object)
    XCTAssertEqual(driver3.linkerOutputType, .staticLibrary)

    let driver4 = try Driver(args: ["swiftc", "-lto=llvm-thin", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver4.compilerOutputType, .llvmBitcode)
    let driver5 = try Driver(args: ["swiftc", "-lto=llvm-full", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver5.compilerOutputType, .llvmBitcode)
  }

  func testLtoOutputModeClash() throws {
    let driver1 = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full", "-static",
                                    "-emit-library", "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver1.compilerOutputType, .llvmBitcode)

    let driver2 = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full",
                                    "-emit-library", "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver2.compilerOutputType, .llvmBitcode)

    let driver3 = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full",
                                    "c", "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver3.compilerOutputType, .llvmBitcode)

    let driver4 = try Driver(args: ["swiftc", "foo.swift", "-c","-lto=llvm-full",
                                    "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver4.compilerOutputType, .llvmBitcode)

    let driver5 = try Driver(args: ["swiftc", "foo.swift", "-c","-lto=llvm-full",
                                    "-emit-bc", "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver5.compilerOutputType, .llvmBitcode)

    let driver6 = try Driver(args: ["swiftc", "foo.swift", "-emit-bc", "-c","-lto=llvm-full",
                                    "-target", "x86_64-apple-macosx10.9"])
    XCTAssertEqual(driver6.compilerOutputType, .llvmBitcode)
  }

  func testLtoOutputPath() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full", "-c", "-target", "x86_64-apple-macosx10.9"])
      XCTAssertEqual(driver.compilerOutputType, .llvmBitcode)
      XCTAssertEqual(driver.linkerOutputType, nil)
      let jobs = try driver.planBuild()
      XCTAssertEqual(jobs.count, 1)
      XCTAssertEqual(jobs[0].outputs.count, 1)
      XCTAssertEqual(jobs[0].outputs[0].file.basename, "foo.bc")
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full", "-c", "-target", "x86_64-apple-macosx10.9", "-o", "foo.o"])
      XCTAssertEqual(driver.compilerOutputType, .llvmBitcode)
      XCTAssertEqual(driver.linkerOutputType, nil)
      let jobs = try driver.planBuild()
      XCTAssertEqual(jobs.count, 1)
      XCTAssertEqual(jobs[0].outputs.count, 1)
      XCTAssertEqual(jobs[0].outputs[0].file.basename, "foo.o")
    }
  }

  func testPrimaryOutputKindsDiagnostics() throws {
      try assertDriverDiagnostics(args: "swift", "-i") {
        $1.expect(.error("the flag '-i' is no longer required and has been removed; use 'swift input-filename'"))
      }
  }

  func testMultiThreadingOutputs() throws {
    try assertDriverDiagnostics(args: "swiftc", "-c", "foo.swift", "bar.swift", "-o", "bar.ll", "-o", "foo.ll", "-num-threads", "2", "-whole-module-optimization") {
      $1.expect(.error("cannot specify -o when generating multiple output files"))
    }

    try assertDriverDiagnostics(args: "swiftc", "-c", "foo.swift", "bar.swift", "-o", "bar.ll", "-o", "foo.ll", "-num-threads", "0") {
      $1.expect(.error("cannot specify -o when generating multiple output files"))
    }
  }

  func testBaseOutputPaths() throws {
    // Test the combination of -c and -o includes the base output path.
    do {
      var driver = try Driver(args: ["swiftc", "-c", "foo.swift", "-o", "/some/output/path/bar.o"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/some/output/path/bar.o"))))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-sil", "foo.swift", "-o", "/some/output/path/bar.sil"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/some/output/path/bar.sil"))))
    }

    do {
      // If no output is specified, verify we print to stdout for textual formats.
      var driver = try Driver(args: ["swiftc", "-emit-assembly", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(.standardOutput)))
    }
  }

    func testMultithreading() throws {
      XCTAssertNil(try Driver(args: ["swiftc"]).numParallelJobs)

      XCTAssertEqual(try Driver(args: ["swiftc", "-j", "4"]).numParallelJobs, 4)

      XCTAssertNil(try Driver(args: ["swiftc", "-j", "0"]).numParallelJobs)

      var env = ProcessEnv.vars
      env["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
      XCTAssertEqual(try Driver(args: ["swiftc", "-j", "4"], env: env).numParallelJobs, 1)
    }

    func testMultithreadingDiagnostics() throws {
      try assertDriverDiagnostics(args: "swiftc", "-j", "0") {
        $1.expect(.error("invalid value '0' in '-j'"))
      }

      var env = ProcessEnv.vars
      env["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
      try assertDriverDiagnostics(args: "swiftc", "-j", "8", env: env) {
        $1.expect(.remark("SWIFTC_MAXIMUM_DETERMINISM overriding -j"))
      }
    }

  func testDebugSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module") { driver in
      XCTAssertNil(driver.debugInfo.level)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g") { driver in
      XCTAssertEqual(driver.debugInfo.level, .astTypes)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "-g", "foo.swift", "-gline-tables-only") { driver in
      XCTAssertEqual(driver.debugInfo.level, .lineTables)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-debug-prefix-map", "foo=bar=baz", "-debug-prefix-map", "qux=") { driver in
        let jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("-debug-prefix-map")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("foo=bar=baz")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("-debug-prefix-map")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("qux=")))
    }

    do {
      var env = ProcessEnv.vars
      env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
      env["RC_DEBUG_PREFIX_MAP"] = "old=new"
      var driver = try Driver(args: ["swiftc", "-c", "-target", "arm64-apple-macos12", "foo.swift"], env: env)
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-debug-prefix-map")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("old=new")))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-debug-prefix-map", "foo", "-debug-prefix-map", "bar") {
        $1.expect(.error("values for '-debug-prefix-map' must be in the format 'original=remapped', but 'foo' was provided"))
        $1.expect(.error("values for '-debug-prefix-map' must be in the format 'original=remapped', but 'bar' was provided"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g", "-debug-info-format=codeview") { driver in
      XCTAssertEqual(driver.debugInfo.level, .astTypes)
      XCTAssertEqual(driver.debugInfo.format, .codeView)
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-debug-info-format=dwarf") {
      $1.expect(.error("option '-debug-info-format=' is missing a required argument (-g)"))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g", "-debug-info-format=notdwarf") {
      $1.expect(.error("invalid value 'notdwarf' in '-debug-info-format='"))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-gdwarf-types", "-debug-info-format=codeview") {
      $1.expect(.error("argument '-debug-info-format=codeview' is not allowed with '-gdwarf-types'"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-g", "-c", "-file-compilation-dir", ".") { driver in
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-file-compilation-dir")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag(".")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-c", "-file-compilation-dir", ".") { driver in
      let jobs = try driver.planBuild()
      XCTAssertFalse(jobs[0].commandLine.contains(.flag("-file-compilation-dir")))
    }
  }

  func testCoverageSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-coverage-prefix-map", "foo=bar=baz", "-coverage-prefix-map", "qux=") { driver in
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-coverage-prefix-map")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("foo=bar=baz")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-coverage-prefix-map")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("qux=")))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-coverage-prefix-map", "foo", "-coverage-prefix-map", "bar") {
      $1.expect(.error("values for '-coverage-prefix-map' must be in the format 'original=remapped', but 'foo' was provided"))
      $1.expect(.error("values for '-coverage-prefix-map' must be in the format 'original=remapped', but 'bar' was provided"))
    }
  }

  func testHermeticSealAtLink() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-experimental-hermetic-seal-at-link", "-lto=llvm-full") { driver in
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-enable-llvm-vfe")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-enable-llvm-wme")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-conditional-runtime-records")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-internalize-at-link")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-lto=llvm-full")))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-experimental-hermetic-seal-at-link") {
      $1.expect(.error("-experimental-hermetic-seal-at-link requires -lto=llvm-full or -lto=llvm-thin"))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-experimental-hermetic-seal-at-link", "-lto=llvm-full", "-enable-library-evolution") {
      $1.expect(.error("Cannot use -experimental-hermetic-seal-at-link with -enable-library-evolution"))
    }
  }

  func testModuleSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift") { driver in
      XCTAssertNil(driver.moduleOutputInfo.output)
      XCTAssertEqual(driver.moduleOutputInfo.name, "foo")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-g") { driver in
      let pathHandle = driver.moduleOutputInfo.output?.outputPath
      XCTAssertTrue(matchTemporary(VirtualPath.lookup(pathHandle!), "foo.swiftmodule"))
      XCTAssertEqual(driver.moduleOutputInfo.name, "foo")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-module-name", "wibble", "bar.swift", "-g") { driver in
      let pathHandle = driver.moduleOutputInfo.output?.outputPath
      XCTAssertTrue(matchTemporary(VirtualPath.lookup(pathHandle!), "wibble.swiftmodule"))
      XCTAssertEqual(driver.moduleOutputInfo.name, "wibble")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "-emit-module", "foo.swift", "-module-name", "wibble", "bar.swift") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath.intern(path: "wibble.swiftmodule")))
      XCTAssertEqual(driver.moduleOutputInfo.name, "wibble")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift") { driver in
      XCTAssertNil(driver.moduleOutputInfo.output)
      XCTAssertEqual(driver.moduleOutputInfo.name, "main")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-library", "-o", "libWibble.so") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.name, "Wibble")
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-library", "-o", "libWibble.so", "-module-name", "Swift") {
        $1.expect(.error("module name \"Swift\" is reserved for the standard library"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "some/dir/libFoo.so", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath.intern(path: "some/dir/MyModule.swiftmodule")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "/", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath.intern(path: "/MyModule.swiftmodule")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "../../some/other/dir/libFoo.so", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath.intern(path: "../../some/other/dir/MyModule.swiftmodule")))
    }
  }

  func testModuleNameFallbacks() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "file.foo.swift")
    try assertNoDriverDiagnostics(args: "swiftc", ".foo.swift")
    try assertNoDriverDiagnostics(args: "swiftc", "foo-bar.swift")
  }

  func testStandardCompileJobs() throws {
    var driver1 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test"])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssertEqual(plannedJobs[0].outputs.count, 1)
    XCTAssertTrue(matchTemporary(plannedJobs[0].outputs.first!.file, "foo.o"))
    XCTAssertEqual(plannedJobs[1].outputs.count, 1)
    XCTAssertTrue(matchTemporary(plannedJobs[1].outputs.first!.file, "bar.o"))
    XCTAssertTrue(plannedJobs[2].tool.name.contains(driver1.targetTriple.isDarwin ? executableName("ld") : executableName("clang")))
    XCTAssertEqual(plannedJobs[2].outputs.count, 1)
    XCTAssertEqual(plannedJobs[2].outputs.first!.file, VirtualPath.relative(RelativePath(executableName("Test"))))

    // Forwarding of arguments.
    let workingDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/tmp", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")

    var driver2 = try Driver(args: ["swiftc", "-color-diagnostics", "foo.swift", "bar.swift", "-working-directory", workingDirectory.pathString, "-api-diff-data-file", "diff.txt", "-Xfrontend", "-HI", "-no-color-diagnostics", "-g"])
    let plannedJobs2 = try driver2.planBuild()
    let compileJob = plannedJobs2.first(where: {$0.kind == .compile})!
    XCTAssert(compileJob.commandLine.contains(Job.ArgTemplate.path(.absolute(try AbsolutePath(validating: rebase("diff.txt", at: workingDirectory))))))
    XCTAssert(compileJob.commandLine.contains(.flag("-HI")))
    XCTAssert(!compileJob.commandLine.contains(.flag("-Xfrontend")))
    XCTAssert(compileJob.commandLine.contains(.flag("-no-color-diagnostics")))
    XCTAssert(!compileJob.commandLine.contains(.flag("-color-diagnostics")))
    XCTAssert(compileJob.commandLine.contains(.flag("-target")))
    XCTAssert(compileJob.commandLine.contains(.flag(driver2.targetTriple.triple)))
    XCTAssert(compileJob.commandLine.contains(.flag("-enable-anonymous-context-mangled-names")))

    var driver3 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-emit-library", "-module-name", "Test"])
    let plannedJobs3 = try driver3.planBuild()
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("-module-name")))
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("Test")))
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("-parse-as-library")))
  }

  func testModuleNaming() throws {
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift"]).moduleOutputInfo.name, "foo")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out"]).moduleOutputInfo.name, "a")

    // This is silly, but necessary for compatibility with the integrated driver.
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out.optimized"]).moduleOutputInfo.name, "main")

    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out.optimized", "-module-name", "bar"]).moduleOutputInfo.name, "bar")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "+++.out"]).moduleOutputInfo.name, "main")
    XCTAssertEqual(try Driver(args: ["swift"]).moduleOutputInfo.name, "REPL")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-emit-library", "-o", "libBaz.dylib"]).moduleOutputInfo.name, "Baz")
  }

  func testOutputFileMapLoading() throws {
    let contents = """
    {
      "": {
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"
      },
      "/tmp/foo/Sources/foo/foo.swift": {
        "dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        "object": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        "swiftmodule": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        let outputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: diags)

        let object = try outputFileMap.getOutput(inputFile: VirtualPath.intern(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .object)
        XCTAssertEqual(VirtualPath.lookup(object).name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o")

        let masterDeps = try outputFileMap.getOutput(inputFile: VirtualPath.intern(path: ""), outputType: .swiftDeps)
        XCTAssertEqual(VirtualPath.lookup(masterDeps).name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps")
      }
    }
  }

  func testFindingObjectPathFromllvmBCPath() throws {
    let contents = """
    {
      "": {
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"
      },
      "/tmp/foo/Sources/foo/foo.swift": {
        "dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        "object": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        "swiftmodule": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps",
        "llvm-bc": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.bc"
      }
    }
    """
    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        let outputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: diags)

        let obj = try outputFileMap.getOutput(inputFile: VirtualPath.intern(path: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.bc"), outputType: .object)
        XCTAssertEqual(VirtualPath.lookup(obj).name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o")
      }
    }
  }

  func testOutputFileMapLoadingDocAndSourceinfo() throws {
    let contents = """
    {
      "": {
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"
      },
      "/tmp/foo/Sources/foo/foo.swift": {
        "dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        "object": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        "swiftmodule": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        let outputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: diags)

        let doc = try outputFileMap.getOutput(inputFile: VirtualPath.intern(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .swiftDocumentation)
        XCTAssertEqual(VirtualPath.lookup(doc).name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftdoc")

        let source = try outputFileMap.getOutput(inputFile: VirtualPath.intern(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .swiftSourceInfoFile)
        XCTAssertEqual(VirtualPath.lookup(source).name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftsourceinfo")
      }
    }
  }

  func testIndexUnitOutputPath() throws {
    let contents = """
    {
      "/tmp/main.swift": {
        "object": "/tmp/build1/main.o",
        "index-unit-output-path": "/tmp/build2/main.o",
      },
      "/tmp/second.swift": {
        "object": "/tmp/build1/second.o",
        "index-unit-output-path": "/tmp/build2/second.o",
      }
    }
    """

    func getFileListElements(for filelistOpt: String, job: Job) -> [VirtualPath] {
      let optIndex = job.commandLine.firstIndex(of: .flag(filelistOpt))!
      let value = job.commandLine[job.commandLine.index(after: optIndex)]
      guard case let .path(.fileList(_, valueFileList)) = value else {
        XCTFail("Argument wasn't a filelist")
        return []
      }
      guard case let .list(inputs) = valueFileList else {
        XCTFail("FileList wasn't List")
        return []
      }
      return inputs
    }

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }

        // 1. Incremental mode (single primary file)
        // a) without filelists
        var driver = try Driver(args: [
          "swiftc", "-c",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        var jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/second.o")))]))
        XCTAssertTrue(jobs[1].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/main.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/second.o")))]))
        XCTAssertTrue(jobs[1].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/main.o")))]))

        // b) with filelists
        driver = try Driver(args: [
          "swiftc", "-c", "-driver-filelist-threshold=0",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        jobs = try driver.planBuild()
        XCTAssertEqual(getFileListElements(for: "-output-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build1/second.o"))])
        XCTAssertEqual(getFileListElements(for: "-index-unit-output-path-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build2/second.o"))])
        XCTAssertEqual(getFileListElements(for: "-output-filelist", job: jobs[1]),
                       [.absolute(.init("/tmp/build1/main.o"))])
        XCTAssertEqual(getFileListElements(for: "-index-unit-output-path-filelist", job: jobs[1]),
                       [.absolute(.init("/tmp/build2/main.o"))])


        // 2. Batch mode (two primary files)
        // a) without filelists
        driver = try Driver(args: [
          "swiftc", "-c", "-enable-batch-mode", "-driver-batch-count", "1",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/second.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/main.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/second.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/main.o")))]))

        // b) with filelists
        driver = try Driver(args: [
          "swiftc", "-c", "-driver-filelist-threshold=0",
          "-enable-batch-mode", "-driver-batch-count", "1",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        jobs = try driver.planBuild()
        XCTAssertEqual(getFileListElements(for: "-output-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build1/second.o")), .absolute(.init("/tmp/build1/main.o"))])
        XCTAssertEqual(getFileListElements(for: "-index-unit-output-path-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build2/second.o")), .absolute(.init("/tmp/build2/main.o"))])

        // 3. Multi-threaded WMO
        // a) without filelists
        driver = try Driver(args: [
          "swiftc", "-c", "-whole-module-optimization", "-num-threads", "2",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/second.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/second.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/main.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/main.o")))]))

        // b) with filelists
        driver = try Driver(args: [
          "swiftc", "-c", "-driver-filelist-threshold=0",
          "-whole-module-optimization", "-num-threads", "2",
          "-output-file-map", file.path.pathString,
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift"
        ])
        jobs = try driver.planBuild()
        XCTAssertEqual(getFileListElements(for: "-output-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build1/second.o")), .absolute(.init("/tmp/build1/main.o"))])
        XCTAssertEqual(getFileListElements(for: "-index-unit-output-path-filelist", job: jobs[0]),
                       [.absolute(.init("/tmp/build2/second.o")), .absolute(.init("/tmp/build2/main.o"))])

        // 4. Index-file (single primary)
        driver = try Driver(args: [
          "swiftc", "-c", "-enable-batch-mode", "-driver-batch-count", "1",
          "-module-name", "test", "/tmp/second.swift", "/tmp/main.swift",
          "-index-file", "-index-file-path", "/tmp/second.swift",
          "-disable-batch-mode", "-o", "/tmp/build1/second.o",
          "-index-unit-output-path", "/tmp/build2/second.o"
        ])
        jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-o", .path(.absolute(.init("/tmp/build1/second.o")))]))
        XCTAssertTrue(jobs[0].commandLine.contains(subsequence: ["-index-unit-output-path", .path(.absolute(.init("/tmp/build2/second.o")))]))
      }
    }
  }

  func testMergeModuleEmittingDependencies() throws {
    var driver1 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Foo", "-emit-dependencies", "-emit-module", "-serialize-diagnostics", "-driver-filelist-threshold=9999", "-no-emit-module-separately"])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertTrue(plannedJobs[0].kind == .compile)
    XCTAssertTrue(plannedJobs[1].kind == .compile)
    XCTAssertTrue(plannedJobs[2].kind == .mergeModule)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-serialize-diagnostics-path")))
    XCTAssertFalse(plannedJobs[2].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertFalse(plannedJobs[2].commandLine.contains(.flag("-serialize-diagnostics-path")))
  }

  func testEmitModuleEmittingDependencies() throws {
    var driver1 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Foo", "-emit-dependencies", "-emit-module", "-serialize-diagnostics", "-driver-filelist-threshold=9999", "-experimental-emit-module-separately"])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssertTrue(plannedJobs[0].kind == .emitModule)
    // TODO: This check is disabled as per rdar://85253406
    // XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
  }

  func testEmitModuleSepratelyEmittingDiagnosticsWithOutputFileMap() throws {
    try withTemporaryDirectory { path in
      let outputFileMap = path.appending(component: "outputFileMap.json")
      try localFileSystem.writeFileContents(outputFileMap) {
        $0 <<< """
        {
          "": {
            "diagnostics": "/build/Foo-test.dia"
          }
        }
        """
      }
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Foo", "-emit-module",
                                      "-serialize-diagnostics", "-experimental-emit-module-separately",
                                      "-output-file-map", outputFileMap.description])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[0].kind == .emitModule)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(subsequence: [.flag("-serialize-diagnostics-path"), .path(.absolute(.init("/build/Foo-test.dia")))]))
    }
  }

  func testReferenceDependencies() throws {
    var driver = try Driver(args: ["swiftc", "foo.swift", "-incremental"])
    let plannedJobs = try driver.planBuild()
    XCTAssertTrue(plannedJobs[0].kind == .compile)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-reference-dependencies-path")))
  }

  func testDuplicateName() throws {
    assertDiagnostics { diagnosticsEngine, verify in
      _ = try? Driver(args: ["swiftc", "-c", "foo.swift", "foo.swift"], diagnosticsEngine: diagnosticsEngine)
      verify.expect(.error("filename \"foo.swift\" used twice: 'foo.swift' and 'foo.swift'"))
      verify.expect(.note("filenames are used to distinguish private declarations with the same name"))
    }

    assertDiagnostics { diagnosticsEngine, verify in
      _ = try? Driver(args: ["swiftc", "-c", "foo.swift", "foo/foo.swift"], diagnosticsEngine: diagnosticsEngine)
      verify.expect(.error("filename \"foo.swift\" used twice: 'foo.swift' and 'foo/foo.swift'"))
      verify.expect(.note("filenames are used to distinguish private declarations with the same name"))
    }
  }

  func testOutputFileMapStoring() throws {
    // Create sample OutputFileMap:

    // Rather than writing VirtualPath(path:...) over and over again, make strings, then fix it
    let stringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"],
      "foo.swift" : [
        .dependencies: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        .object: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        .swiftModule: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        .swiftDeps: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
        ]
    ]
    let pathyEntries = try Dictionary(uniqueKeysWithValues:
      stringyEntries.map { try
        (
          VirtualPath.intern(path: $0.key),
          Dictionary(uniqueKeysWithValues: $0.value.map { try ($0.key, VirtualPath.intern(path: $0.value))})
        )})
    let sampleOutputFileMap = OutputFileMap(entries: pathyEntries)

    try withTemporaryFile { file in
      try sampleOutputFileMap.store(fileSystem: localFileSystem, file: file.path, diagnosticEngine: DiagnosticsEngine())
      let contentsForDebugging = try localFileSystem.readFileContents(file.path).cString
      _ = contentsForDebugging
      let recoveredOutputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: DiagnosticsEngine())
      XCTAssertEqual(sampleOutputFileMap, recoveredOutputFileMap)
    }
  }

  func testOutputFileMapResolving() throws {
    // Create sample OutputFileMap:

    let stringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: "foo.build/master.swiftdeps"],
      "foo.swift" : [
        .dependencies: "foo.build/foo.d",
        .object: "foo.build/foo.swift.o",
        .swiftModule: "foo.build/foo~partial.swiftmodule",
        .swiftDeps: "foo.build/foo.swiftdeps"
      ]
    ]

    let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/foo_root", relativeTo: $0) }
                    ?? AbsolutePath(validating: "/foo_root")

    let resolvedStringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: root.appending(components: "foo.build", "master.swiftdeps").pathString],
      root.appending(component: "foo.swift").pathString : [
        .dependencies: root.appending(components: "foo.build", "foo.d").pathString,
        .object: root.appending(components: "foo.build", "foo.swift.o").pathString,
        .swiftModule: root.appending(components: "foo.build", "foo~partial.swiftmodule").pathString,
        .swiftDeps: root.appending(components: "foo.build", "foo.swiftdeps").pathString
      ]
    ]

    func outputFileMapFromStringyEntries(
      _ entries: [String: [FileType: String]]
    ) throws -> OutputFileMap {
      .init(entries: Dictionary(uniqueKeysWithValues: try entries.map { try (
        VirtualPath.intern(path: $0.key),
        $0.value.mapValues(VirtualPath.intern(path:))
      )}))
    }

    let sampleOutputFileMap =
      try outputFileMapFromStringyEntries(stringyEntries)
    let resolvedOutputFileMap = sampleOutputFileMap
      .resolveRelativePaths(relativeTo: root)
    let expectedOutputFileMap =
      try outputFileMapFromStringyEntries(resolvedStringyEntries)
    XCTAssertEqual(expectedOutputFileMap, resolvedOutputFileMap)
  }

  func testOutputFileMapRelativePathArg() throws {
#if os(Windows)
    throw XCTSkip("TSCUtility.RelativePath failure")
#else
    try withTemporaryDirectory { path in
      guard let cwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      let outputFileMap = path.appending(component: "outputFileMap.json")
      try localFileSystem.writeFileContents(outputFileMap) {
        $0 <<< """
        {
          "": {
            "swift-dependencies": "build/master.swiftdeps"
          },
          "main.swift": {
            "object": "build/main.o",
            "dependencies": "build/main.o.d"
          },
          "util.swift": {
            "object": "build/util.o",
            "dependencies": "build/util.o.d"
          }
        }
        """
      }
      let outputFileMapRelative = outputFileMap.relative(to: cwd).pathString
      // FIXME: Needs a better way to check that outputFileMap correctly loaded
      XCTAssertNoThrow(try Driver(args: [
        "swiftc",
        "-output-file-map", outputFileMapRelative,
        "main.swift", "util.swift",
      ]))
    }
#endif
  }

  func testResponseFileExpansion() throws {
    try withTemporaryDirectory { path in
      let diags = DiagnosticsEngine()
      let fooPath = path.appending(component: "foo.rsp")
      let barPath = path.appending(component: "bar.rsp")
      try localFileSystem.writeFileContents(fooPath) {
#if os(Windows)
        $0 <<< "hello\nbye\n\"bye to you\"\n@\(barPath.nativePathString(escaped: true))"
#else
        $0 <<< "hello\nbye\nbye\\ to\\ you\n@\(barPath.nativePathString(escaped: true))"
#endif
      }
      try localFileSystem.writeFileContents(barPath) {
        $0 <<< "from\nbar\n@\(fooPath.nativePathString(escaped: true))"
      }
      let args = try Driver.expandResponseFiles(["swift", "compiler", "-Xlinker", "@loader_path", "@" + fooPath.pathString, "something"], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["swift", "compiler", "-Xlinker", "@loader_path", "hello", "bye", "bye to you", "from", "bar", "something"])
      XCTAssertEqual(diags.diagnostics.count, 1)
      XCTAssert(diags.diagnostics.first?.description.contains("is recursively expanded") ?? false)
    }
  }

  func testResponseFileExpansionRelativePathsInCWD() throws {
    try withTemporaryDirectory { path in
      guard let preserveCwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      try! localFileSystem.changeCurrentWorkingDirectory(to: path)
      defer { try! localFileSystem.changeCurrentWorkingDirectory(to: preserveCwd) }

      let diags = DiagnosticsEngine()
      let fooPath = path.appending(component: "foo.rsp")
      let barPath = path.appending(component: "bar.rsp")
      try localFileSystem.writeFileContents(fooPath) {
#if os(Windows)
        $0 <<< "hello\nbye\n\"bye to you\"\n@bar.rsp"
#else
        $0 <<< "hello\nbye\nbye\\ to\\ you\n@bar.rsp"
#endif
      }
      try localFileSystem.writeFileContents(barPath) {
        $0 <<< "from\nbar\n@foo.rsp"
      }
      let args = try Driver.expandResponseFiles(["swift", "compiler", "-Xlinker", "@loader_path", "@foo.rsp", "something"], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["swift", "compiler", "-Xlinker", "@loader_path", "hello", "bye", "bye to you", "from", "bar", "something"])
      XCTAssertEqual(diags.diagnostics.count, 1)
      XCTAssert(diags.diagnostics.first!.description.contains("is recursively expanded"))
    }
  }

  /// Tests that relative paths in response files are resolved based on the CWD, not the response file's location.
  func testResponseFileExpansionRelativePathsNotInCWD() throws {
    try withTemporaryDirectory { path in
      guard let preserveCwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      try! localFileSystem.changeCurrentWorkingDirectory(to: path)
      defer { try! localFileSystem.changeCurrentWorkingDirectory(to: preserveCwd) }

      try localFileSystem.createDirectory(path.appending(component: "subdir"))

      let diags = DiagnosticsEngine()
      let fooPath = path.appending(components: "subdir", "foo.rsp")
      let barPath = path.appending(components: "subdir", "bar.rsp")
      try localFileSystem.writeFileContents(fooPath) {
#if os(Windows)
        $0 <<< "hello\nbye\n\"bye to you\"\n@subdir/bar.rsp"
#else
        $0 <<< "hello\nbye\nbye\\ to\\ you\n@subdir/bar.rsp"
#endif
      }
      try localFileSystem.writeFileContents(barPath) {
        $0 <<< "from\nbar\n@subdir/foo.rsp"
      }
      let args = try Driver.expandResponseFiles(["swift", "compiler", "-Xlinker", "@loader_path", "@subdir/foo.rsp", "something"], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["swift", "compiler", "-Xlinker", "@loader_path", "hello", "bye", "bye to you", "from", "bar", "something"])
      XCTAssertEqual(diags.diagnostics.count, 1)
      XCTAssert(diags.diagnostics.first!.description.contains("is recursively expanded"))
    }
  }

  /// Tests how response files tokens such as spaces, comments, escaping characters and quotes, get parsed and expanded.
  func testResponseFileTokenization() throws {
    try withTemporaryDirectory { path  in
      let diags = DiagnosticsEngine()
      let fooPath = path.appending(component: "foo.rsp")
      let barPath = path.appending(component: "bar.rsp")
      let escapingPath = path.appending(component: "escaping.rsp")

#if os(Windows)
      try localFileSystem.writeFileContents(fooPath) {
        $0 <<< "a\\b c\\\\d e\\\\\"f g\" h\\\"i j\\\\\\\"k \"lmn\" o pqr \"st \\\"u\" \\v"
           <<< "\n@\(barPath.nativePathString(escaped: true))"
      }
      try localFileSystem.writeFileContents(barPath) {
        $0 <<< #"""
        -Xswiftc -use-ld=lld
        -Xcc -IS:\Library\sqlite-3.36.0\usr\include
        -Xlinker -LS:\Library\sqlite-3.36.0\usr\lib
        """#
      }
      let args = try Driver.expandResponseFiles(["@\(fooPath.pathString)"], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["a\\b", "c\\\\d", "e\\f g", "h\"i", "j\\\"k", "lmn", "o", "pqr", "st \"u", "\\v", "-Xswiftc", "-use-ld=lld", "-Xcc", "-IS:\\Library\\sqlite-3.36.0\\usr\\include", "-Xlinker", "-LS:\\Library\\sqlite-3.36.0\\usr\\lib"])
#else
      try localFileSystem.writeFileContents(fooPath) {
        $0 <<< #"""
        Command1 --kkc
        //This is a comment
        // this is another comment
        but this is \\\\\a command
        @\#(barPath.nativePathString(escaped: true))
        @NotAFile
        -flag="quoted string with a \"quote\" inside" -another-flag
        """#
        <<< "\nthis  line\thas        lots \t  of    whitespace"
      }

      try localFileSystem.writeFileContents(barPath) {
        $0 <<< #"""
        swift
        "rocks!"
        compiler
        -Xlinker

        @loader_path
        mkdir "Quoted Dir"
        cd Unquoted\ Dir
        // Bye!
        """#
      }

      try localFileSystem.writeFileContents(escapingPath) {
        $0 <<< "swift\n--driver-mode=swiftc\n-v\r\n//comment\n\"the end\""
      }
      let args = try Driver.expandResponseFiles(["@" + fooPath.pathString], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["Command1", "--kkc", "but", "this", "is", #"\\a"#, "command", #"swift"#, "rocks!" ,"compiler", "-Xlinker", "@loader_path", "mkdir", "Quoted Dir", "cd", "Unquoted Dir", "@NotAFile", #"-flag=quoted string with a "quote" inside"#, "-another-flag", "this", "line", "has", "lots", "of", "whitespace"])
      let escapingArgs = try Driver.expandResponseFiles(["@" + escapingPath.pathString], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(escapingArgs, ["swift", "--driver-mode=swiftc", "-v","the end"])
#endif
    }
  }

  func testUsingResponseFiles() throws {
    let manyArgs = (1...20000).map { "-DTEST_\($0)" }
    // Needs response file
    do {
      var driver = try Driver(args: ["swift"] + manyArgs + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: false)
      XCTAssertTrue(resolvedArgs.count == 2)
      XCTAssertEqual(resolvedArgs[1].first, "@")
      let responseFilePath = try AbsolutePath(validating: String(resolvedArgs[1].dropFirst()))
      let contents = try localFileSystem.readFileContents(responseFilePath).description
      XCTAssertTrue(contents.hasPrefix("\"-frontend\"\n\"-interpret\"\n\"foo.swift\""))
      XCTAssertTrue(contents.contains("\"-D\"\n\"TEST_20000\""))
      XCTAssertTrue(contents.contains("\"-D\"\n\"TEST_1\""))
    }
    // Forced response file
    do {
      var driver = try Driver(args: ["swift"] + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: true)
      XCTAssertTrue(resolvedArgs.count == 2)
      XCTAssertEqual(resolvedArgs[1].first, "@")
      let responseFilePath = try AbsolutePath(validating: String(resolvedArgs[1].dropFirst()))
      let contents = try localFileSystem.readFileContents(responseFilePath).description
      XCTAssertTrue(contents.hasPrefix("\"-frontend\"\n\"-interpret\"\n\"foo.swift\""))
    }

    // No response file
    do {
      var driver = try Driver(args: ["swift"] + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: false)
      XCTAssertFalse(resolvedArgs.map { $0.hasPrefix("@") }.reduce(false){ $0 || $1 })
    }
  }

  func testLinking() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    env["SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC"] = "/garbage/swift-autolink-extract"
    env["SWIFT_DRIVER_DSYMUTIL_EXEC"] = "/garbage/dsymutil"

    let commonArgs = ["swiftc", "foo.swift", "bar.swift",  "-module-name", "Test"]

    do {
      // macOS target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("x86_64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "macos", "10.15.0"]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // .tbd inputs are passed down to the linker.
      var driver = try Driver(args: commonArgs + ["foo.dylib", "foo.tbd", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()
      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)
      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: "foo.tbd"))))
      XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: "foo.dylib"))))
    }

    do {
      // iOS target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "arm64-apple-ios10.0"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("arm64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "ios", "10.0.0"]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // macOS catalyst target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-apple-ios13.1-macabi"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("x86_64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "mac-catalyst", "13.1.0"]))
      XCTAssertTrue(cmd.contains(.flag("13.1.0")))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // Xlinker flags
      var driver = try Driver(args: commonArgs + ["-emit-library", "-L", "/tmp", "-Xlinker", "-w", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-w")))
      XCTAssertTrue(cmd.contains(.flag("-L")))
      XCTAssertTrue(cmd.contains(.path(.absolute(AbsolutePath("/tmp")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    #if os(Linux)
    do {
      // Xlinker flags
      // Ensure that Xlinker flags are passed as such to the clang linker invocation.
      var driver = try Driver(args: commonArgs + ["-emit-library", "-L", "/tmp", "-Xlinker", "-w",
                                                  "-Xlinker", "-rpath=$ORIGIN",
                                                  "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(subsequence: [.flag("-Xlinker"), .flag("-rpath=$ORIGIN")]))
    }
    #endif

    do {
      var driver = try Driver(args: commonArgs + ["-emit-library", "-no-toolchain-stdlib-rpath",
                                                  "-target", "aarch64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      XCTAssertFalse(cmd.contains(subsequence: [.flag("-Xlinker"), .flag("-rpath"), .flag("-Xlinker")]))
    }

    do {
      // Object file inputs
      var driver = try Driver(args: commonArgs + ["baz.o", "-emit-library", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(linkJob.inputs.contains { matchTemporary($0.file, "foo.o") && $0.type == .object })
      XCTAssertTrue(linkJob.inputs.contains { matchTemporary($0.file, "bar.o") && $0.type == .object })
      XCTAssertTrue(linkJob.inputs.contains(.init(file: VirtualPath.relative(.init("baz.o")).intern(), type: .object)))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertTrue(cmd.contains(.path(.relative(.init("baz.o")))))
    }

    do {
      // static linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-L", "/tmp", "-Xlinker", "-w", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-static")))
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      // The regular Swift driver doesn't pass Xlinker flags to the static
      // linker, so be consistent with this
      XCTAssertFalse(cmd.contains(.flag("-w")))
      XCTAssertFalse(cmd.contains(.flag("-L")))
      XCTAssertFalse(cmd.contains(.path(.absolute(AbsolutePath("/tmp")))))

      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // static linking
      // Locating relevant libraries is dependent on being a macOS host
      #if os(macOS)
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-L", "/tmp", "-Xlinker", "-w", "-target", "x86_64-apple-macosx10.9", "-lto=llvm-full"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-static")))
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.bc"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.bc"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      // The regular Swift driver doesn't pass Xlinker flags to the static
      // linker, so be consistent with this
      XCTAssertFalse(cmd.contains(.flag("-w")))
      XCTAssertFalse(cmd.contains(.flag("-L")))
      XCTAssertFalse(cmd.contains(.path(.absolute(AbsolutePath("/tmp")))))

      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
      XCTAssertFalse(cmd.contains("-force_load"))
      XCTAssertFalse(cmd.contains("-platform_version"))
      XCTAssertFalse(cmd.contains("-lto_library"))
      XCTAssertFalse(cmd.contains("-syslibroot"))
      XCTAssertFalse(cmd.contains("-no_objc_category_merging"))
      #endif
    }

    do {
      // executable linking
      var driver = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // lto linking
      // Locating relevant libraries is dependent on being a macOS host
      #if os(macOS)
      var driver1 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-apple-macosx10.15", "-lto=llvm-thin"], env: env)
      let plannedJobs1 = try driver1.planBuild()
      XCTAssertFalse(plannedJobs1.contains(where: { $0.kind == .autolinkExtract }))
      let linkJob1 = plannedJobs1.first(where: { $0.kind == .link })
      XCTAssertTrue(linkJob1?.tool.name.contains("ld"))
      XCTAssertTrue(linkJob1?.commandLine.contains(.flag("-lto_library")))
      #endif

      var driver2 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-unknown-linux", "-lto=llvm-thin"], env: env)
      let plannedJobs2 = try driver2.planBuild()
      XCTAssertFalse(plannedJobs2.contains(where: { $0.kind == .autolinkExtract }))
      let linkJob2 = plannedJobs2.first(where: { $0.kind == .link })
      XCTAssertTrue(linkJob2?.tool.name.contains("clang"))
      XCTAssertTrue(linkJob2?.commandLine.contains(.flag("-flto=thin")))

      var driver3 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-unknown-linux", "-lto=llvm-full"], env: env)
      let plannedJobs3 = try driver3.planBuild()
      XCTAssertFalse(plannedJobs3.contains(where: { $0.kind == .autolinkExtract }))

      let compileJob3 = try XCTUnwrap(plannedJobs3.first(where: { $0.kind == .compile }))
      XCTAssertTrue(compileJob3.outputs.contains { $0.file.basename.hasSuffix(".bc") })

      let linkJob3 = try XCTUnwrap(plannedJobs3.first(where: { $0.kind == .link }))
      XCTAssertTrue(linkJob3.tool.name.contains("clang"))
      XCTAssertTrue(linkJob3.commandLine.contains(.flag("-flto=full")))
    }

    do {
      var driver = try Driver(args: commonArgs + ["-emit-executable", "-emit-module", "-g", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(5, plannedJobs.count)
      XCTAssertEqual(plannedJobs.map(\.kind), [.emitModule, .compile, .compile, .link, .generateDSYM])

      let linkJob = plannedJobs[3]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertTrue(cmd.contains(subsequence: [.flag("-add_ast_path"), .path(.relative(.init("Test.swiftmodule")))]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // linux target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "bar.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "Test.autolink"))

      let linkJob = plannedJobs[3]
      XCTAssertEqual(linkJob.kind, .link)
      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(cmd.contains(.flag("-shared")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertTrue(commandContainsTemporaryResponsePath(cmd, "Test.autolink"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.so"))

      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
    }

    do {
      // static linux linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "bar.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "Test.autolink"))

      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      // we'd expect "ar crs libTest.a foo.o bar.o"
      XCTAssertTrue(cmd.contains(.flag("crs")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      XCTAssertFalse(cmd.contains(.flag("-o")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
      XCTAssertFalse(cmd.contains(.flag("--start-group")))
      XCTAssertFalse(cmd.contains(.flag("--end-group")))
    }

    // /usr/lib/swift_static/linux/static-stdlib-args.lnk is required for static
    // linking on Linux, but is not present in macOS toolchains
    #if os(Linux)
    do {
      // executable linking linux static stdlib
      var driver = try Driver(args: commonArgs + ["-emit-executable", "-static-stdlib", "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "bar.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "Test.autolink"))

      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertTrue(cmd.contains(.flag("--start-group")))
      XCTAssertTrue(cmd.contains(.flag("--end-group")))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }
    #endif

    do {
      // static WASM linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-target", "wasm32-unknown-wasi"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "bar.o"))
      XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "Test.autolink"))

      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      // we'd expect "ar crs libTest.a foo.o bar.o"
      XCTAssertTrue(cmd.contains(.flag("crs")))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
      XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      XCTAssertFalse(cmd.contains(.flag("-o")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      try withTemporaryDirectory { path in
        try localFileSystem.writeFileContents(
          path.appending(components: "wasi", "static-executable-args.lnk")) { $0 <<< "garbage" }
        // WASM executable linking
        var driver = try Driver(args: commonArgs + ["-emit-executable",
                                                    "-target", "wasm32-unknown-wasi",
                                                    "-resource-dir", path.pathString,
                                                    "-sdk", "/sdk/path"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(plannedJobs.count, 4)

        let autolinkExtractJob = plannedJobs[2]
        XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

        let autolinkCmd = autolinkExtractJob.commandLine
        XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "foo.o"))
        XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "bar.o"))
        XCTAssertTrue(commandContainsTemporaryPath(autolinkCmd, "Test.autolink"))

        let linkJob = plannedJobs[3]
        let cmd = linkJob.commandLine
        XCTAssertTrue(cmd.contains(subsequence: ["-target", "wasm32-unknown-wasi"]))
        XCTAssertTrue(cmd.contains(subsequence: ["--sysroot", .path(.absolute(.init("/sdk/path")))]))
        XCTAssertTrue(cmd.contains(.path(.absolute(path.appending(components: "wasi", "wasm32", "swiftrt.o")))))
        XCTAssertTrue(commandContainsTemporaryPath(cmd, "foo.o"))
        XCTAssertTrue(commandContainsTemporaryPath(cmd, "bar.o"))
        XCTAssertTrue(commandContainsTemporaryResponsePath(cmd, "Test.autolink"))
        XCTAssertTrue(cmd.contains(.responseFilePath(.absolute(path.appending(components: "wasi", "static-executable-args.lnk")))))
        XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

        XCTAssertFalse(cmd.contains(.flag("-dylib")))
        XCTAssertFalse(cmd.contains(.flag("-shared")))
      }
    }

    do {
      // Linker flags with and without space
      var driver = try Driver(args: commonArgs + ["-lsomelib","-l","otherlib"], env: env)
      let plannedJobs = try driver.planBuild()
      let cmd = plannedJobs.last!.commandLine
      XCTAssertTrue(cmd.contains(.flag("-lsomelib")))
      XCTAssertTrue(cmd.contains(.flag("-lotherlib")))
    }

    do {
      // The Android NDK only uses the lld linker now
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "aarch64-unknown-linux-android24"], env: env)
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      let lastJob = plannedJobs.last!
      XCTAssertTrue(lastJob.tool.name.contains("clang"))
      XCTAssertTrue(lastJob.commandLine.contains(.flag("-fuse-ld=lld")))
    }
  }

  func testWebAssemblyUnsupportedFeatures() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC"] = "/garbage/swift-autolink-extract"
    do {
      var driver = try Driver(args: ["swift", "-target", "wasm32-unknown-wasi", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.interactiveModeUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "-emit-library", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.dynamicLibrariesUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "-no-static-executable", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.dynamicLibrariesUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "foo.swift", "-sanitize=thread"], env: env)) {
        guard case WebAssemblyToolchain.Error.sanitizersUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }
  }

  private func clangPathInActiveXcode() throws -> AbsolutePath? {
#if !os(macOS)
    return nil
#else
    let process = Process(arguments: ["xcrun", "-toolchain", "default", "-f", "clang"])
    try process.launch()
    let result = try process.waitUntilExit()
    guard result.exitStatus == .terminated(code: EXIT_SUCCESS) else { return nil }
    guard let path = String(bytes: try result.output.get(), encoding: .utf8) else { return nil }
    return path.isEmpty ? nil : AbsolutePath(path.spm_chomp())
#endif
  }

  func testCompatibilityLibs() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    try withTemporaryDirectory { path in
      let path5_0Mac = path.appending(components: "macosx", "libswiftCompatibility50.a")
      let path5_1Mac = path.appending(components: "macosx", "libswiftCompatibility51.a")
      let pathDynamicReplacementsMac = path.appending(components: "macosx", "libswiftCompatibilityDynamicReplacements.a")
      let path5_0iOS = path.appending(components: "iphoneos", "libswiftCompatibility50.a")
      let path5_1iOS = path.appending(components: "iphoneos", "libswiftCompatibility51.a")
      let pathDynamicReplacementsiOS = path.appending(components: "iphoneos", "libswiftCompatibilityDynamicReplacements.a")

      for compatibilityLibPath in [path5_0Mac, path5_1Mac,
                                   pathDynamicReplacementsMac, path5_0iOS,
                                   path5_1iOS, pathDynamicReplacementsiOS] {
        try localFileSystem.writeFileContents(compatibilityLibPath) { $0 <<< "Empty" }
      }
      let commonArgs = ["swiftc", "foo.swift", "bar.swift",  "-module-name", "Test", "-resource-dir", path.pathString]

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.14"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.1"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.4"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.4", "-runtime-compatibility-version", "5.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "arm64-apple-ios13.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1iOS))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsiOS))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "arm64-apple-ios12.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsiOS))]))
      }

      // libarclite is only relevant on darwin
      #if os(macOS)
      do {
        // Override executive paths and make sure this does not affect the location of the found
        // libarclite
        env["SWIFT_DRIVER_SWIFTC_EXEC"] = "/some/path/swiftc"
        env["SWIFT_DRIVER_CLANG_EXEC"] = "/some/path/clang"
        guard let clangPathInXcode = try? clangPathInActiveXcode() else {
          throw XCTSkip()
        }
        let clangRelativeArcLite = clangPathInXcode.parentDirectory.parentDirectory
                                   .appending(components: "lib", "arc", "libarclite_macosx.a")

        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.9"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(clangRelativeArcLite))]))
      }
      #endif
    }
  }

  func testSanitizerRecoverArgs() throws {
    let commonArgs = ["swiftc", "foo.swift", "bar.swift",]
    do {
      // address sanitizer + address sanitizer recover
      var driver = try Driver(args: commonArgs + ["-sanitize=address", "-sanitize-recover=address"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize-recover=address")))
    }
    do {
      // invalid sanitize recover arg
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize-recover=foo"]) {
        $1.expect(.error("invalid value 'foo' in '-sanitize-recover='"))
      }
    }
    do {
      // only address is supported
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize-recover=thread"]) {
        $1.expect(.error("unsupported argument 'thread' to option '-sanitize-recover='"))
      }
    }
    do {
      // only address is supported
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize-recover=scudo"]) {
        $1.expect(.error("unsupported argument 'scudo' to option '-sanitize-recover='"))
      }
    }
    do {
      // invalid sanitize recover arg
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize-recover=undefined"]) {
        $1.expect(.error("unsupported argument 'undefined' to option '-sanitize-recover='"))
      }
    }
    do {
      // no sanitizer + address sanitizer recover
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize-recover=address"]) {
        $1.expect(.warning("option '-sanitize-recover=address' has no effect when 'address' sanitizer is disabled. Use -sanitize=address to enable the sanitizer"))
      }
    }
    do {
      // thread sanitizer + address sanitizer recover
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize=thread", "-sanitize-recover=address"]) {
      #if os(Windows)
        $1.expect(.error("thread sanitizer is unavailable on target 'x86_64-unknown-windows-msvc'"))
      #endif
        $1.expect(.warning("option '-sanitize-recover=address' has no effect when 'address' sanitizer is disabled. Use -sanitize=address to enable the sanitizer"))
      }
    }
    // "-sanitize=undefined" is not available on x86_64-unknown-linux-gnu
    #if os(macOS)
    do {
      // multiple sanitizers separately
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize=undefined", "-sanitize=address", "-sanitize-recover=address"]) {
        $1.forbidUnexpected(.error, .warning)
      }
    }
    do {
      // comma sanitizer + address sanitizer recover together
      try assertDriverDiagnostics(args: commonArgs + ["-sanitize=undefined,address", "-sanitize-recover=address"]) {
        $1.forbidUnexpected(.error, .warning)
      }
    }
    #endif
  }

  func testSanitizerArgs() throws {
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-target", "x86_64-apple-macosx10.9",
      "-module-name", "Test"
    ]
  // FIXME: This doesn't work on Linux.
  #if os(macOS)
    do {
      // address sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=address"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.asan_osx_dynamic.dylib")
        }
        return false
      })
    }

    do {
      // thread sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=thread"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=thread")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.tsan_osx_dynamic.dylib")
        }
        return false
      })
    }

    do {
      // undefined behavior sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=undefined"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=undefined")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.ubsan_osx_dynamic.dylib")
        }
        return false
      })
    }

    // FIXME: This test will fail when run on macOS, because the driver uses
    //        the existence of the runtime support libraries to determine if
    //        a sanitizer is supported. Until we allow cross-compiling with
    //        sanitizers, we'll need to disable this test on macOS
    #if os(Linux)
    do {
      // linux multiple sanitizers
      var driver = try Driver(
        args: commonArgs + [
          "-target", "x86_64-unknown-linux",
          "-sanitize=address", "-sanitize=undefined"
        ]
      )
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=undefined")))

      let linkJob = plannedJobs[3]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains(.flag("-fsanitize=address,undefined")))
    }

    do {
      // linux scudo hardened allocator
      var driver = try Driver(
        args: commonArgs + [
          "-target", "x86_64-unknown-linux",
          "-sanitize=scudo"
        ]
      )
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=scudo")))

      let linkJob = plannedJobs[3]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains(.flag("-fsanitize=scudo")))
    }
    #endif
  #endif

  // FIXME: This test will fail when not run on Android, because the driver uses
  //        the existence of the runtime support libraries to determine if
  //        a sanitizer is supported. Until we allow cross-compiling with
  //        sanitizers, this test is disabled outside Android.
  #if os(Android)
    do {
      var driver = try Driver(
        args: commonArgs + [
          "-target", "aarch64-unknown-linux-android", "-sanitize=address"
        ]
      )
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))

      let linkJob = plannedJobs[3]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains(.flag("-fsanitize=address")))
    }
  #endif
  }

  func testSanitizerCoverageArgs() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-sanitize-coverage=func,trace-cmp"]) {
      $1.expect(.error("option '-sanitize-coverage=' requires a sanitizer to be enabled. Use -sanitize= to enable a sanitizer"))
    }

#if os(Windows)
    throw XCTSkip("tsan is not yet available on Windows")
#else
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-sanitize=thread", "-sanitize-coverage=bar"]) {
      $1.expect(.error("option '-sanitize-coverage=' is missing a required argument (\"func\", \"bb\", \"edge\")"))
      $1.expect(.error("unsupported argument 'bar' to option '-sanitize-coverage='"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-sanitize=thread", "-sanitize-coverage=func,baz"]) {
      $1.expect(.error("unsupported argument 'baz' to option '-sanitize-coverage='"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-sanitize=thread", "-sanitize-coverage=edge,indirect-calls,trace-bb,trace-cmp,8bit-counters")
#endif
  }

  func testSanitizerAddressUseOdrIndicator() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-sanitize=address", "-sanitize-address-use-odr-indicator", "Test.swift"])

      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-sanitize=address")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-sanitize-address-use-odr-indicator")))
    }

    do {
      try assertDriverDiagnostics(args: ["swiftc", "-sanitize=thread", "-sanitize-address-use-odr-indicator", "Test.swift"]) {
        $1.expect(.warning("option '-sanitize-address-use-odr-indicator' has no effect when 'address' sanitizer is disabled. Use -sanitize=address to enable the sanitizer"))
#if os(Windows)
        $1.expect(.error("thread sanitizer is unavailable on target 'x86_64-unknown-windows-msvc'"))
#endif
      }
    }

    do {
      try assertDriverDiagnostics(args: ["swiftc", "-sanitize-address-use-odr-indicator", "Test.swift"]) {
        $1.expect(.warning("option '-sanitize-address-use-odr-indicator' has no effect when 'address' sanitizer is disabled. Use -sanitize=address to enable the sanitizer"))
      }
    }
  }

  func testADDITIONAL_SWIFT_DRIVER_FLAGS() throws {
    var env = ProcessEnv.vars
    env["ADDITIONAL_SWIFT_DRIVER_FLAGS"] = "-Xfrontend -unknown1 -Xfrontend -unknown2"
    var driver = try Driver(args: ["swiftc", "foo.swift", "-module-name", "Test"], env: env)
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-unknown1")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-unknown2")))
    XCTAssertTrue(plannedJobs[1].kind == .link)
  }

  func testBatchModeCompiles() throws {
    do {
      var driver1 = try Driver(args: ["swiftc", "foo1.swift", "bar1.swift", "foo2.swift", "bar2.swift", "foo3.swift", "bar3.swift", "foo4.swift", "bar4.swift", "foo5.swift", "bar5.swift", "wibble.swift", "-module-name", "Test", "-enable-batch-mode", "-driver-batch-count", "3"])
      let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs.first!.file, "foo1.o"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 4)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs.first!.file, "foo3.o"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertTrue(matchTemporary(plannedJobs[2].outputs.first!.file, "foo5.o"))
      XCTAssertTrue(plannedJobs[3].tool.name.contains(driver1.targetTriple.isDarwin ? "ld" : "clang"))
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertEqual(plannedJobs[3].outputs.first!.file, VirtualPath.relative(RelativePath(executableName("Test"))))
    }

    // Test 1 partition results in 1 job
    do {
      var driver = try Driver(args: ["swiftc", "-toolchain-stdlib-rpath", "-module-cache-path", "/tmp/clang-module-cache", "-swift-version", "4", "-Xfrontend", "-ignore-module-source-info", "-module-name", "batch", "-enable-batch-mode", "-j", "1", "-c", "main.swift", "lib.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      var count = 0
      for arg in plannedJobs[0].commandLine where arg == .flag("-primary-file") {
        count += 1
      }
      XCTAssertEqual(count, 2)
    }
  }

  func testSingleThreadedWholeModuleOptimizationCompiles() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    var driver1 = try Driver(args: ["swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "-emit-library", "-emit-module", "-module-name", "Test", "-target", "x86_64-apple-macosx10.15", "-emit-module-interface", "-emit-objc-header-path", "Test-Swift.h", "-emit-private-module-interface-path", "Test.private.swiftinterface", "-emit-tbd"],
                             env: envVars)
    let plannedJobs = try driver1.planBuild()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))

    XCTAssertEqual(plannedJobs[0].kind, .compile)
    XCTAssertEqual(plannedJobs[0].outputs.count, 1)
    XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "Test.o"))
    XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))

    let emitModuleJob = plannedJobs.first(where: {$0.kind == .emitModule})!
    XCTAssertEqual(emitModuleJob.outputs.count, driver1.targetTriple.isDarwin ? 8 : 7)
    XCTAssertEqual(emitModuleJob.outputs[0].file, VirtualPath.relative(RelativePath("Test.swiftmodule")))
    XCTAssertEqual(emitModuleJob.outputs[1].file, VirtualPath.relative(RelativePath("Test.swiftdoc")))
    XCTAssertEqual(emitModuleJob.outputs[2].file, VirtualPath.relative(RelativePath("Test.swiftsourceinfo")))
    XCTAssertEqual(emitModuleJob.outputs[3].file, VirtualPath.relative(RelativePath("Test.swiftinterface")))
    XCTAssertEqual(emitModuleJob.outputs[4].file, VirtualPath.relative(RelativePath("Test.private.swiftinterface")))
    XCTAssertEqual(emitModuleJob.outputs[5].file, VirtualPath.relative(RelativePath("Test-Swift.h")))
    XCTAssertEqual(emitModuleJob.outputs[6].file, VirtualPath.relative(RelativePath("Test.tbd")))
    if driver1.targetTriple.isDarwin {
      XCTAssertEqual(emitModuleJob.outputs[7].file, VirtualPath.relative(RelativePath("Test.abi.json")))
    }
    XCTAssert(!emitModuleJob.commandLine.contains(.flag("-primary-file")))
    XCTAssert(emitModuleJob.commandLine.contains(.flag("-emit-module-interface-path")))
    XCTAssert(emitModuleJob.commandLine.contains(.flag("-emit-private-module-interface-path")))
  }


  func testIndexFileEntryInSupplementaryFileOutputMap() throws {
    var driver1 = try Driver(args: [
      "swiftc", "foo1.swift", "foo2.swift", "foo3.swift", "foo4.swift", "foo5.swift",
      "-index-file", "-index-file-path", "foo5.swift", "-o", "/tmp/t.o",
      "-index-store-path", "/tmp/idx"
    ])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 1)
    let suppleArg = "-supplementary-output-file-map"
    // Make sure we are using supplementary file map
    XCTAssert(plannedJobs[0].commandLine.contains(.flag(suppleArg)))
    let args = plannedJobs[0].commandLine
    var fileMapPath: VirtualPath?
    for pair in args.enumerated() {
      if pair.element == .flag(suppleArg) {
        let filemap = args[pair.offset + 1]
        switch filemap {
        case .path(let p):
          fileMapPath = p
        default:
          break
        }
      }
    }
    XCTAssert(fileMapPath != nil)
    switch fileMapPath! {
    case .fileList(_, let list):
      switch list {
      case .outputFileMap(let map):
        // This is to match the legacy driver behavior
        // Make sure the supplementary output map has an entry for the Swift file
        // under indexing and its indexData entry is the primary output file
        let entry = map.entries[VirtualPath.relative(RelativePath("foo5.swift")).intern()]!
        XCTAssert(VirtualPath.lookup(entry[.indexData]!) == .absolute(AbsolutePath("/tmp/t.o")))
        return
      default:
        break
      }
      break
    default:
      break
    }
    XCTAssert(false)
  }

  func testMultiThreadedWholeModuleOptimizationCompiles() throws {
    do {
      var driver1 = try Driver(args: [
        "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift",
        "-module-name", "Test", "-num-threads", "4"
      ])
      let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "foo.o"))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[1].file, "bar.o"))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[2].file, "wibble.o"))
      XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))

      XCTAssertEqual(plannedJobs[1].kind, .link)
    }

    // emit-module
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "-wmo", "-num-threads", "4", "main.swift", "multi-threaded.swift", "-emit-module", "-o", "test.swiftmodule"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, VirtualPath.relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, VirtualPath.relative(RelativePath("multi-threaded.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.relative(RelativePath("test.swiftmodule")))
    }
  }

  func testEmitABIDescriptor() throws {
#if !os(macOS)
    throw XCTSkip("Skipping: ABI descriptor is only emitted on Darwin platforms.")
#endif
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "-wmo", "main.swift", "multi-threaded.swift", "-emit-module", "-o", "test.swiftmodule"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-abi-descriptor-path")))
    }
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "main.swift", "multi-threaded.swift", "-emit-module", "-o", "test.swiftmodule", "-experimental-emit-module-separately"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(plannedJobs[0].kind, .emitModule)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-abi-descriptor-path")))
    }
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "main.swift", "multi-threaded.swift", "-emit-module", "-o", "test.swiftmodule", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(plannedJobs[2].kind, .mergeModule)
      XCTAssertTrue(plannedJobs[2].commandLine.contains(.flag("-emit-abi-descriptor-path")))
    }
    
  }

  func testDashDashPassingDownInput() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "-wmo", "-num-threads", "4", "-emit-module", "-o", "test.swiftmodule", "--", "main.swift", "multi-threaded.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertFalse(driver.diagnosticEngine.hasErrors)
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, VirtualPath.relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, VirtualPath.relative(RelativePath("multi-threaded.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.relative(RelativePath("test.swiftmodule")))
    }
  }

  func testWholeModuleOptimizationOutputFileMap() throws {
    let contents = """
    {
      "": {
        "swiftinterface": "/tmp/salty/Test.swiftinterface"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        var driver1 = try Driver(args: [
          "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift", "-module-name", "Test",
          "-num-threads", "4", "-output-file-map", file.path.pathString, "-emit-module-interface"
        ])
        let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
        XCTAssertEqual(plannedJobs.count, 3)
        XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))

        XCTAssertEqual(plannedJobs[0].kind, .compile)
        XCTAssertEqual(plannedJobs[0].outputs.count, 3)
        XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "foo.o"))
        XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[1].file, "bar.o"))
        XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[2].file, "wibble.o"))
        XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))

        let emitModuleJob = plannedJobs.first(where: {$0.kind == .emitModule})!
        XCTAssertEqual(emitModuleJob.outputs[3].file, VirtualPath.absolute(AbsolutePath("/tmp/salty/Test.swiftinterface")))
        XCTAssert(!emitModuleJob.commandLine.contains(.flag("-primary-file")))

        XCTAssertEqual(plannedJobs[2].kind, .link)
      }
    }
  }

  func testModuleAliasingWithImplicitBuild() throws {
    var driver = try Driver(args: [
      "swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "Car=Bar",
      "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule",
    ])
    let plannedJobs = try driver.planBuild()
    XCTAssertTrue(plannedJobs.contains { job in
      job.commandLine.contains(.flag("-module-alias")) &&
      job.commandLine.contains(.flag("Car=Bar")) &&
      job.outputs[0].file.absolutePath?.pathString == "/tmp/dir/Foo.swiftmodule"
    })
    XCTAssertEqual(driver.moduleOutputInfo.name, "Foo")
    XCTAssertNotNil(driver.moduleOutputInfo.aliases)
    XCTAssertEqual(driver.moduleOutputInfo.aliases!.count, 1)
    XCTAssertEqual(driver.moduleOutputInfo.aliases!["Car"], "Bar")
  }

  func testInvalidModuleAliasing() throws {
    try assertDriverDiagnostics(
      args: ["swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "CarBar", "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule"]
    ) {
      $1.expect(.error("invalid format \"CarBar\"; use the format '-module-alias alias_name=underlying_name'"))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "Foo=Bar", "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule"]
    ) {
      $1.expect(.error("module alias \"Foo\" should be different from the module name \"Foo\""))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "C-ar=Bar", "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule"]
    ) {
      $1.expect(.error("module name \"C-ar\" is not a valid identifier"))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "Car=Bar", "-module-alias", "Train=Car", "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule"]
    ) {
      $1.expect(.error("the name \"Car\" is already used for a module alias or an underlying name"))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "foo.swift", "-module-name", "Foo", "-module-alias", "Car=Bar", "-module-alias", "Car=Bus", "-emit-module", "-emit-module-path", "/tmp/dir/Foo.swiftmodule"]
    ) {
      $1.expect(.error("the name \"Car\" is already used for a module alias or an underlying name"))
    }
  }

  func testWholeModuleOptimizationUsingSupplementaryOutputFileMap() throws {
    var driver1 = try Driver(args: [
      "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift", "-module-name", "Test",
      "-emit-module-interface", "-driver-filelist-threshold=0"
    ])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssertEqual(plannedJobs[0].kind, .compile)
    XCTAssert(plannedJobs[0].commandLine.contains(.flag("-supplementary-output-file-map")))
  }

  func testOptimizationRecordFileInSupplementaryOutputFileMap() throws {
    func checkSupplementaryOutputFileMap(format: String, _ fileType: FileType) throws {
      var driver1 = try Driver(args: [
        "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift", "-module-name", "Test",
        "-save-optimization-record=\(format)", "-driver-filelist-threshold=0"
      ])
      let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      print(plannedJobs[0].commandLine.joinedUnresolvedArguments)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-supplementary-output-file-map")))
      let argIdx = try XCTUnwrap(plannedJobs[0].commandLine.firstIndex(where: { $0 == .flag("-supplementary-output-file-map") }))
      let supplOutputs = plannedJobs[0].commandLine[argIdx+1]
      guard case let .path(path) = supplOutputs,
            case let .fileList(_, fileList) = path,
            case let .outputFileMap(outFileMap) = fileList else {
        throw StringError("Unexpected argument for output file map")
      }
      XCTAssertEqual(outFileMap.entries.values.first?.keys.first, fileType)
    }

    try checkSupplementaryOutputFileMap(format: "yaml", .yamlOptimizationRecord)
    try checkSupplementaryOutputFileMap(format: "bitstream", .bitstreamOptimizationRecord)
  }

  func testUpdateCode() throws {
    do {
      var driver = try Driver(args: [
        "swiftc", "-update-code", "foo.swift", "bar.swift"
      ])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .compile, .link])
      XCTAssertTrue(commandContainsFlagTemporaryPathSequence(plannedJobs[0].commandLine,
                                                             flag: "-emit-remap-file-path",
                                                             filename: "foo.remap"))
      XCTAssertTrue(commandContainsFlagTemporaryPathSequence(plannedJobs[1].commandLine,
                                                             flag: "-emit-remap-file-path",
                                                             filename: "bar.remap"))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "-update-code", "foo.swift", "bar.swift", "-enable-batch-mode", "-driver-batch-count", "1"]
    ) {
      _ = try? $0.planBuild()
      $1.expect(.error("using '-update-code' in batch compilation mode is not supported"))
    }

    try assertDriverDiagnostics(
      args: ["swiftc", "-update-code", "foo.swift", "bar.swift", "-wmo"]
    ) {
      _ = try? $0.planBuild()
      $1.expect(.error("using '-update-code' in whole module optimization mode is not supported"))
    }

    do {
      var driver = try Driver(args: [
        "swiftc", "-update-code", "foo.swift", "-migrate-keep-objc-visibility"
      ])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertTrue(commandContainsFlagTemporaryPathSequence(plannedJobs[0].commandLine,
                                                             flag: "-emit-remap-file-path",
                                                             filename: "foo.remap"))
      XCTAssertTrue(plannedJobs[0].commandLine.contains("-migrate-keep-objc-visibility"))
    }
  }

  func testMergeModulesOnly() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-emit-dependencies", "-emit-module-source-info-path", "/foo/bar/Test.swiftsourceinfo", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .mergeModule]))
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)

      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "foo.swiftmodule"))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[1].file, "foo.swiftdoc"))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[2].file, "foo.swiftsourceinfo"))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[3].file, "foo.d"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))

      XCTAssertEqual(plannedJobs[1].outputs.count, 4)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "bar.swiftmodule"))
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[1].file, "bar.swiftdoc"))
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[2].file, "bar.swiftsourceinfo"))
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[3].file, "bar.d"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-import-objc-header")))

      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .absolute(AbsolutePath("/foo/bar/Test.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[2].outputs[3].file, .relative(RelativePath("Test.abi.json")))
      }
      XCTAssert(plannedJobs[2].commandLine.contains(.flag("-import-objc-header")))
    }

    do {
      let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/foo/bar", relativeTo: $0) }
                    ?? AbsolutePath(validating: "/foo/bar")

      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root))))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root))))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root))))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[2].outputs[3].file, .absolute(AbsolutePath(rebase("Test.abi.json", at: root))))
      }
    }

    do {
      // Make sure the swiftdoc path is correct for a relative module
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "Test.swiftmodule", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .relative(RelativePath("Test.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[2].outputs[3].file, .relative(RelativePath("Test.abi.json")))
      }
    }

    do {
      // Make sure the swiftdoc path is correct for an inferred module
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .relative(RelativePath("Test.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[2].outputs[3].file, .relative(RelativePath("Test.abi.json")))
      }
    }

    do {
      // -o specified
      var driver = try Driver(args: ["swiftc", "-emit-module", "-o", "/tmp/test.swiftmodule", "input.swift", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "input.swiftmodule"))
      XCTAssertEqual(plannedJobs[1].kind, .mergeModule)
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs[0].file, "input.swiftmodule"))
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .absolute(AbsolutePath("/tmp/test.swiftmodule")))
    }
  }

  func testEmitModuleSeparately() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    do {
      let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/foo/bar", relativeTo: $0) }
                    ?? AbsolutePath(validating: "/foo/bar")

      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-emit-symbol-graph", "-emit-symbol-graph-dir", "/foo/bar/", "-experimental-emit-module-separately", "-emit-library", "-target", "x86_64-apple-macosx10.15"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))
      XCTAssertTrue(plannedJobs[0].tool.name.contains("swift"))
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-parse-as-library")))
      XCTAssertEqual(plannedJobs[0].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root))))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root))))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root))))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[0].outputs[3].file, .absolute(AbsolutePath(rebase("Test.abi.json", at: root))))
      }

      // We don't know the output file of the symbol graph, just make sure the flag is passed along.
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-symbol-graph-dir")))
    }

    do {
      let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/foo/bar", relativeTo: $0) }
                    ?? AbsolutePath(validating: "/foo/bar")

      // We don't expect partial jobs when asking only for the swiftmodule with
      // -experimental-emit-module-separately.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-experimental-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.emitModule, .compile]))
      XCTAssertTrue(plannedJobs[0].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[0].outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root))))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root))))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root))))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs[0].outputs[3].file, .absolute(AbsolutePath(rebase("Test.abi.json", at: root))))
      }
    }

    do {
      // Specifying -no-emit-module-separately uses a mergeModule job.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule", "-experimental-emit-module-separately", "-no-emit-module-separately" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .mergeModule]))
    }

    do {
      // Calls using the driver to link a library shouldn't trigger an emit-module job, like in LLDB tests.
      var driver = try Driver(args: ["swiftc", "-emit-library", "foo.swiftmodule", "foo.o", "-emit-module-path", "foo.swiftmodule", "-experimental-emit-module-separately", "-target", "x86_64-apple-macosx10.15"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.link]))
    }

    do {
      // Use emit-module to build sil files.
      var driver = try Driver(args: ["swiftc", "foo.sil", "bar.sil", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule", "-experimental-emit-module-separately", "-emit-library", "-target", "x86_64-apple-macosx10.15"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))
    }
  }

  func testEmitModuleSeparatelyWMO() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)
    let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/foo/bar", relativeTo: $0) }
                  ?? AbsolutePath(validating: "/foo/bar")

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-emit-symbol-graph", "-emit-symbol-graph-dir", root.pathString, "-emit-library", "-target", "x86_64-apple-macosx10.15", "-wmo", "-emit-module-separately-wmo"],
                               env: envVars)
      
      let abiFileCount = (driver.isFeatureSupported(.emit_abi_descriptor) && driver.targetTriple.isDarwin) ? 1 : 0
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))

      // The compile job only produces the object file.
      let compileJob = plannedJobs.first(where: {$0.kind == .compile})!
      XCTAssertTrue(compileJob.tool.name.contains("swift"))
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-parse-as-library")))
      XCTAssertEqual(compileJob.outputs.count, 1)
      XCTAssertEqual(1, compileJob.outputs.filter({$0.type == .object}).count)

      // The emit module job produces the module files.
      let emitModuleJob = plannedJobs.first(where: {$0.kind == .emitModule})!
      XCTAssertTrue(emitModuleJob.tool.name.contains("swift"))
      XCTAssertEqual(emitModuleJob.outputs.count, 3 + abiFileCount)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root)))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root)))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root)))}).count)
      if abiFileCount == 1 {
        XCTAssertEqual(abiFileCount, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.abi.json", at: root)))}).count)
      }

      // We don't know the output file of the symbol graph, just make sure the flag is passed along.
      XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("-emit-symbol-graph-dir")))
    }

    do {
      // Ignore the `-emit-module-separately-wmo` flag when building only the module files to avoid duplicating outputs.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-wmo", "-emit-module-separately-wmo"])
      let abiFileCount = (driver.isFeatureSupported(.emit_abi_descriptor) && driver.targetTriple.isDarwin) ? 1 : 0
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile]))

      // The compile job produces the module files.
      let emitModuleJob = plannedJobs[0]
      XCTAssertTrue(emitModuleJob.tool.name.contains("swift"))
      XCTAssertEqual(emitModuleJob.outputs.count, 3 + abiFileCount)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root)))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root)))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root)))}).count)
      if abiFileCount == 1 {
        XCTAssertEqual(abiFileCount, emitModuleJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.abi.json", at: root)))}).count)
      }
    }

    do {
      // Specifying -no-emit-module-separately-wmo doesn't schedule the separate emit-module job.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-emit-library", "-wmo", "-emit-module-separately-wmo", "-no-emit-module-separately-wmo" ])
      let abiFileCount = (driver.isFeatureSupported(.emit_abi_descriptor) && driver.targetTriple.isDarwin) ? 1 : 0
      let plannedJobs = try driver.planBuild()
      #if os(Linux) || os(Android)
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .link, .autolinkExtract]))
      #else
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .link]))
      #endif

      // The compile job produces both the object file and the module files.
      let compileJob = plannedJobs.first(where: {$0.kind == .compile})!
      XCTAssertEqual(compileJob.outputs.count, 4 + abiFileCount)
      XCTAssertEqual(1, compileJob.outputs.filter({$0.type == .object}).count)
      XCTAssertEqual(1, compileJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftmodule", at: root)))}).count)
      XCTAssertEqual(1, compileJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftdoc", at: root)))}).count)
      XCTAssertEqual(1, compileJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.swiftsourceinfo", at: root)))}).count)
      if abiFileCount == 1 {
        XCTAssertEqual(abiFileCount, compileJob.outputs.filter({$0.file == .absolute(AbsolutePath(rebase("Test.abi.json", at: root)))}).count)
      }
    }

    #if os(Linux) || os(Android)
    let autoLinkExtractJob = 1
    #else
    let autoLinkExtractJob = 0
    #endif

    do {
      // non library-evolution builds require a single job, because cross-module-optimization is enabled by default.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-c", "-o", rebase("test.o", at: root), "-wmo", "-O" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1 + autoLinkExtractJob)
    }

    do {
      // library-evolution builds can emit the module in a separate job.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-c", "-o", rebase("test.o", at: root), "-wmo", "-O", "-enable-library-evolution" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2 + autoLinkExtractJob)
    }

    do {
      // When disabling cross-module-optimization, the module can be emitted in a separate job.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-c", "-o", rebase("test.o", at: root), "-wmo", "-O", "-disable-cmo" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2 + autoLinkExtractJob)
    }

    do {
      // non optimized builds can emit the module in a separate job.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", rebase("Test.swiftmodule", at: root), "-c", "-o", rebase("test.o", at: root), "-wmo" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2 + autoLinkExtractJob)
    }

    do {
        // Don't use emit-module-separetely as a linker.
      var driver = try Driver(args: ["swiftc", "foo.sil", "bar.sil", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule", "-emit-library", "-target", "x86_64-apple-macosx10.15", "-wmo", "-emit-module-separately-wmo"],
                               env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .link]))
    }
  }

  func testModuleWrapJob() throws {
    // FIXME: These tests will fail when run on macOS, because
    // swift-autolink-extract is not present
    #if os(Linux) || os(Android)
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "-g", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 5)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .autolinkExtract, .moduleWrap, .link]))
      let wrapJob = plannedJobs.filter {$0.kind == .moduleWrap} .first!
      XCTAssertEqual(wrapJob.inputs.count, 1)
      XCTAssertTrue(wrapJob.commandLine.contains(subsequence: ["-target", "x86_64-unknown-linux-gnu"]))
      let mergeJob = plannedJobs.filter {$0.kind == .emitModule} .first!
      XCTAssertTrue(mergeJob.outputs.contains(wrapJob.inputs.first!))
      XCTAssertTrue(plannedJobs[4].inputs.contains(wrapJob.outputs.first!))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      // No merge module/module wrap jobs.
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .autolinkExtract, .link]))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "-gdwarf-types", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      // Merge module, but no module wrapping.
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .emitModule, .autolinkExtract, .link]))
    }
    #endif
    // dsymutil won't be found on other platforms
    #if os(macOS)
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-macosx10.15", "-g", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      // No module wrapping with Mach-O.
      XCTAssertEqual(plannedJobs.map { $0.kind }, [.emitModule, .compile, .link, .generateDSYM])
    }
    #endif
  }

  func testRepl() throws {
    // Do not run this test if no LLDB is found in the toolchain.
    if try !testEnvHasLLDB() {
      throw XCTSkip()
    }

    func isExpectedLLDBREPLFlag(_ arg: Job.ArgTemplate) -> Bool {
      if case let .squashedArgumentList(option: opt, args: args) = arg {
        return opt == "--repl=" && !args.contains("-module-name")
      }
      return false
    }

    do {
      var driver = try Driver(args: ["swift"], env: envWithFakeSwiftHelp)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      let helpJob = plannedJobs[0]
      XCTAssertTrue(helpJob.tool.name.contains("swift-help"))
      XCTAssertTrue(helpJob.commandLine.contains(.flag("intro")))
    }

    do {
      var driver = try Driver(args: ["swift", "-repl"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let replJob = plannedJobs.first!
      XCTAssertTrue(replJob.tool.name.contains("lldb"))
      XCTAssertTrue(replJob.requiresInPlaceExecution)
      XCTAssert(replJob.commandLine.contains(where: { isExpectedLLDBREPLFlag($0) }))
    }

    do {
      let (mode, args) = try Driver.invocationRunMode(forArgs: ["swift", "repl"])
      XCTAssertEqual(mode, .normal(isRepl: true))
      var driver = try Driver(args: args)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let replJob = plannedJobs.first!
      XCTAssertTrue(replJob.tool.name.contains("lldb"))
      XCTAssertTrue(replJob.requiresInPlaceExecution)
      XCTAssert(replJob.commandLine.contains(where: { isExpectedLLDBREPLFlag($0) }))
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swift", "-deprecated-integrated-repl"])) {
        XCTAssertEqual($0 as? Driver.Error, Driver.Error.integratedReplRemoved)
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-repl", "/foo/bar/Test.swift"])
      XCTAssertThrowsError(try driver.planBuild()) { error in
        XCTAssertEqual(error as? PlanningError, .replReceivedInput)
      }
    }

    do {
      // Linked library arguments with space
      var driver = try Driver(args: ["swift", "-repl", "-l", "somelib", "-lotherlib"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let cmd = plannedJobs.first!.commandLine
      guard case let .squashedArgumentList(option: _, args: args) = cmd[0] else {
        XCTFail()
        return
      }
      XCTAssertTrue(args.contains(.flag("-lsomelib")))
      XCTAssertTrue(args.contains(.flag("-lotherlib")))
    }
  }

  func testInstallAPI() throws {
    let modulePath = "/tmp/FooMod.swiftmodule"
    var driver = try Driver(args: ["swiftc", "foo.swift", "-whole-module-optimization",
                                   "-module-name", "FooMod",
                                   "-emit-tbd", "-emit-tbd-path", "/tmp/FooMod.tbd",
                                   "-emit-module", "-emit-module-path", modulePath])
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 1)
    XCTAssertEqual(plannedJobs[0].kind, .compile)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-frontend")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-module")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: modulePath))))
  }

  func testImmediateMode() throws {
    do {
      var driver = try Driver(args: ["swift", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)
      XCTAssertTrue(job.commandLine.contains(.flag("-frontend")))
      XCTAssertTrue(job.commandLine.contains(.flag("-interpret")))
      XCTAssertTrue(job.commandLine.contains(.flag("-module-name")))
      XCTAssertTrue(job.commandLine.contains(.flag("foo")))

      if driver.targetTriple.isMacOSX {
        XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      }

      XCTAssertFalse(job.commandLine.contains(.flag("--")))

      let envVar: String
      if driver.targetTriple.isDarwin {
        envVar = "DYLD_LIBRARY_PATH"
      } else if driver.targetTriple.isWindows {
        envVar = "Path"
      } else {
        // assume Unix
        envVar = "LD_LIBRARY_PATH"
      }

      // The library search path applies to import libraries not runtime
      // libraries on Windows.  There is no way to derive the path from the
      // command on Windows.
      if !driver.targetTriple.isWindows {
        #if os(macOS)
        // On darwin, swift ships in the OS. Immediate mode should use that runtime.
        XCTAssertFalse(job.extraEnvironment.keys.contains(envVar))
        #else
        XCTAssertTrue(job.extraEnvironment.keys.contains(envVar))
        #endif
      }
    }

    do {
      var driver = try Driver(args: ["swift", "foo.swift", "-some", "args", "-for=foo"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)
      XCTAssertTrue(job.commandLine.contains(.flag("-frontend")))
      XCTAssertTrue(job.commandLine.contains(.flag("-interpret")))
      XCTAssertTrue(job.commandLine.contains(.flag("-module-name")))
      XCTAssertTrue(job.commandLine.contains(.flag("foo")))
      XCTAssertTrue(job.commandLine.contains(.flag("--")))
      XCTAssertTrue(job.commandLine.contains(.flag("-some")))
      XCTAssertTrue(job.commandLine.contains(.flag("args")))
      XCTAssertTrue(job.commandLine.contains(.flag("-for=foo")))
    }

    do {
      var driver = try Driver(args: ["swift", "-L/path/to/lib", "-F/path/to/framework", "-lsomelib", "-l", "otherlib", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)

      let envVar: String
      if driver.targetTriple.isDarwin {
        envVar = "DYLD_LIBRARY_PATH"
      } else if driver.targetTriple.isWindows {
        envVar = "Path"
      } else {
        // assume Unix
        envVar = "LD_LIBRARY_PATH"
      }

      // The library search path applies to import libraries not runtime
      // libraries on Windows.  There is no way to derive the path from the
      // command on Windows.
      if !driver.targetTriple.isWindows {
        XCTAssertTrue(job.extraEnvironment[envVar, default: ""].contains("/path/to/lib"))
        if driver.targetTriple.isDarwin {
          XCTAssertTrue(job.extraEnvironment["DYLD_FRAMEWORK_PATH", default: ""].contains("/path/to/framework"))
        }
      }

      XCTAssertTrue(job.commandLine.contains(.flag("-lsomelib")))
      XCTAssertTrue(job.commandLine.contains(.flag("-lotherlib")))
    }
  }

  func testTargetTriple() throws {
    let driver1 = try Driver(args: ["swiftc", "-c", "foo.swift", "-module-name", "Foo"])

    let expectedDefaultContents: String
    #if os(macOS)
    expectedDefaultContents = "-apple-macosx"
    #elseif os(Linux) || os(Android)
    expectedDefaultContents = "-unknown-linux"
    #elseif os(Windows)
    expectedDefaultContents = "-unknown-windows-msvc"
    #else
    expectedDefaultContents = "-"
    #endif

    XCTAssert(driver1.targetTriple.triple.contains(expectedDefaultContents),
              "Default triple \(driver1.targetTriple) contains \(expectedDefaultContents)")

    let driver2 = try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-watchos12", "foo.swift", "-module-name", "Foo"])
    XCTAssertEqual(
      driver2.targetTriple.triple, "x86_64-apple-watchos12-simulator")

    let driver3 = try Driver(args: ["swiftc", "-c", "-target", "x86_64-watchos12", "foo.swift", "-module-name", "Foo"])
    XCTAssertEqual(
      driver3.targetTriple.triple, "x86_64-unknown-watchos12-simulator")
  }

  func testTargetVariant() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    do {
      var driver = try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios13.1-macabi", "-target-variant", "x86_64-apple-macosx10.14", "foo.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.1-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "-target", "x86_64-apple-ios13.1-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-module-name", "foo", "foo.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.1-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssertTrue(plannedJobs[1].commandLine.contains(subsequence: [
        "-platform_version", "mac-catalyst", "13.1.0"]))
      XCTAssertTrue(plannedJobs[1].commandLine.contains(subsequence: [
        "-platform_version", "macos", "10.14.0"]))
    }

    // Test -target-variant is passed to generate pch job
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-ios13.1-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-enable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.1-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("x86_64-apple-ios13.1-macabi")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence: [
        "-platform_version", "mac-catalyst", "13.1.0"]))
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence: [
        "-platform_version", "macos", "10.14.0"]))
    }
  }

  func testValidDeprecatedTargets() throws {
    var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "armv7-apple-ios13.0", "foo.swift"])
    let plannedJobs = try driver.planBuild()
    let emitModuleJob = plannedJobs.first(where: {$0.kind == .emitModule})
    XCTAssertNotNil(emitModuleJob)
    let currentJob = emitModuleJob!
    XCTAssert(currentJob.commandLine.contains(.flag("-target")))
    XCTAssert(currentJob.commandLine.contains(.flag("armv7-apple-ios13.0")))
  }

  func testClangTargetForExplicitModule() throws {
    #if os(macOS)
    // Check -clang-target is on by default when explicit module is on.
    try withTemporaryDirectory { path in
      let main = path.appending(component: "Foo.swift")
      try localFileSystem.writeFileContents(main) {
        $0 <<< "import Swift"
      }
      var driver = try Driver(args: ["swiftc", "-explicit-module-build", "-target",
                                     "x86_64-apple-macosx10.14", main.pathString])
      guard driver.isFrontendArgSupported(.clangTarget) else {
        throw XCTSkip("Skipping: compiler does not support '-clang-target'")
      }
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.contains { job in
        job.commandLine.contains(.flag("-clang-target"))
      })
    }
    // Check -disable-clang-target works
    try withTemporaryDirectory { path in
      let main = path.appending(component: "Foo.swift")
      try localFileSystem.writeFileContents(main) {
        $0 <<< "import Swift"
      }
      var driver = try Driver(args: ["swiftc", "-disable-clang-target",
                                     "-explicit-module-build", "-target",
                                     "x86_64-apple-macosx10.14", main.pathString])
      guard driver.isFrontendArgSupported(.clangTarget) else {
        throw XCTSkip("Skipping: compiler does not support '-clang-target'")
      }
      let plannedJobs = try driver.planBuild()
      XCTAssertFalse(plannedJobs.contains { job in
        job.commandLine.contains(.flag("-clang-target"))
      })
    }
    #endif
  }

  func testDisableClangTargetForImplicitModule() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    var driver = try Driver(args: ["swiftc", "-target",
                                   "x86_64-apple-macosx10.14", "foo.swift"],
                            env: envVars)
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
    XCTAssertFalse(plannedJobs[0].commandLine.contains(.flag("-clang-target")))
  }

  func testPCHasCompileInput() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-macosx10.14", "-enable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"],
                            env: envVars)
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssert(plannedJobs[0].kind == .generatePCH)
    XCTAssert(plannedJobs[1].kind == .compile)
    XCTAssert(plannedJobs[1].inputs[0].file.extension == "swift")
    XCTAssert(plannedJobs[1].inputs[1].file.extension == "pch")
  }

  func testEnvironmentInferenceWarning() throws {
    let sdkRoot = testInputsPath.appending(component: "SDKChecks").appending(component: "iPhoneOS.sdk")

    try assertDriverDiagnostics(args: ["swiftc", "-target", "x86_64-apple-ios13.0", "foo.swift", "-sdk", sdkRoot.pathString]) {
      $1.expect(.warning("inferring simulator environment for target 'x86_64-apple-ios13.0'; use '-target x86_64-apple-ios13.0-simulator'"))
    }
    try assertDriverDiagnostics(args: ["swiftc", "-target", "x86_64-apple-watchos6.0", "foo.swift", "-sdk", sdkRoot.pathString]) {
      $1.expect(.warning("inferring simulator environment for target 'x86_64-apple-watchos6.0'; use '-target x86_64-apple-watchos6.0-simulator'"))
    }
    try assertNoDriverDiagnostics(args: "swiftc", "-target", "x86_64-apple-ios13.0-simulator", "foo.swift", "-sdk", sdkRoot.pathString)
  }

  func testDarwinToolchainArgumentValidation() throws {
    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios6.0",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("iOS 7") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-macosx10.4",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("OS X 10.9") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "armv7-apple-ios12.1",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.invalidDeploymentTargetForIR("iOS 11", "armv7") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-emit-module", "-c", "-target", 
                                           "armv7s-apple-ios12.0", "foo.swift"])) { error in
        guard case DarwinToolchain.ToolchainValidationError.invalidDeploymentTargetForIR("iOS 11", "armv7s") = error else {
          XCTFail()
          return
        }
      }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios13.0",
                                           "-target-variant", "x86_64-apple-macosx10.14",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.unsupportedTargetVariant(variant: _) = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-static-stdlib", "-target", "x86_64-apple-macosx10.14",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.argumentNotSupported("-static-stdlib") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-static-executable", "-target", "x86_64-apple-macosx10.14",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.argumentNotSupported("-static-executable") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-macosx10.14", "-experimental-cxx-stdlib", "libstdc++",
                                           "foo.swift"])) { error in
        guard case DarwinToolchain.ToolchainValidationError.darwinOnlySupportsLibCxx = error else {
        XCTFail()
        return
      }
    }
    // On non-darwin hosts, libArcLite won't be found and a warning will be emitted
    #if os(macOS)
    try assertNoDriverDiagnostics(args: "swiftc", "-c", "-target", "x86_64-apple-macosx10.14", "-link-objc-runtime", "foo.swift")
    #endif
  }

  func testProfileArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-profile-generate", "-profile-use=profile.profdata"]) {
      $1.expect(.error(Driver.Error.conflictingOptions(.profileGenerate, .profileUse)))
      $1.expect(.error(Driver.Error.missingProfilingData("profile.profdata")))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-profile-use=profile.profdata"]) {
      $1.expect(.error(Driver.Error.missingProfilingData("profile.profdata")))
    }

    try withTemporaryDirectory { path in
      try localFileSystem.writeFileContents(path.appending(component: "profile.profdata"), bytes: .init())
      try assertNoDriverDiagnostics(args: "swiftc", "-working-directory", path.pathString, "foo.swift", "-profile-use=profile.profdata")
    }

    try withTemporaryDirectory { path in
      try localFileSystem.writeFileContents(path.appending(component: "profile.profdata"), bytes: .init())
      try assertDriverDiagnostics(args: ["swiftc", "-working-directory", path.pathString, "foo.swift",
                                         "-profile-use=profile.profdata,profile2.profdata"]) {
        $1.expect(.error(Driver.Error.missingProfilingData(path.appending(component: "profile2.profdata").pathString)))
      }
    }
  }

  func testProfileLinkerArgs() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "x86_64-apple-macosx10.9", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_osx.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "x86_64-apple-ios7.1-simulator", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_ios.a"))
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_iossim.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "arm64-apple-ios7.1", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_ios.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "x86_64-apple-tvos9.0-simulator", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_tvos.a"))
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_tvossim.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "arm64-apple-tvos9.0", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_tvos.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "i386-apple-watchos2.0-simulator", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_watchos.a"))
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_watchossim.a"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "armv7k-apple-watchos2.0", "test.swift"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile_watchos.a"))
    }

    // FIXME: This will fail when run on macOS, because
    // swift-autolink-extract is not present
    #if os(Linux) || os(Android) || os(Windows)
    do {
      var driver = try Driver(args: ["swiftc", "-profile-generate", "-target", "x86_64-unknown-linux-gnu", "test.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssert(plannedJobs[1].commandLine.containsPathWithBasename("libclang_rt.profile-x86_64.a"))
      XCTAssert(plannedJobs[1].commandLine.contains { $0 == .flag("-u__llvm_profile_runtime") })
    }
    #endif

    // TODO: Windows
  }

  func testConditionalCompilationArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-DFOO=BAR"]) {
      $1.expect(.warning("conditional compilation flags do not have values in Swift; they are either present or absent (rather than 'FOO=BAR')"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-D-DFOO"]) {
      $1.expect(.error(Driver.Error.conditionalCompilationFlagHasRedundantPrefix("-DFOO")))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-Dnot-an-identifier"]) {
      $1.expect(.error(Driver.Error.conditionalCompilationFlagIsNotValidIdentifier("not-an-identifier")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-DFOO")
  }

  func testFrameworkSearchPathArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-F/some/dir/xyz.framework"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-F/some/dir/xyz.framework/"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework/"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-Fsystem", "/some/dir/xyz.framework"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
    }

   try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-Fsystem", "/some/dir/")
  }

  func testMultipleValidationFailures() throws {
    try assertDiagnostics { engine, verifier in
      verifier.expect(.error(Driver.Error.conditionalCompilationFlagIsNotValidIdentifier("not-an-identifier")))
      verifier.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
      _ = try Driver(args: ["swiftc", "foo.swift", "-Dnot-an-identifier", "-F/some/dir/xyz.framework"], diagnosticsEngine: engine)
    }
  }

  func testToolsDirectory() throws {
    try withTemporaryDirectory { tmpDir in
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
      let ld = tmpDir.appending(component: "ld")
#else
      let ld = tmpDir.appending(component: executableName("clang"))
#endif
      // tiny PE binary from: https://archive.is/w01DO
      let contents: [UInt8] = [
          0x4d, 0x5a, 0x00, 0x00, 0x50, 0x45, 0x00, 0x00, 0x4c, 0x01, 0x01, 0x00,
          0x6a, 0x2a, 0x58, 0xc3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x04, 0x00, 0x03, 0x01, 0x0b, 0x01, 0x08, 0x00, 0x04, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00,
          0x04, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
          0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x68, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x02
      ]
      try localFileSystem.writeFileContents(ld) { $0 <<< contents }
      try localFileSystem.chmod(.executable, path: AbsolutePath(ld.pathString))
      var driver = try Driver(args: ["swiftc",
                                     "-tools-directory", tmpDir.pathString,
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(frontendJobs.count, 2)
      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertEqual(frontendJobs[1].tool.absolutePath!.pathString, ld.pathString)
    }
  }

  // Test cases ported from Driver/macabi-environment.swift
  func testDarwinSDKVersioning() throws {
    var envVars = ProcessEnv.vars
    envVars["ENABLE_RESTRICT_SWIFTMODULE_SDK"] = "YES"
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    try withTemporaryDirectory { tmpDir in
      let sdk1 = tmpDir.appending(component: "MacOSX10.15.sdk")
      try localFileSystem.writeFileContents(sdk1.appending(component: "SDKSettings.json")) {
        $0 <<< """
        {
          "Version":"10.15",
          "CanonicalName": "macosx10.15",
          "VersionMap" : {
              "macOS_iOSMac" : {
                  "10.15" : "13.1",
                  "10.15.1" : "13.2"
              },
              "iOSMac_macOS" : {
                  "13.1" : "10.15",
                  "13.2" : "10.15.1"
              }
          }
        }
        """
      }

      let sdk2 = tmpDir.appending(component: "MacOSX10.15.4.sdk")
      try localFileSystem.writeFileContents(sdk2.appending(component: "SDKSettings.json")) {
        $0 <<< """
        {
          "Version":"10.15.4",
          "CanonicalName": "macosx10.15.4",
          "VersionMap" : {
              "macOS_iOSMac" : {
                  "10.14.4" : "12.4",
                  "10.14.3" : "12.3",
                  "10.14.2" : "12.2",
                  "10.14.1" : "12.1",
                  "10.15" : "13.0",
                  "10.14" : "12.0",
                  "10.14.5" : "12.5",
                  "10.15.1" : "13.2",
                  "10.15.4" : "13.4"
              },
              "iOSMac_macOS" : {
                  "13.0" : "10.15",
                  "12.3" : "10.14.3",
                  "12.0" : "10.14",
                  "12.4" : "10.14.4",
                  "12.1" : "10.14.1",
                  "12.5" : "10.14.5",
                  "12.2" : "10.14.2",
                  "13.2" : "10.15.1",
                  "13.4" : "10.15.4"
              }
          }
        }
        """
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-sdk", sdk1.description,
                                       "foo.swift"], env: envVars)
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15")
        ]))
        if driver.isFrontendArgSupported(.targetSdkName) {
          XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
            .flag("-target-sdk-name"),
            .flag("macosx10.15"),
          ]))
        }
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.0"),
        ]))
      }

      do {
        var envVars = ProcessEnv.vars
        envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-target-variant", "x86_64-apple-ios13.1-macabi",
                                       "-sdk", sdk1.description,
                                       "foo.swift"], env: envVars)
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15"),
          .flag("-target-variant-sdk-version"),
          .flag("13.1"),
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.0"),
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.1.0"),
          .flag("13.1.0"),
        ]))
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-target-variant", "x86_64-apple-ios13.1-macabi",
                                       "-sdk", sdk2.description,
                                       "foo.swift"], env: envVars)
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15.4"),
          .flag("-target-variant-sdk-version"),
          .flag("13.4")
        ]))
        if driver.isFrontendArgSupported(.targetSdkName) {
          XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
            .flag("-target-sdk-name"),
            .flag("macosx10.15.4"),
          ]))
        }
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.4"),
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.1.0"),
          .flag("13.4.0"),
        ]))
      }

      do {
        var envVars = ProcessEnv.vars
        envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

        var driver = try Driver(args: ["swiftc",
                                       "-target-variant", "x86_64-apple-macosx10.14",
                                       "-target", "x86_64-apple-ios13.1-macabi",
                                       "-sdk", sdk2.description,
                                       "foo.swift"], env: envVars)
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("13.4"),
          .flag("-target-variant-sdk-version"),
          .flag("10.15.4")
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.1.0"),
          .flag("13.4.0"),
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.4"),
        ]))
      }
    }
  }

  func testDarwinSDKTooOld() throws {
    func getSDKPath(sdkDirName: String) -> AbsolutePath {
      return testInputsPath.appending(component: "SDKChecks").appending(component: sdkDirName)
    }

    // Ensure an error is emitted for an unsupported SDK
    func checkSDKUnsupported(sdkDirName: String)
    throws {
      let sdkPath = getSDKPath(sdkDirName: sdkDirName)
      // Get around the check for SDK's existence
      try localFileSystem.createDirectory(sdkPath)
      let args = [ "swiftc", "foo.swift", "-target", "x86_64-apple-macosx10.9", "-sdk", sdkPath.pathString ]
      try assertDriverDiagnostics(args: args) { driver, verifier in
        verifier.expect(.error("Swift does not support the SDK \(sdkPath.pathString)"))
      }
    }

    // Ensure no error is emitted for a supported SDK
    func checkSDKOkay(sdkDirName: String) throws {
      let sdkPath = getSDKPath(sdkDirName: sdkDirName)
      try localFileSystem.createDirectory(sdkPath)
      let args = [ "swiftc", "foo.swift", "-target", "x86_64-apple-macosx10.9", "-sdk", sdkPath.pathString ]
      try assertNoDiagnostics { de in let _ = try Driver(args: args, diagnosticsEngine: de) }
    }

    // Ensure old/bogus SDK versions are caught
    try checkSDKUnsupported(sdkDirName: "tvOS8.0.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX10.8.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX10.9.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX10.10.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX10.11.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX7.17.sdk")
    try checkSDKUnsupported(sdkDirName: "MacOSX10.14.Internal.sdk")
    try checkSDKUnsupported(sdkDirName: "iPhoneOS7.sdk")
    try checkSDKUnsupported(sdkDirName: "iPhoneSimulator7.sdk")
    try checkSDKUnsupported(sdkDirName: "iPhoneOS12.99.sdk")
    try checkSDKUnsupported(sdkDirName: "watchOS2.0.sdk")
    try checkSDKUnsupported(sdkDirName: "watchOS3.0.sdk")
    try checkSDKUnsupported(sdkDirName: "watchOS3.0.Internal.sdk")

    // Verify a selection of okay SDKs
    try checkSDKOkay(sdkDirName: "MacOSX10.15.sdk")
    try checkSDKOkay(sdkDirName: "MacOSX10.15.4.sdk")
    try checkSDKOkay(sdkDirName: "MacOSX10.15.Internal.sdk")
    try checkSDKOkay(sdkDirName: "iPhoneOS13.0.sdk")
    try checkSDKOkay(sdkDirName: "tvOS13.0.sdk")
    try checkSDKOkay(sdkDirName: "watchOS6.0.sdk")
    try checkSDKOkay(sdkDirName: "watchSimulator6.0.sdk")
    try checkSDKOkay(sdkDirName: "iPhoneOS.sdk")
    try checkSDKOkay(sdkDirName: "tvOS.sdk")
    try checkSDKOkay(sdkDirName: "watchOS.sdk")
  }

  func testDarwinLinkerPlatformVersion() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-macos10.15",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("macos"),
        .flag("10.15.0"),
      ]))
    }

    // Mac gained aarch64 support in v11
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "arm64-apple-macos10.15",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("macos"),
        .flag("11.0.0"),
      ]))
    }

    // Mac Catalyst on x86_64 was introduced in v13.
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-ios12.0-macabi",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("mac-catalyst"),
        .flag("13.1.0"),
      ]))
    }

    // Mac Catalyst on arm was introduced in v14.
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0-macabi",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("mac-catalyst"),
        .flag("14.0.0"),
      ]))
    }

    // Regular iOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios"),
        .flag("12.0.0"),
      ]))
    }

    // Regular tvOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-tvos12.0",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("tvos"),
        .flag("12.0.0"),
      ]))
    }

    // Regular watchOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-watchos6.0",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("watchos"),
        .flag("6.0.0"),
      ]))
    }

    // x86_64 iOS simulator
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-ios12.0-simulator",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios-simulator"),
        .flag("12.0.0"),
      ]))
    }

    // aarch64 iOS simulator
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0-simulator",
                                     "foo.swift"],
                              env: envVars)
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios-simulator"),
        .flag("14.0.0"),
      ]))
    }
  }

  func testDSYMGeneration() throws {
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-module-name", "Test",
    ]

    do {
      // No dSYM generation (no -g)
      var driver = try Driver(args: commonArgs)
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .generateDSYM })
    }

    do {
      // No dSYM generation (-gnone)
      var driver = try Driver(args: commonArgs + ["-gnone"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .generateDSYM })
    }

    do {
      var env = ProcessEnv.vars
      // As per Unix conventions, /var/empty is expected to exist and be empty.
      // This gives us a non-existent path that we can use for libtool which
      // allows us to run this this on non-Darwin platforms.
      env["SWIFT_DRIVER_LIBTOOL_EXEC"] = "/var/empty/libtool"

      // No dSYM generation (-g -emit-library -static)
      var driver = try Driver(args: [
        "swiftc", "-target", "x86_64-apple-macosx10.15", "-g", "-emit-library",
        "-static", "-o", "library.a", "library.swift"
      ], env: env)
      let jobs = try driver.planBuild()

      XCTAssertEqual(jobs.count, 3)
      XCTAssertFalse(jobs.contains { $0.kind == .generateDSYM })
    }

    do {
      // dSYM generation (-g)
      var driver = try Driver(args: commonArgs + ["-g"])
      let plannedJobs = try driver.planBuild()

      let generateDSYMJob = plannedJobs.last!
      let cmd = generateDSYMJob.commandLine

      if driver.targetTriple.objectFormat == .elf  {
        XCTAssertEqual(plannedJobs.count, 6)
      } else {
        XCTAssertEqual(plannedJobs.count, 5)
      }

      if driver.targetTriple.isDarwin {
        XCTAssertEqual(generateDSYMJob.outputs.last?.file, try VirtualPath(path: "Test.dSYM"))
      } else {
        XCTAssertFalse(plannedJobs.map { $0.kind }.contains(.generateDSYM))
      }

      XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: executableName("Test")))))
    }

    do {
      // dSYM generation (-g) with specified output file name with an extension
      var driver = try Driver(args: commonArgs + ["-g", "-o", "a.out"])
      let plannedJobs = try driver.planBuild()
      let generateDSYMJob = plannedJobs.last!
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs.count, 5)
        XCTAssertEqual(generateDSYMJob.outputs.last?.file, try VirtualPath(path: "a.out.dSYM"))
      }
    }
  }

  func testEmitModuleTrace() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-emit-loaded-module-trace", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(
        job.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                               .path(.relative(.init("foo.trace.json")))])
      )
    }
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck",
                                     "-emit-loaded-module-trace",
                                     "foo.swift", "bar.swift", "baz.swift"])
      let plannedJobs = try driver.planBuild()
      let tracedJobs = plannedJobs.filter {
        $0.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                              .path(.relative(.init("main.trace.json")))])
      }
      XCTAssertEqual(tracedJobs.count, 1)
    }
    do {
      // Make sure the trace is associated with the first frontend job as
      // opposed to the first input.
      var driver = try Driver(args: ["swiftc", "-emit-loaded-module-trace",
                                     "foo.o", "bar.swift", "baz.o"])
      let plannedJobs = try driver.planBuild()
      let tracedJobs = plannedJobs.filter {
        $0.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                              .path(.relative(.init("main.trace.json")))])
      }
      XCTAssertEqual(tracedJobs.count, 1)
      XCTAssertTrue(tracedJobs[0].inputs.contains(.init(file: VirtualPath.relative(.init("bar.swift")).intern(), type: .swift)))
    }
    do {
      var env = ProcessEnv.vars
      env["SWIFT_LOADED_MODULE_TRACE_FILE"] = "/some/path/to/the.trace.json"
      var driver = try Driver(args: ["swiftc", "-typecheck",
                                     "-emit-loaded-module-trace", "foo.swift"],
                              env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(
        job.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                               .path(.absolute(.init("/some/path/to/the.trace.json")))])
      )
    }
  }

  func testVerifyDebugInfo() throws {
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-module-name", "Test", "-verify-debug-info"
    ]

    // No dSYM generation (no -g), therefore no verification
    try assertDriverDiagnostics(args: commonArgs) { driver, verifier in
      verifier.expect(.warning("ignoring '-verify-debug-info'; no debug info is being generated"))
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .verifyDebugInfo })
    }

    // No dSYM generation (-gnone), therefore no verification
    try assertDriverDiagnostics(args: commonArgs + ["-gnone"]) { driver, verifier in
      verifier.expect(.warning("ignoring '-verify-debug-info'; no debug info is being generated"))
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .verifyDebugInfo })
    }

    do {
      // dSYM generation and verification (-g + -verify-debug-info)
      var driver = try Driver(args: commonArgs + ["-g"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      let verifyDebugInfoJob = plannedJobs.last!
      let cmd = verifyDebugInfoJob.commandLine

      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs.count, 6)
        XCTAssertEqual(verifyDebugInfoJob.inputs.first?.file, try VirtualPath(path: "Test.dSYM"))
        XCTAssertTrue(cmd.contains(.flag("--verify")))
        XCTAssertTrue(cmd.contains(.flag("--debug-info")))
        XCTAssertTrue(cmd.contains(.flag("--eh-frame")))
        XCTAssertTrue(cmd.contains(.flag("--quiet")))
        XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: "Test.dSYM"))))
      } else {
        XCTAssertEqual(plannedJobs.count, 5)
      }
    }
  }

  func testLEqualPassedDownToLinkerInvocation() throws {
    let workingDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/Foo/Bar", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")

    var driver = try Driver(args: [
      "swiftc", "-working-directory", workingDirectory.pathString, "-emit-executable", "test.swift", "-L=.", "-F=."
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    let workDir: VirtualPath = try VirtualPath(path: workingDirectory.nativePathString(escaped: false))

    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.joinedOptionAndPath("-F=", workDir)))
    XCTAssertFalse(plannedJobs[0].commandLine.contains(.joinedOptionAndPath("-L=", workDir)))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.joinedOptionAndPath("-L=", workDir)))
    XCTAssertFalse(plannedJobs[1].commandLine.contains(.joinedOptionAndPath("-F=", workDir)))
    // Test implicit output file also honors the working directory.
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: rebase(executableName("test"), at: workingDirectory)))))
  }

  func testWorkingDirectoryForImplicitOutputs() throws {
    let workingDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/Foo/Bar", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")

    var driver = try Driver(args: [
      "swiftc", "-working-directory", workingDirectory.pathString, "-emit-executable", "-c", "/tmp/main.swift"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

    XCTAssertEqual(plannedJobs.count, 1)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: rebase("main.o", at: workingDirectory)))))
  }

  func testWorkingDirectoryForImplicitModules() throws {
    let workingDirectory =
        try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/Foo/Bar", relativeTo: $0) }
                ?? AbsolutePath(validating: "/Foo/Bar")

    var driver = try Driver(args: [
      "swiftc", "-working-directory", workingDirectory.pathString, "-emit-module", "/tmp/main.swift"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: rebase("main.swiftmodule", at: workingDirectory)))))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-module-doc-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: rebase("main.swiftdoc", at: workingDirectory)))))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-module-source-info-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: rebase("main.swiftsourceinfo", at: workingDirectory)))))
  }

  func testDOTFileEmission() throws {
    // Reset the temporary store to ensure predictable results.
    VirtualPath.resetTemporaryFileStore()
    var driver = try Driver(args: [
      "swiftc", "-emit-executable", "test.swift", "-emit-module", "-avoid-emit-module-source-info", "-experimental-emit-module-separately"
    ])
    let plannedJobs = try driver.planBuild()

    var serializer = DOTJobGraphSerializer(jobs: plannedJobs)
    var output = ""
    serializer.writeDOT(to: &output)

    let linkerDriver = driver.targetTriple.isDarwin ? executableName("ld") : executableName("clang")
    if driver.targetTriple.objectFormat == .elf {
        XCTAssertEqual(output,
        """
        digraph Jobs {
          "emitModule (\(executableName("swift-frontend")))" [style=bold];
          "test.swift" [fontsize=12];
          "test.swift" -> "emitModule (\(executableName("swift-frontend")))" [color=blue];
          "test.swiftmodule" [fontsize=12];
          "emitModule (\(executableName("swift-frontend")))" -> "test.swiftmodule" [color=green];
          "test.swiftdoc" [fontsize=12];
          "emitModule (\(executableName("swift-frontend")))" -> "test.swiftdoc" [color=green];
          "compile (\(executableName("swift-frontend")))" [style=bold];
          "test.swift" -> "compile (\(executableName("swift-frontend")))" [color=blue];
          "test-1.o" [fontsize=12];
          "compile (\(executableName("swift-frontend")))" -> "test-1.o" [color=green];
          "autolinkExtract (\(executableName("swift-autolink-extract")))" [style=bold];
          "test-1.o" -> "autolinkExtract (\(executableName("swift-autolink-extract")))" [color=blue];
          "test-2.autolink" [fontsize=12];
          "autolinkExtract (\(executableName("swift-autolink-extract")))" -> "test-2.autolink" [color=green];
          "link (\(executableName("clang")))" [style=bold];
          "test-1.o" -> "link (\(executableName("clang")))" [color=blue];
          "test-2.autolink" -> "link (\(executableName("clang")))" [color=blue];
          "\(executableName("test"))" [fontsize=12];
          "link (\(executableName("clang")))" -> "\(executableName("test"))" [color=green];
        }

        """)
    } else if driver.targetTriple.objectFormat == .macho {
        XCTAssertEqual(output,
        """
        digraph Jobs {
          "emitModule (\(executableName("swift-frontend")))" [style=bold];
          "test.swift" [fontsize=12];
          "test.swift" -> "emitModule (\(executableName("swift-frontend")))" [color=blue];
          "test.swiftmodule" [fontsize=12];
          "emitModule (\(executableName("swift-frontend")))" -> "test.swiftmodule" [color=green];
          "test.swiftdoc" [fontsize=12];
          "emitModule (\(executableName("swift-frontend")))" -> "test.swiftdoc" [color=green];
          "test.abi.json" [fontsize=12];
          "emitModule (\(executableName("swift-frontend")))" -> "test.abi.json" [color=green];
          "compile (\(executableName("swift-frontend")))" [style=bold];
          "test.swift" -> "compile (\(executableName("swift-frontend")))" [color=blue];
          "test-1.o" [fontsize=12];
          "compile (\(executableName("swift-frontend")))" -> "test-1.o" [color=green];
          "link (\(linkerDriver))" [style=bold];
          "test-1.o" -> "link (\(linkerDriver))" [color=blue];
          "\(executableName("test"))" [fontsize=12];
          "link (\(linkerDriver))" -> "\(executableName("test"))" [color=green];
        }

        """)
    } else {
      XCTAssertEqual(output,
      """
      digraph Jobs {
        "emitModule (\(executableName("swift-frontend")))" [style=bold];
        "test.swift" [fontsize=12];
        "test.swift" -> "emitModule (\(executableName("swift-frontend")))" [color=blue];
        "test.swiftmodule" [fontsize=12];
        "emitModule (\(executableName("swift-frontend")))" -> "test.swiftmodule" [color=green];
        "test.swiftdoc" [fontsize=12];
        "emitModule (\(executableName("swift-frontend")))" -> "test.swiftdoc" [color=green];
        "compile (\(executableName("swift-frontend")))" [style=bold];
        "test.swift" -> "compile (\(executableName("swift-frontend")))" [color=blue];
        "test-1.o" [fontsize=12];
        "compile (\(executableName("swift-frontend")))" -> "test-1.o" [color=green];
        "link (\(linkerDriver))" [style=bold];
        "test-1.o" -> "link (\(linkerDriver))" [color=blue];
        "\(executableName("test"))" [fontsize=12];
        "link (\(linkerDriver))" -> "\(executableName("test"))" [color=green];
      }

      """)
    }
  }

  func testRegressions() throws {
    var driverWithEmptySDK = try Driver(args: ["swiftc", "-sdk", "", "file.swift"])
    _ = try driverWithEmptySDK.planBuild()

    var driver = try Driver(args: ["swiftc", "foo.swift", "-sdk", "/"])
    let plannedJobs = try driver.planBuild()
    XCTAssertTrue(plannedJobs[0].commandLine.contains(subsequence: ["-sdk", .path(.absolute(.init("/")))]))
  }

  func testDumpASTOverride() throws {
    try assertDriverDiagnostics(args: ["swiftc", "-wmo", "-dump-ast", "foo.swift"]) {
      $1.expect(.warning("ignoring '-wmo' because '-dump-ast' was also specified"))
      let jobs = try $0.planBuild()
      XCTAssertEqual(jobs[0].kind, .compile)
      XCTAssertFalse(jobs[0].commandLine.contains("-wmo"))
      XCTAssertTrue(jobs[0].commandLine.contains("-dump-ast"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "-index-file", "-dump-ast",
                                       "foo.swift",
                                       "-index-file-path", "foo.swift",
                                       "-index-store-path", "store/path",
                                       "-index-ignore-system-modules"]) {
      $1.expect(.warning("ignoring '-index-file' because '-dump-ast' was also specified"))
      let jobs = try $0.planBuild()
      XCTAssertEqual(jobs[0].kind, .compile)
      XCTAssertFalse(jobs[0].commandLine.contains("-wmo"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-file"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-file-path"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-store-path"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-ignore-stdlib"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-system-modules"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-ignore-system-modules"))
      XCTAssertTrue(jobs[0].commandLine.contains("-dump-ast"))
    }
  }

  func testDeriveSwiftDocPath() throws {
    var driver = try Driver(args: [
      "swiftc", "-emit-module", "/tmp/main.swift", "-emit-module-path", "test-ios-macabi.swiftmodule"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[0].kind == .emitModule)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftmodule"))))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-module-doc-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftdoc"))))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-module-source-info-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftsourceinfo"))))
  }

  func testToolchainClangPath() throws {
    // Overriding the swift executable to a specific location breaks this.
    guard ProcessEnv.vars["SWIFT_DRIVER_SWIFT_EXEC"] == nil,
          ProcessEnv.vars["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC"] == nil else {
      return
    }
    // TODO: remove this conditional check once DarwinToolchain does not requires xcrun to look for clang.
    var toolchain: Toolchain
    let executor = try SwiftDriverExecutor(diagnosticsEngine: DiagnosticsEngine(),
                                           processSet: ProcessSet(),
                                           fileSystem: localFileSystem,
                                           env: ProcessEnv.vars)
    #if os(macOS)
    toolchain = DarwinToolchain(env: ProcessEnv.vars, executor: executor)
    #elseif os(Windows)
    toolchain = WindowsToolchain(env: ProcessEnv.vars, executor: executor)
    #else
    toolchain = GenericUnixToolchain(env: ProcessEnv.vars, executor: executor)
    #endif

    XCTAssertEqual(
      try? toolchain.getToolPath(.swiftCompiler).parentDirectory,
      try? toolchain.getToolPath(.clang).parentDirectory
    )
  }

  func testExecutableFallbackPath() throws {
    let driver1 = try Driver(args: ["swift", "main.swift"])
    if !driver1.targetTriple.isDarwin {
      XCTAssertThrowsError(try driver1.toolchain.getToolPath(.dsymutil))
    }

    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    let driver2 = try Driver(args: ["swift", "main.swift"], env: env)
    XCTAssertNoThrow(try driver2.toolchain.getToolPath(.dsymutil))
  }

  func testVersionRequest() throws {
    for arg in ["-version", "--version"] {
      var driver = try Driver(args: ["swift"] + [arg])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .versionRequest)
      XCTAssertEqual(job.commandLine, [.flag("--version")])
    }
  }

  func testNoInputs() throws {
    // A plain `swift` invocation requires lldb to be present
    if try testEnvHasLLDB() {
      do {
        var driver = try Driver(args: ["swift"], env: envWithFakeSwiftHelp)
        XCTAssertNoThrow(try driver.planBuild())
      }
    }
    do {
      var driver = try Driver(args: ["swiftc"], env: envWithFakeSwiftHelp)
      XCTAssertThrowsError(try driver.planBuild()) {
        XCTAssertEqual($0 as? Driver.Error, .noInputFiles)
      }
    }
    do {
      var driver = try Driver(args: ["swiftc", "-v"])
      XCTAssertNoThrow(try driver.planBuild())
    }
    do {
      var driver = try Driver(args: ["swiftc", "-v", "-whole-module-optimization"])
      XCTAssertNoThrow(try driver.planBuild())
    }
    do {
      var driver = try Driver(args: ["swiftc", "-whole-module-optimization"])
      XCTAssertThrowsError(try driver.planBuild()) {
        XCTAssertEqual($0 as? Driver.Error, .noInputFiles)
      }
    }
  }

  func testPrintTargetInfo() throws {
    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "arm64-apple-ios12.0", "-sdk", "bar", "-resource-dir", "baz"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      XCTAssertTrue(job.commandLine.contains(.flag("-resource-dir")))
    }

    do {
      struct MockExecutor: DriverExecutor {
        let resolver: ArgsResolver

        func execute(job: Job, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : Date]) throws -> ProcessResult {
          return ProcessResult(arguments: [], environment: [:], exitStatus: .terminated(code: 0), output: .success(Array("bad JSON".utf8)), stderrOutput: .success([]))
        }
        func execute(workload: DriverExecutorWorkload,
                     delegate: JobExecutionDelegate,
                     numParallelJobs: Int,
                     forceResponseFiles: Bool,
                     recordedInputModificationDates: [TypedVirtualPath : Date]) throws {
          fatalError()
        }
        func checkNonZeroExit(args: String..., environment: [String : String]) throws -> String {
          return try Process.checkNonZeroExit(arguments: args, environment: environment)
        }
        func description(of job: Job, forceResponseFiles: Bool) throws -> String {
          fatalError()
        }
      }

      XCTAssertThrowsError(try Driver(args: ["swift", "-print-target-info"],
                                      executor: MockExecutor(resolver: ArgsResolver(fileSystem: InMemoryFileSystem())))) {
        error in
        if case .unableToDecodeFrontendTargetInfo = error as? Driver.Error {}
        else {
          XCTFail("not a decoding error")
        }
      }
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swift", "-print-target-info"],
                                      env: ["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": "/bad/path/to/swift-frontend"])) {
        error in
        XCTAssertTrue(error is Driver.Error)

        switch error {
        case Driver.Error.failedToRetrieveFrontendTargetInfo,
             Driver.Error.failedToRunFrontendToRetrieveTargetInfo:
          break;

        default:
          XCTFail("unexpected error \(error)")
        }
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-apple-ios13.1-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-sdk", "bar", "-resource-dir", "baz"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target-variant")))
      XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      XCTAssertTrue(job.commandLine.contains(.flag("-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux", "-static-stdlib"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux", "-static-executable"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }
  }

  func testFrontendSupportedArguments() throws {
    do {
      // General case: ensure supported frontend arguments have been computed, one way or another
      let driver = try Driver(args: ["swift", "-target", "arm64-apple-ios12.0",
                                     "-resource-dir", "baz"])
      XCTAssertTrue(driver.supportedFrontendFlags.contains("emit-module"))
    }
    do {
      let driver = try Driver(args: ["swift", "-target", "arm64-apple-ios12.0",
                                     "-resource-dir", "baz"])
      if let libraryBasedResult = try driver.querySupportedArgumentsForTest() {
        XCTAssertTrue(libraryBasedResult.contains("emit-module"))
      }
    }
    do {
      // Test the fallback path of computing the supported arguments using a swift-frontend
      // invocation, by pointing the driver to look for libSwiftScan in a place that does not
      // exist
      var env = ProcessEnv.vars
      env["SWIFT_DRIVER_SWIFT_SCAN_TOOLCHAIN_PATH"] = "/some/nonexistent/path"
      let driver = try Driver(args: ["swift", "-target", "arm64-apple-ios12.0",
                                     "-resource-dir", "baz"],
                              env: env)
      XCTAssertTrue(driver.supportedFrontendFlags.contains("emit-module"))
    }
  }

  func testPrintOutputFileMap() throws {
    try withTemporaryDirectory { path in
      // Replace the error stream with one we capture here.
      let errorStream = stderrStream

      let root = try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/build", relativeTo: $0) }
                    ?? AbsolutePath(validating: "/build")

      let errorOutputFile = path.appending(component: "dummy_error_stream")
      TSCBasic.stderrStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(errorOutputFile))

      let libObj: AbsolutePath = root.appending(component: "lib.o")
      let mainObj: AbsolutePath = root.appending(component: "main.o")
      let basicOutputFileMapObj: AbsolutePath = root.appending(component: "basic_output_file_map.o")

      let dummyInput: AbsolutePath = path.appending(component: "output_file_map_test.swift")
      let mainSwift: AbsolutePath = path.appending(components: "Inputs", "main.swift")
      let libSwift: AbsolutePath = path.appending(components: "Inputs", "lib.swift")
      let outputFileMap = path.appending(component: "output_file_map.json")

      let fileMap = """
{
    \"\(dummyInput.nativePathString(escaped: true))\": {
        \"object\": \"\(basicOutputFileMapObj.nativePathString(escaped: true))\"
    },
    \"\(mainSwift.nativePathString(escaped: true))\": {
        \"object\": \"\(mainObj.nativePathString(escaped: true))\"
    },
    \"\(libSwift.nativePathString(escaped: true))\": {
        \"object\": \"\(libObj.nativePathString(escaped: true))\"
    }
}
"""
      try localFileSystem.writeFileContents(outputFileMap) { $0 <<< fileMap }

      var driver = try Driver(args: ["swiftc", "-driver-print-output-file-map",
                                     "-target", "x86_64-apple-macosx10.9",
                                     "-o", root.appending(component: "basic_output_file_map.out").nativePathString(escaped: false),
                                     "-module-name", "OutputFileMap",
                                     "-output-file-map", outputFileMap.nativePathString(escaped: false)])
      try driver.run(jobs: [])
      let invocationError = try localFileSystem.readFileContents(errorOutputFile).description

      XCTAssertTrue(invocationError.contains("\(libSwift.nativePathString(escaped: false)) -> object: \"\(libObj.nativePathString(escaped: false))\""))
      XCTAssertTrue(invocationError.contains("\(mainSwift.nativePathString(escaped: false)) -> object: \"\(mainObj.nativePathString(escaped: false))\""))
      XCTAssertTrue(invocationError.contains("\(dummyInput.nativePathString(escaped: false)) -> object: \"\(basicOutputFileMapObj.nativePathString(escaped: false))\""))

      // Restore the error stream to what it was
      TSCBasic.stderrStream = errorStream
    }
  }

  func testVerboseImmediateMode() throws {
    #if os(macOS) && arch(arm64)
      try XCTSkipIf(true, "Temporarily disabled on Apple Silicon (rdar://80558898)")
    #endif

// There is nothing particularly macOS-specific about this test other than
// the use of some macOS-specific XCTest functionality to determine the
// test bundle that contains the swift-driver executable.
#if os(macOS)
    try withTemporaryDirectory { path in
      let input = path.appending(component: "ImmediateTest.swift")
      try localFileSystem.writeFileContents(input) { $0 <<< "print(\"Hello, World\")" }
      let binDir = bundleRoot()
      let driver = binDir.appending(component: "swift-driver")
      let args = [driver.description, "--driver-mode=swift", "-v", input.description]
      // Immediate mode takes over the process with `exec` so we need to create
      // a separate process to capture its output here
      let result = try TSCBasic.Process.checkNonZeroExit(
        arguments: args,
        environment: ProcessEnv.vars
      )
      // Make sure the interpret job description was printed
      XCTAssertTrue(result.contains("-frontend -interpret \(input.description)"))
      XCTAssertTrue(result.contains("Hello, World"))
    }
#endif
  }

  func testDiagnosticOptions() throws {
    do {
      var driver = try Driver(args: ["swift", "-no-warnings-as-errors", "-warnings-as-errors", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-warnings-as-errors")))
    }

    do {
      var driver = try Driver(args: ["swift", "-warnings-as-errors", "-no-warnings-as-errors", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-no-warnings-as-errors")))
    }

    do {
      var driver = try Driver(args: ["swift", "-warnings-as-errors", "-no-warnings-as-errors", "-suppress-warnings", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-no-warnings-as-errors")))
      XCTAssertTrue(job.commandLine.contains(.flag("-suppress-warnings")))
    }

    do {
      try assertDriverDiagnostics(args: ["swift", "-no-warnings-as-errors", "-warnings-as-errors", "-suppress-warnings", "foo.swift"]) {
        $1.expect(.error(Driver.Error.conflictingOptions(.warningsAsErrors, .suppressWarnings)))
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-print-educational-notes", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-print-educational-notes")))
    }
  }

  func testNumThreads() throws {
    XCTAssertEqual(try Driver(args: ["swiftc"]).numThreads, 0)

    XCTAssertEqual(try Driver(args: ["swiftc", "-num-threads", "4"]).numThreads, 4)

    XCTAssertEqual(try Driver(args: ["swiftc", "-num-threads", "0"]).numThreads, 0)

    try assertDriverDiagnostics(args: ["swift", "-num-threads", "-1"]) { driver, verify in
      verify.expect(.error("invalid value '-1' in '-num-threads'"))
      XCTAssertEqual(driver.numThreads, 0)
    }

    try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-num-threads", "4") { driver, verify in
      verify.expect(.warning("ignoring -num-threads argument; cannot multithread batch mode"))
      XCTAssertEqual(driver.numThreads, 0)
    }
  }

  func testLTOOption() throws {
    XCTAssertEqual(try Driver(args: ["swiftc"]).lto, nil)

    XCTAssertEqual(try Driver(args: ["swiftc", "-lto=llvm-thin"]).lto, .llvmThin)

    XCTAssertEqual(try Driver(args: ["swiftc", "-lto=llvm-full"]).lto, .llvmFull)

    try assertDriverDiagnostics(args: ["swiftc", "-lto=nop"]) { driver, verify in
      verify.expect(.error("invalid value 'nop' in '-lto=', valid options are: llvm-thin, llvm-full"))
    }
  }

  func testLTOOutputs() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    let targets = ["x86_64-unknown-linux-gnu", "x86_64-apple-macosx10.9"]
    for target in targets {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-thin", "-target", target],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-bc")))
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs.first!.file, "foo.bc"))
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs.first!.file, "foo.bc"))
    }
  }

  func testLTOLibraryArg() throws {
    #if os(macOS)
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-thin", "-target", "x86_64-apple-macos11.0"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertTrue(plannedJobs[1].commandLine.contains("-lto_library"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-thin", "-lto-library", "/foo/libLTO.dylib", "-target", "x86_64-apple-macos11.0"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/foo/libLTO.dylib"))))
      XCTAssertTrue(plannedJobs[1].commandLine.contains("-lto_library"))
      XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/foo/libLTO.dylib"))))
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full", "-target", "x86_64-apple-macos11.0"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertTrue(plannedJobs[1].commandLine.contains("-lto_library"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-full", "-lto-library", "/foo/libLTO.dylib", "-target", "x86_64-apple-macos11.0"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/foo/libLTO.dylib"))))
      XCTAssertTrue(plannedJobs[1].commandLine.contains("-lto_library"))
      XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/foo/libLTO.dylib"))))
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-target", "x86_64-apple-macos11.0"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .link])
      XCTAssertFalse(plannedJobs[1].commandLine.contains("-lto_library"))
    }
    #endif
  }

  func testBCasTopLevelOutput() throws {
    var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-bc", "-target", "x86_64-apple-macosx10.9"])
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 1)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-bc")))
    XCTAssertEqual(plannedJobs[0].outputs.first!.file, VirtualPath.relative(RelativePath("foo.bc")))
  }

  func testScanDependenciesOption() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-scan-dependencies", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-scan-dependencies")))
    }

    // Test .d output
    do {
      var driver = try Driver(args: ["swiftc", "-scan-dependencies",
                                     "-emit-dependencies", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-scan-dependencies")))
      XCTAssertTrue(job.commandLine.contains(.flag("-emit-dependencies-path")))
      XCTAssertTrue(commandContainsTemporaryPath(job.commandLine, "foo.d"))
    }
  }

  func testUserModuleVersion() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-user-module-version", "12.21"])
      guard driver.isFrontendArgSupported(.userModuleVersion) else {
        throw XCTSkip("Skipping: compiler does not support '-user-module-version'")
      }
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
      let emitModuleJob = plannedJobs[0]
      XCTAssertEqual(emitModuleJob.kind, .emitModule)
      XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("-user-module-version")))
      XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("12.21")))
    }
  }

  func testExperimentalPerformanceAnnotations() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-experimental-performance-annotations",
                                     "-emit-sil", "-o", "foo.sil"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let emitModuleJob = plannedJobs[0]
      XCTAssertEqual(emitModuleJob.kind, .compile)
      XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("-experimental-performance-annotations")))
    }
  }

  func testVerifyEmittedInterfaceJob() throws {
    // Evolution enabled
    var envVars = ProcessEnv.vars
    envVars["ENABLE_DEFAULT_INTERFACE_VERIFIER"] = "YES"
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-verify-emitted-module-interface",
                                     "-enable-library-evolution"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      let emitJob = plannedJobs.first(where: { $0.kind == .emitModule })!
      let verifyJob = plannedJobs.first(where: { $0.kind == .verifyModuleInterface })!

      let mergeInterfaceOutputs = emitJob.outputs.filter { $0.type == .swiftInterface }
      XCTAssertTrue(mergeInterfaceOutputs.count == 1,
                    "Merge module job should only have one swiftinterface output")
      XCTAssertTrue(verifyJob.inputs.count == 1)
      XCTAssertTrue(verifyJob.inputs[0] == mergeInterfaceOutputs[0])
      XCTAssertTrue(verifyJob.outputs.isEmpty)
      XCTAssertTrue(verifyJob.commandLine.contains(.path(mergeInterfaceOutputs[0].file)))
    }

    // No Evolution
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface", "-verify-emitted-module-interface"], env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
    }

    // Explicitly disabled
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-no-verify-emitted-module-interface"], env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
    }

    // Disabled by default in merge-module
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-no-emit-module-separately"], env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
    }

    // Disabled when no "ENABLE_DEFAULT_INTERFACE_VERIFIER" found in the environment
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-experimental-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
    }

    // Emit-module separately
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-experimental-emit-module-separately"], env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      let emitJob = plannedJobs.first(where: { $0.kind == .emitModule })!
      let verifyJob = plannedJobs.first(where: { $0.kind == .verifyModuleInterface })!
      let emitInterfaceOutput = emitJob.outputs.filter { $0.type == .swiftInterface }
      XCTAssertTrue(emitInterfaceOutput.count == 1,
                    "Emit module job should only have one swiftinterface output")
      XCTAssertTrue(verifyJob.inputs.count == 1)
      XCTAssertTrue(verifyJob.inputs[0] == emitInterfaceOutput[0])
      XCTAssertTrue(verifyJob.commandLine.contains(.path(emitInterfaceOutput[0].file)))
    }

    // Whole-module
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-whole-module-optimization"], env: envVars)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
      let emitJob = plannedJobs[0]
      let verifyJob = plannedJobs[1]
      XCTAssertEqual(emitJob.kind, .compile)
      let emitInterfaceOutput = emitJob.outputs.filter { $0.type == .swiftInterface }
      XCTAssertTrue(emitInterfaceOutput.count == 1,
                    "Emit module job should only have one swiftinterface output")
      XCTAssertEqual(verifyJob.kind, .verifyModuleInterface)
      XCTAssertTrue(verifyJob.inputs.count == 1)
      XCTAssertTrue(verifyJob.inputs[0] == emitInterfaceOutput[0])
      XCTAssertTrue(verifyJob.commandLine.contains(.path(emitInterfaceOutput[0].file)))
    }

    // Enabled by default when the library-level is api.
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-whole-module-optimization",
                                     "-library-level", "api"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertTrue(plannedJobs.contains() {$0.kind == .verifyModuleInterface})
    }

    // Not enabled by default when the library-level is spi.
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-enable-library-evolution",
                                     "-whole-module-optimization",
                                     "-library-level", "spi"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
    }

    // The flag -check-api-availability-only is not passed down to the verify job.
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-verify-emitted-module-interface",
                                     "-enable-library-evolution",
                                     "-check-api-availability-only"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      let emitJob = plannedJobs.first(where: { $0.kind == .emitModule })!
      XCTAssertTrue(emitJob.commandLine.contains(.flag("-check-api-availability-only")))

      let verifyJob = plannedJobs.first(where: { $0.kind == .verifyModuleInterface })!
      XCTAssertFalse(verifyJob.commandLine.contains(.flag("-check-api-availability-only")))
    }
  }

  func testPCHGeneration() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file.nativePathString(escaped: false), VirtualPath.relative(RelativePath("TestInputHeader.h")).nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(plannedJobs[0].commandLine, "TestInputHeader.pch"))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-import-objc-header")))
      XCTAssertTrue(commandContainsTemporaryPath(plannedJobs[1].commandLine, "TestInputHeader.pch"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-index-store-path", "idx", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-index-store-path")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "idx"))))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(plannedJobs[0].commandLine, "TestInputHeader.pch"))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file.nativePathString(escaped: false), try VirtualPath(path: "/pch/TestInputHeader.pch").nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "-embed-bitcode", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file.nativePathString(escaped: false), try VirtualPath(path: "/pch/TestInputHeader.pch").nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "foo.bc"))

      XCTAssertEqual(plannedJobs[2].kind, .backend)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-whole-module-optimization", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-serialize-diagnostics", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 2)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "TestInputHeader.dia"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .diagnostics)
      XCTAssertEqual(plannedJobs[0].outputs[1].file.nativePathString(escaped: false), try VirtualPath(path: "/pch/TestInputHeader.pch").nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].outputs[1].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
      XCTAssertTrue(commandContainsTemporaryPath(plannedJobs[0].commandLine, "TestInputHeader.dia"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-serialize-diagnostics", "foo.swift", "-emit-module", "-emit-module-path", "/module-path-dir"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 2)
      XCTAssertNotNil(plannedJobs[0].outputs[0].file.name.range(of: #"[\\/]pch[\\/]TestInputHeader-.*.dia"#, options: .regularExpression))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .diagnostics)
      XCTAssertEqual(plannedJobs[0].outputs[1].file.nativePathString(escaped: false), try VirtualPath(path: "/pch/TestInputHeader.pch").nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].outputs[1].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
      XCTAssert(plannedJobs[0].commandLine.contains {
        guard case .path(let path) = $0 else { return false }
        return path.name.range(of: #"[\\/]pch[\\/]TestInputHeader-.*.dia"#, options: .regularExpression) != nil
      })
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .emitModule)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))

      // FIXME: validate that merge module is correct job and that it has correct inputs and flags
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-whole-module-optimization", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file.nativePathString(escaped: false), try VirtualPath(path: "/pch/TestInputHeader.pch").nativePathString(escaped: false))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssertFalse(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-O", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-O")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssertTrue(commandContainsTemporaryPath(plannedJobs[0].commandLine, "TestInputHeader.pch"))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
    }

    // Ensure the merge-module step is not passed the precompiled header
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-import-objc-header", "header.h", "foo.swift", "-no-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("header.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "header.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssertTrue(commandContainsFlagTemporaryPathSequence(plannedJobs[0].commandLine,
                                                             flag: "-o", filename: "header.pch"))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertTrue(commandContainsFlagTemporaryPathSequence(plannedJobs[1].commandLine,
                                                             flag: "-import-objc-header",
                                                             filename: "header.pch"))
      XCTAssertEqual(plannedJobs[2].kind, .mergeModule)
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence:
                                                          ["-import-objc-header",
                                                           .path(.relative(RelativePath("header.h")))]))
    }

    // Immediate mode doesn't generate a pch
    do {
      var driver = try Driver(args: ["swift", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .interpret)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.relative(RelativePath("TestInputHeader.h")))))
    }
  }

  func testPCMGeneration() throws {
     do {
       var driver = try Driver(args: ["swiftc", "-emit-pcm", "module.modulemap", "-module-name", "Test"])
       let plannedJobs = try driver.planBuild()
       XCTAssertEqual(plannedJobs.count, 1)

       XCTAssertEqual(plannedJobs[0].kind, .generatePCM)
       XCTAssertEqual(plannedJobs[0].inputs.count, 1)
       XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("module.modulemap")))
       XCTAssertEqual(plannedJobs[0].outputs.count, 1)
       XCTAssertEqual(plannedJobs[0].outputs[0].file, .relative(RelativePath("Test.pcm")))
    }
  }

  func testPCMDump() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-dump-pcm", "module.pcm"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .dumpPCM)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("module.pcm")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 0)
    }
  }

  func testIndexFilePathHandling() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-index-file", "-index-file-path",
                                     "bar.swift", "foo.swift", "bar.swift", "baz.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(subsequence: [.path(.relative(.init("foo.swift"))),
                                                           "-primary-file",
                                                           .path(.relative(.init("bar.swift"))),
                                                           .path(.relative(.init("baz.swift")))]))
    }
  }

  func testEmbedBitcode() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "embed-bitcode.bc"))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs[0].file, "embed-bitcode.bc"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "embed-bitcode.o"))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("embed-bitcode")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "main.swift", "hi.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 5)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, .relative(RelativePath("hi.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "main.bc"))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs[0].file, "main.bc"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "main.o"))

      XCTAssertEqual(plannedJobs[2].kind, .compile)
      XCTAssertEqual(plannedJobs[2].inputs.count, 2)
      XCTAssertEqual(plannedJobs[2].inputs[0].file, .relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[2].inputs[1].file, .relative(RelativePath("hi.swift")))
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[2].outputs[0].file, "hi.bc"))

      XCTAssertEqual(plannedJobs[3].kind, .backend)
      XCTAssertEqual(plannedJobs[3].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[3].inputs[0].file, "hi.bc"))
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[3].outputs[0].file, "hi.o"))

      XCTAssertEqual(plannedJobs[4].kind, .link)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-emit-module", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs.first(where: {$0.kind == .compile})!
      XCTAssertEqual(compileJob.inputs.count, 1)
      XCTAssertEqual(compileJob.inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(compileJob.outputs.count, 1)
      XCTAssertTrue(matchTemporary(compileJob.outputs[0].file, "embed-bitcode.bc"))

      let backendJob = plannedJobs.first(where: {$0.kind == .backend})!
      XCTAssertEqual(backendJob.inputs.count, 1)
      XCTAssertTrue(matchTemporary(backendJob.inputs[0].file, "embed-bitcode.bc"))
      XCTAssertEqual(backendJob.outputs.count, 1)
      XCTAssertEqual(backendJob.outputs[0].file, .relative(RelativePath("embed-bitcode.o")))

      let emitModuleJob = plannedJobs.first(where: {$0.kind == .emitModule})!
      XCTAssertEqual(emitModuleJob.inputs.count, 1)
      XCTAssertEqual(emitModuleJob.inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(emitModuleJob.outputs[0].file, .relative(RelativePath("main.swiftmodule")))
      XCTAssertEqual(emitModuleJob.outputs[1].file, .relative(RelativePath("main.swiftdoc")))
      XCTAssertEqual(emitModuleJob.outputs[2].file, .relative(RelativePath("main.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(emitModuleJob.outputs[3].file, .relative(RelativePath("main.abi.json")))
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-wmo", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "main.bc"))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs[0].file, "main.bc"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "main.o"))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("embed-bitcode")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-parse-as-library", "-emit-module",  "embed-bitcode.swift", "empty.swift", "-module-name", "ABC"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 5)

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].outputs[0].file, "embed-bitcode.bc"))

      XCTAssertEqual(plannedJobs[2].kind, .backend)
      XCTAssertEqual(plannedJobs[2].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[2].inputs[0].file, "embed-bitcode.bc"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("embed-bitcode.o")))

      XCTAssertEqual(plannedJobs[3].kind, .compile)
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[3].outputs[0].file, "empty.bc"))

      XCTAssertEqual(plannedJobs[4].kind, .backend)
      XCTAssertEqual(plannedJobs[4].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[4].inputs[0].file, "empty.bc"))

      XCTAssertEqual(plannedJobs[4].outputs.count, 1)
      XCTAssertEqual(plannedJobs[4].outputs[0].file, .relative(RelativePath("empty.o")))

      let emitModuleJob = plannedJobs.first(where: { $0.kind == .emitModule })!
      XCTAssertEqual(emitModuleJob.inputs.count, 2)
      XCTAssertEqual(emitModuleJob.inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(emitModuleJob.inputs[1].file, .relative(RelativePath("empty.swift")))
      XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(emitModuleJob.outputs[0].file, .relative(RelativePath("ABC.swiftmodule")))
      XCTAssertEqual(emitModuleJob.outputs[1].file, .relative(RelativePath("ABC.swiftdoc")))
      XCTAssertEqual(emitModuleJob.outputs[2].file, .relative(RelativePath("ABC.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(emitModuleJob.outputs[3].file, .relative(RelativePath("ABC.abi.json")))
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-parse-as-library", "-emit-module", "-whole-module-optimization", "embed-bitcode.swift", "-parse-stdlib", "-module-name", "Swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[0].outputs[0].file, "Swift.bc"))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertTrue(matchTemporary(plannedJobs[1].inputs[0].file, "Swift.bc"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .relative(RelativePath("Swift.o")))

      let emitModuleJob = plannedJobs[2]
      XCTAssertEqual(emitModuleJob.kind, .emitModule)
      XCTAssertEqual(emitModuleJob.inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .relative(RelativePath("Swift.swiftmodule"))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .relative(RelativePath("Swift.swiftdoc"))}).count)
      XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .relative(RelativePath("Swift.swiftsourceinfo"))}).count)
      if driver.targetTriple.isDarwin {
        XCTAssertEqual(1, emitModuleJob.outputs.filter({$0.file == .relative(RelativePath("Swift.abi.json"))}).count)
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-module", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-module-path", "a.swiftmodule",  "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sib", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sibgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sil", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-silgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-ir", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-bc", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-assembly", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-module", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-module-path", "a.swiftmodule",  "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sib", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sibgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sil", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-silgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-ir", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-bc", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-assembly", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }
  }

  func testCXXInteropOptions() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-enable-experimental-cxx-interop", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      let compileJob = plannedJobs[0]
      let linkJob = plannedJobs[1]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-enable-cxx-interop")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(linkJob.commandLine.contains(.flag("-lc++")))
      }
    }
    do {
      var driver = try Driver(args: ["swiftc", "-enable-experimental-cxx-interop",
                                     "-experimental-cxx-stdlib", "libc++", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      let compileJob = plannedJobs[0]
      let linkJob = plannedJobs[1]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-enable-cxx-interop")))
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-stdlib=libc++")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(linkJob.commandLine.contains(.flag("-lc++")))
      }
    }
  }

  func testVFSOverlay() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-c", "-vfsoverlay", "overlay.yaml", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(subsequence: [.flag("-vfsoverlay"), .path(.relative(RelativePath("overlay.yaml")))]))
    }

    // Verify that the overlays are passed to the frontend in the same order.
    do {
      var driver = try Driver(args: ["swiftc", "-c", "-vfsoverlay", "overlay1.yaml", "-vfsoverlay", "overlay2.yaml", "-vfsoverlay", "overlay3.yaml", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(subsequence: [.flag("-vfsoverlay"), .path(.relative(RelativePath("overlay1.yaml"))), .flag("-vfsoverlay"), .path(.relative(RelativePath("overlay2.yaml"))), .flag("-vfsoverlay"), .path(.relative(RelativePath("overlay3.yaml")))]))
    }
  }

  func testSwiftHelpOverride() throws {
    // FIXME: On Linux, we might not have any Clang in the path. We need a
    // better override.
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_SWIFT_HELP_EXEC"] = "/usr/bin/nonexistent-swift-help"
    env["SWIFT_DRIVER_CLANG_EXEC"] = "/usr/bin/clang"
    var driver = try Driver(
      args: ["swiftc", "-help"],
      env: env)
    let jobs = try driver.planBuild()
    XCTAssert(jobs.count == 1)
    XCTAssertEqual(jobs.first!.tool.name, "/usr/bin/nonexistent-swift-help")
  }

  func testSourceInfoFileEmitOption() throws {
    // implicit
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let emitModuleJob = plannedJobs[0]
      XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("-emit-module-source-info-path")))
      XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
      XCTAssertTrue(emitModuleJob.outputs[0].file == VirtualPath.relative(RelativePath("foo.swiftmodule")))
      XCTAssertTrue(emitModuleJob.outputs[1].file == VirtualPath.relative(RelativePath("foo.swiftdoc")))
      XCTAssertTrue(emitModuleJob.outputs[2].file == VirtualPath.relative(RelativePath("foo.swiftsourceinfo")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(emitModuleJob.outputs[3].file == VirtualPath.relative(RelativePath("foo.abi.json")))
      }
    }
    // implicit with Project/ Directory
    do {
      try withTemporaryDirectory { path in
        let projectDirPath = path.appending(component: "Project")
        try localFileSystem.createDirectory(projectDirPath)
        var driver = try Driver(args: ["swiftc", "-emit-module",
                                       path.appending(component: "foo.swift").description,
                                       "-o", path.appending(component: "foo.swiftmodule").description])
        let plannedJobs = try driver.planBuild()
        let emitModuleJob = plannedJobs[0]
        XCTAssertTrue(emitModuleJob.commandLine.contains(.flag("-emit-module-source-info-path")))
        XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 4 : 3)
        XCTAssertEqual(emitModuleJob.outputs[0].file, .absolute(path.appending(component: "foo.swiftmodule")))
        XCTAssertEqual(emitModuleJob.outputs[1].file, .absolute(path.appending(component: "foo.swiftdoc")))
        XCTAssertEqual(emitModuleJob.outputs[2].file, .absolute(projectDirPath.appending(component: "foo.swiftsourceinfo")))
        if driver.targetTriple.isDarwin {
          XCTAssertEqual(emitModuleJob.outputs[3].file, .absolute(path.appending(component: "foo.abi.json")))
        }
      }
    }
    // avoid implicit swiftsourceinfo
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-avoid-emit-module-source-info", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let emitModuleJob = plannedJobs[0]
      XCTAssertFalse(emitModuleJob.commandLine.contains(.flag("-emit-module-source-info-path")))
      XCTAssertEqual(emitModuleJob.outputs.count, driver.targetTriple.isDarwin ? 3 : 2)
      XCTAssertTrue(emitModuleJob.outputs[0].file == VirtualPath.relative(RelativePath("foo.swiftmodule")))
      XCTAssertTrue(emitModuleJob.outputs[1].file == VirtualPath.relative(RelativePath("foo.swiftdoc")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(emitModuleJob.outputs[2].file == VirtualPath.relative(RelativePath("foo.abi.json")))
      }
    }
  }

  func testUseStaticResourceDir() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
      XCTAssertEqual(VirtualPath.lookup(driver.frontendTargetInfo.runtimeResourcePath.path).basename, "swift")
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-no-static-executable", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
      XCTAssertEqual(VirtualPath.lookup(driver.frontendTargetInfo.runtimeResourcePath.path).basename, "swift")
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-no-static-stdlib", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
      XCTAssertEqual(VirtualPath.lookup(driver.frontendTargetInfo.runtimeResourcePath.path).basename, "swift")
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-static-executable", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
      XCTAssertEqual(VirtualPath.lookup(driver.frontendTargetInfo.runtimeResourcePath.path).basename, "swift_static")
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-static-stdlib", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
      XCTAssertEqual(VirtualPath.lookup(driver.frontendTargetInfo.runtimeResourcePath.path).basename, "swift_static")
    }
  }

  func testFrontendTargetInfoWithWorkingDirectory() throws {
    do {
      let workingDirectory =
          try localFileSystem.currentWorkingDirectory.map { AbsolutePath("/absolute/path", relativeTo: $0) }
                  ?? AbsolutePath(validating: "/Foo/Bar")

      var driver = try Driver(args: ["swiftc", "-typecheck", "foo.swift",
                                     "-resource-dir", "resource/dir",
                                     "-sdk", "sdk",
                                     "-working-directory", workingDirectory.pathString])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.path(try VirtualPath(path: rebase("resource", "dir", at: workingDirectory)))))
      XCTAssertFalse(job.commandLine.contains(.path(.relative(.init("resource/dir")))))
      XCTAssertTrue(job.commandLine.contains(.path(try VirtualPath(path: rebase("sdk", at: workingDirectory)))))
      XCTAssertFalse(job.commandLine.contains(.path(.relative(.init("sdk")))))
    }
  }

  func testWarnConcurrency() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-warn-concurrency", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-warn-concurrency")))
    }
  }

  func testLibraryLevel() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-library-level", "spi", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(subsequence: [.flag("-library-level"), .flag("spi")]))
    }
  }

  func testPrebuiltModuleCacheFlags() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    let mockSDKPath: String =
        testInputsPath.appending(component: "mock-sdk.sdk").nativePathString(escaped: false)

    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-ios13.1-macabi", "foo.swift", "-sdk", mockSDKPath],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-prebuilt-module-cache-path")))
      XCTAssertTrue(job.commandLine.contains { arg in
        if case .path(let curPath) = arg {
          if curPath.basename == "10.15" && curPath.parentDirectory.basename == "prebuilt-modules" {
              return true
          }
        }
        return false
      })
    }
  }

  func testRelativeResourceDir() throws {
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-unknown-linux", "-lto=llvm-thin",
                                     "foo.swift",
                                     "-resource-dir", "resource/dir"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      let compileJob = plannedJobs[0]
      XCTAssertEqual(compileJob.kind, .compile)
      XCTAssertTrue(compileJob.commandLine.contains(subsequence: ["-resource-dir", .path(.relative(.init("resource/dir")))]))
      let linkJob = plannedJobs[1]
      XCTAssertEqual(linkJob.kind, .link)
      XCTAssertTrue(linkJob.commandLine.contains(subsequence:
                                              ["-Xlinker", "-rpath",
                                               "-Xlinker", .path(.relative(.init("resource/dir/linux")))]))
      XCTAssertTrue(linkJob.commandLine.contains(.path(.relative(.init("resource/dir/linux/x86_64/swiftrt.o")))))
      XCTAssertTrue(linkJob.commandLine.contains(subsequence:
                                              ["-L", .path(.relative(.init("resource/dir/linux")))]))
    }
  }

  func testSanitizerArgsForTargets() throws {
    let targets = ["x86_64-unknown-freebsd",  "x86_64-unknown-linux", "x86_64-apple-macosx10.9"]
    try targets.forEach {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", $0, "foo.swift"])
      _ = try driver.planBuild()
      XCTAssertFalse(driver.diagnosticEngine.hasErrors)
    }
  }

  func testIsIosMacInterface() throws {
    try withTemporaryFile { file in
      try localFileSystem.writeFileContents(file.path) { $0 <<< "// swift-module-flags: -target x86_64-apple-ios15.0-macabi" }
      XCTAssertTrue(try isIosMacInterface(VirtualPath.absolute(file.path)))
    }
    try withTemporaryFile { file in
      try localFileSystem.writeFileContents(file.path) { $0 <<< "// swift-module-flags: -target arm64e-apple-macos12.0" }
      XCTAssertFalse(try isIosMacInterface(VirtualPath.absolute(file.path)))
    }
  }

  func testSupportedFeatureJson() throws {
    let driver = try Driver(args: ["swiftc", "-emit-module", "foo.swift"])
    XCTAssertFalse(driver.supportedFrontendFeatures.isEmpty)
    XCTAssertTrue(driver.supportedFrontendFeatures.contains("experimental-skip-all-function-bodies"))
  }

  func testFilelist() throws {
    var envVars = ProcessEnv.vars
    envVars["SWIFT_DRIVER_LD_EXEC"] = ld.nativePathString(escaped: false)

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-no-emit-module-separately"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()

      let jobA = plannedJobs[0]
      let flagA = jobA.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentA = jobA.commandLine[jobA.commandLine.index(after: flagA)]
      guard case let .path(.fileList(_, fileListA)) = fileListArgumentA else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapA) = fileListA else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesA = try XCTUnwrap(mapA.entries[VirtualPath.relative(RelativePath("a.swift")).intern()])
      XCTAssertTrue(filesA.keys.contains(.swiftModule))
      XCTAssertTrue(filesA.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesA.keys.contains(.swiftSourceInfoFile))

      let jobB = plannedJobs[1]
      let flagB = jobB.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentB = jobB.commandLine[jobB.commandLine.index(after: flagB)]
      guard case let .path(.fileList(_, fileListB)) = fileListArgumentB else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapB) = fileListB else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesB = try XCTUnwrap(mapB.entries[VirtualPath.relative(RelativePath("b.swift")).intern()])
      XCTAssertTrue(filesB.keys.contains(.swiftModule))
      XCTAssertTrue(filesB.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesB.keys.contains(.swiftSourceInfoFile))

      let jobC = plannedJobs[2]
      let flagC = jobC.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentC = jobC.commandLine[jobC.commandLine.index(after: flagC)]
      guard case let .path(.fileList(_, fileListC)) = fileListArgumentC else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapC) = fileListC else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesC = try XCTUnwrap(mapC.entries[VirtualPath.relative(RelativePath("c.swift")).intern()])
      XCTAssertTrue(filesC.keys.contains(.swiftModule))
      XCTAssertTrue(filesC.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesC.keys.contains(.swiftSourceInfoFile))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(inputs, [.relative(RelativePath("a.swift")), .relative(RelativePath("b.swift")), .relative(RelativePath("c.swift"))])

      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(outputs, [.relative(RelativePath("main.o"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(outputs, [.relative(RelativePath("a.o")), .relative(RelativePath("b.o")), .relative(RelativePath("c.o"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1", "-embed-bitcode"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertTrue(outputs.count == 3)
      XCTAssertTrue(matchTemporary(outputs[0], "a.bc"))
      XCTAssertTrue(matchTemporary(outputs[1], "b.bc"))
      XCTAssertTrue(matchTemporary(outputs[2], "c.bc"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[3]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertTrue(inputs.count == 3)
      XCTAssertTrue(matchTemporary(inputs[0], "a.o"))
      XCTAssertTrue(matchTemporary(inputs[1], "b.o"))
      XCTAssertTrue(matchTemporary(inputs[2], "c.o"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1"],
                              env: envVars)
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[1]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertTrue(inputs.count == 3)
      XCTAssertTrue(matchTemporary(inputs[0], "a.o"))
      XCTAssertTrue(matchTemporary(inputs[1], "b.o"))
      XCTAssertTrue(matchTemporary(inputs[2], "c.o"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "a.swift", "b.swift", "-driver-filelist-threshold=0"])
      let plannedJobs = try driver.planBuild()

      let jobA = plannedJobs[0]
      let flagA = jobA.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentA = jobA.commandLine[jobA.commandLine.index(after: flagA)]
      guard case let .path(.fileList(_, fileListA)) = fileListArgumentA else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapA) = fileListA else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      XCTAssertEqual(mapA.entries, [VirtualPath.relative(.init("a.swift")).intern(): [:]])

      let jobB = plannedJobs[1]
      let flagB = jobB.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentB = jobB.commandLine[jobB.commandLine.index(after: flagB)]
      guard case let .path(.fileList(_, fileListB)) = fileListArgumentB else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapB) = fileListB else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      XCTAssertEqual(mapB.entries, [VirtualPath.relative(.init("b.swift")).intern(): [:]])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-wmo", "a.swift", "b.swift", "-driver-filelist-threshold=0"])
      let plannedJobs = try driver.planBuild()

      let jobA = plannedJobs[0]
      let flagA = jobA.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentA = jobA.commandLine[jobA.commandLine.index(after: flagA)]
      guard case let .path(.fileList(_, fileListA)) = fileListArgumentA else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapA) = fileListA else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      XCTAssertEqual(mapA.entries, [VirtualPath.relative(.init("a.swift")).intern(): [:]])
    }
  }
  
  func testCleaningUpOldCompilationOutputs() throws {
#if !os(macOS)
    throw XCTSkip("sdkArguments does not work on Linux")
#else
    // Build something, create an error, see if the .o and .swiftdeps files get cleaned up
    try withTemporaryDirectory { tmpDir in
      let main = tmpDir.appending(component: "main.swift")
      let ofm = tmpDir.appending(component: "ofm")
      OutputFileMapCreator.write(module: "mod",
                                 inputPaths: [main],
                                 derivedData: tmpDir,
                                 to: ofm)
      
      try localFileSystem.writeFileContents(main) {
        $0 <<< "// no errors here"
        $0 <<< "func foo() {}"
      }
      /// return true if no error
      func doBuild() throws -> Bool {
        let sdkArguments = try XCTUnwrap(try Driver.sdkArgumentsForTesting())
        var driver = try Driver(args: ["swiftc",
                                       "-working-directory", tmpDir.nativePathString(escaped: true),
                                       "-module-name", "mod",
                                       "-c",
                                       "-incremental",
                                       "-output-file-map", ofm.nativePathString(escaped: true),
                                       main.nativePathString(escaped: true)] + sdkArguments,
                                env: ProcessEnv.vars)
        let jobs = try driver.planBuild()
        do {try driver.run(jobs: jobs)}
        catch {return false}
        return true
      }
      XCTAssertTrue(try doBuild())

      let outputs = [
        tmpDir.appending(component: "main.o"),
        tmpDir.appending(component: "main.swiftdeps")
        ]
      XCTAssert(outputs.allSatisfy(localFileSystem.exists))
      
      try localFileSystem.writeFileContents(main) {
        $0 <<< "#error(\"Yipes!\")"
        $0 <<< "func foo() {}"
      }
      XCTAssertFalse(try doBuild())
      XCTAssert(outputs.allSatisfy {!localFileSystem.exists($0)})
    }
#endif
  }
}

func assertString(
  _ haystack: String, contains needle: String, _ message: String = "",
  file: StaticString = #file, line: UInt = #line
) {
  XCTAssertTrue(haystack.contains(needle), """
                \(String(reflecting: needle)) not found in \
                \(String(reflecting: haystack))\
                \(message.isEmpty ? "" : ": " + message)
                """, file: file, line: line)
}

extension Array where Element: Equatable {
  /// Returns true if the receiver contains the given elements as a subsequence
  /// (i.e., all elements are present, contiguous, and in the same order).
  ///
  /// A naïve implementation has been used here rather than a more efficient
  /// general purpose substring search algorithm since the arrays being tested
  /// are relatively small.
  func contains<Elements: Collection>(
    subsequence: Elements
  ) -> Bool
  where Elements.Element == Element
  {
    precondition(!subsequence.isEmpty,  "Subsequence may not be empty")

    let subsequenceCount = subsequence.count
    for index in 0...(self.count - subsequence.count) {
      let subsequenceEnd = index + subsequenceCount
      if self[index..<subsequenceEnd].elementsEqual(subsequence) {
        return true
      }
    }
    return false
  }
}

extension Array where Element == Job {
  // Utility to drop autolink-extract jobs, which helps avoid introducing
  // platform-specific conditionals in tests unrelated to autolinking.
  func removingAutolinkExtractJobs() -> Self {
    var filtered = self
    filtered.removeAll(where: { $0.kind == .autolinkExtract })
    return filtered
  }
}

private extension Array where Element == Job.ArgTemplate {
  func containsPathWithBasename(_ basename: String) -> Bool {
    contains {
      switch $0 {
      case let .path(path):
        return path.basename == basename
      case .flag, .responseFilePath, .joinedOptionAndPath, .squashedArgumentList:
        return false
      }
    }
  }
}
