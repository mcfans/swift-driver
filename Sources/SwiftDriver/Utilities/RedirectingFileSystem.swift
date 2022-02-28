import TSCBasic
@_implementationOnly import Yams

@_spi(Testing)
public class RedirectingFileSystem: FileSystem {

  private let overlay: RedirectingFileSystemOverlay
  private let fs: FileSystem
  private let externalContentsPrefixDir: AbsolutePath?

  var overlayRelative: Bool {
    self.overlay.overlayRelative ?? false
  }

  var useExternalNames: Bool {
    self.overlay.useExternalNames ?? true
  }

  @_spi(Testing)
  public init(yamlFilePath: VirtualPath, fs: FileSystem = localFileSystem) throws {
    let yamlContent = try fs.readFileContents(yamlFilePath)
    let decoder = YAMLDecoder()
    self.fs = fs
    let prefixDir: AbsolutePath?
    if case let .absolute(path) = yamlFilePath {
      prefixDir = path
    } else if let workingDir = fs.currentWorkingDirectory {
      prefixDir = yamlFilePath.parentDirectory.resolvedRelativePath(base: workingDir).absolutePath
    } else {
      prefixDir = nil
    }
    self.externalContentsPrefixDir = prefixDir
    self.overlay = try yamlContent.withData { data in
      try decoder.decode(RedirectingFileSystemOverlay.self, from: data)
    }
  }

  private func lookup(at path: AbsolutePath) -> RedirectingFileSystemEntry? {
    for content in overlay.roots {
      // FIXME: Roots might be relative.
      let rootPath = AbsolutePath(content.name)
      if let entry = content.lookup(path: path, in: rootPath) {
        return entry
      }
    }
    return nil
  }

  private func getRealPath(for entry: RedirectingFileSystemEntry) -> AbsolutePath? {
    switch entry.type {
    case .file:
      let filePathString: String
      if entry.useExternalName ?? self.useExternalNames {
        guard case let .externalContents(externalContent) = entry.contents else {
          return nil
        }
        filePathString = externalContent
      } else {
        filePathString = entry.name
      }
      let filePath: AbsolutePath
      if self.overlayRelative, let externalContentsPrefixDir = externalContentsPrefixDir {
        filePath = externalContentsPrefixDir.appending(RelativePath(filePathString))
      } else {
        filePath = AbsolutePath(filePathString)
      }
      return filePath
    case .directory:
      return nil
    }
  }

  public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {

  }

  public func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
    if let entry = lookup(at: path), let path = getRealPath(for: entry) {
      return fs.exists(path, followSymlink: followSymlink)
    }
    return false
  }

  public func isDirectory(_ path: AbsolutePath) -> Bool {
    if let entry = lookup(at: path) {
      return entry.type == .directory
    }
    return false
  }

  public func isFile(_ path: AbsolutePath) -> Bool {
    if let entry = lookup(at: path) {
      return entry.type == .file
    }
    return false
  }

  public func isExecutableFile(_ path: AbsolutePath) -> Bool {
    if let entry = lookup(at: path), let realPath = getRealPath(for: entry) {
      return fs.isExecutableFile(realPath)
    }
    return false
  }

  public func isSymlink(_ path: AbsolutePath) -> Bool {
    if let entry = lookup(at: path), let realPath = getRealPath(for: entry) {
      return fs.isSymlink(realPath)
    }
    return false
  }

  public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
    if let entry = lookup(at: path), let realPath = getRealPath(for: entry) {
      return try fs.getDirectoryContents(realPath)
    }
    return []
  }

  public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
    if let entry = lookup(at: path), let realPath = getRealPath(for: entry) {
      return try fs.readFileContents(realPath)
    }
    throw TSCBasic.FileSystemError.init(.noEntry, path)
  }

  public var currentWorkingDirectory: AbsolutePath?

  public func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
  }

  public var homeDirectory: AbsolutePath {
    .root
  }

  public var cachesDirectory: AbsolutePath?

  public func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {

  }

  public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {

  }

  public func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {

  }

  public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
    throw TSCBasic.FileSystemError.init(.unsupported, path)
  }

  public func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
    throw TSCBasic.FileSystemError.init(.unsupported, path)
  }

  public func removeFileTree(_ path: AbsolutePath) throws {
    throw TSCBasic.FileSystemError.init(.unsupported, path)
  }
}

@_spi(Testing)
public class OverlayFileSystem: FileSystem {
  public func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
    try localFileSystem.chmod(mode, path: path, options: options)
  }

  public func removeFileTree(_ path: AbsolutePath) throws {
    try localFileSystem.removeFileTree(path)
  }

  public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
    try localFileSystem.writeFileContents(path, bytes: bytes)
  }

  public func writeFileContents(_ path: AbsolutePath, bytes: ByteString, atomically: Bool) throws {
    try localFileSystem.writeFileContents(path, bytes: bytes, atomically: atomically)
  }

  func fsContains(path: AbsolutePath) -> FileSystem? {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return fs
      }
    }
    return nil
  }

  public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
    if let fs = fsContains(path: path) {
      return try fs.readFileContents(path)
    }
    throw TSCBasic.FileSystemError.init(.noEntry, path)
  }

  public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
    try localFileSystem.createDirectory(path, recursive: recursive)
  }

  public func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: followSymlink) {
        return true
      }
    }
    return false
  }

  var localFileSystem: FileSystem {
    fsList.first!
  }

  public func isDirectory(_ path: AbsolutePath) -> Bool {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return fs.isDirectory(path)
      }
    }
    return false
  }

  public func isFile(_ path: AbsolutePath) -> Bool {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return fs.isFile(path)
      }
    }
    return false
  }

  public func isExecutableFile(_ path: AbsolutePath) -> Bool {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return fs.isExecutableFile(path)
      }
    }
    return false
  }

  public func isSymlink(_ path: AbsolutePath) -> Bool {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return fs.isSymlink(path)
      }
    }
    return false
  }

  public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
    for fs in fsList.reversed() {
      if fs.exists(path, followSymlink: true) {
        return try fs.getDirectoryContents(path)
      }
    }
    throw TSCBasic.FileSystemError.init(.noEntry, path)
  }

  public var currentWorkingDirectory: AbsolutePath? {
    fsList.first?.currentWorkingDirectory
  }

  public func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
    try fsList.first?.changeCurrentWorkingDirectory(to: path)
  }

  public var homeDirectory: AbsolutePath {
    fsList.first!.homeDirectory
  }

  public var cachesDirectory: AbsolutePath? {
    fsList.first!.cachesDirectory
  }

  public func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {
    try fsList.first!.createSymbolicLink(path, pointingAt: destination, relative: relative)
  }

  public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
    try fsList.first!.copy(from: sourcePath, to: destinationPath)
  }

  public func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
    try fsList.first!.move(from: sourcePath, to: destinationPath)
  }

  var fsList: [FileSystem] = []

  @_spi(Testing)
  public init(fsList: [FileSystem]) {
    self.fsList = fsList
  }

  func addOverlay(fs: FileSystem) {
    fsList.append(fs)
  }
}

private struct RedirectingFileSystemOverlay: Codable {
  let caseSensitive: Bool?
  let useExternalNames: Bool?
  let overlayRelative: Bool?
  let `fallthrough`: Bool?
  let redirectingWith: Bool?
  let version: Int
  let roots: [RedirectingFileSystemEntry]

  enum CodingKeys: String, CodingKey {
    case caseSensitive = "case-sensitive"
    case useExternalNames = "use-external-names"
    case overlayRelative = "overlay-relative"
    case `fallthrough`
    case redirectingWith = "redirecting-with"
    case version
    case roots
  }
}

private enum RedirectingFileSystemEntryType: String, Codable {
  case file
  case directory
}

private struct RedirectingFileSystemEntry: Codable {
  let name: String
  let type: RedirectingFileSystemEntryType
  let useExternalName: Bool?
  let contents: RedirectingFileSystemEntryContents

  enum CodingKeys: String, CodingKey {
    case name
    case type
    case useExternalName = "use-external-name"
    case contents = "contents"
    case externalContents = "external-contents"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    type = try container.decode(RedirectingFileSystemEntryType.self, forKey: .type)
    useExternalName = try container.decodeIfPresent(Bool.self, forKey: .useExternalName)
    switch type {
    case .file:
      let content = try container.decode(String.self, forKey: .externalContents)
      self.contents = .externalContents(content)
    case .directory:
      let contents = try container.decode([RedirectingFileSystemEntry].self, forKey: .contents)
      self.contents = .entries(contents)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(useExternalName, forKey: .useExternalName)
    switch self.contents {
    case .externalContents(let content):
      try container.encode(content, forKey: .externalContents)
    case .entries(let entries):
      try container.encode(entries, forKey: .contents)
    }
  }

  func lookup(path: AbsolutePath, in directory: AbsolutePath) -> RedirectingFileSystemEntry? {
    let currentFilePath: AbsolutePath
    if let virtualPath = try? VirtualPath(path: name), case let .absolute(path) = virtualPath {
      currentFilePath = path
    } else {
      currentFilePath = directory.appending(component: name)
    }
    if currentFilePath == path {
      return self
    }
    if type == .file {
      return nil
    } else if type == .directory {
      guard case let .entries(contents) = contents else {
        // This should not happen, we validated yaml file before
        return nil
      }
      if currentFilePath.isAncestorOfOrEqual(to: path) {
        for content in contents {
          if let entry = content.lookup(path: path, in: currentFilePath) {
            return entry
          }
        }
      }
      return nil
    }
    return nil
  }
}

private enum RedirectingFileSystemEntryContents: Codable {
  case externalContents(String)
  case entries([RedirectingFileSystemEntry])

  enum CodingKeys: String, CodingKey {
    case externalContents = "external-contents"
    case entries = "contents"
  }
}
