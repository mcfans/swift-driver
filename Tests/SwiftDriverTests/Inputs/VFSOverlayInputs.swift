enum VFSOverlayInputs {
  static func overlayContent(relativeToOverlay: Bool = true, rootDir: String, pathMap: [(String, String)]) -> String {
    let contents = pathMap.map { (name, externalContents) -> String in
"""
{
  "name": \(name),
  "type": "file",
  "external-contents": \(externalContents)
}
"""
    }
    return
"""
{
  "case-sensitive": true,
  "overlay-relative": \(relativeToOverlay),
  "roots": [
{
  "name": \(rootDir),
  "type": "directory",
  "contents": [\(contents.joined(separator: ","))]
}
],
  "use-external-names": true,
  "version": 0,
}
"""
    }
}
