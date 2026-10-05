// The external scanners of the JavaScript, Lua, Python and YAML grammars. Their packages add
// scanner.c only when `fileExists("src/scanner.c")` holds for the working directory SwiftPM
// evaluates manifests in, which isn't the package's, so the scanners are compiled here.
