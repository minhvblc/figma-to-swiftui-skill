import Foundation
import SwiftSyntax
import SwiftParser

// figma-audit — SwiftSyntax-based extractor.
//
// Reads a Swift source file (*Screen.swift / *View.swift) and emits structured
// rows describing every visible value (color, font, padding, frame, image,
// text, stack). Output schema documented in
// figma-to-swiftui-skill plan: c2-audit.json schemaVersion=2.
//
// Usage:
//   figma-audit --in <path>  --out <path>         # parse file, write JSON
//   figma-audit --stdin      --out <path>         # parse stdin, write JSON
//   figma-audit --in <path>  --stdout             # parse file, write to stdout
//   figma-audit --self-test                       # parse bundled samples, exit 0/1
//   figma-audit --version                         # print parser version

let parserVersion = "0.3.0"

// MARK: - Args

struct Args {
    var inPath: String?
    var outPath: String?
    var stdin = false
    var stdout = false
    var nodeIdHint: String?
    var existingJSON: String?  // if set, merge into existing audit.json (per-file overwrite)
    var selfTest = false
    var printVersion = false
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--in":            a.inPath  = it.next()
        case "--out":           a.outPath = it.next()
        case "--stdin":         a.stdin   = true
        case "--stdout":        a.stdout  = true
        case "--node-id":       a.nodeIdHint = it.next()
        case "--merge-into":    a.existingJSON = it.next()
        case "--self-test":     a.selfTest = true
        case "--version", "-v": a.printVersion = true
        case "-h", "--help":    printHelp(); exit(0)
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
            printHelp(); exit(64)
        }
    }
    return a
}

func printHelp() {
    let msg = """
    figma-audit \(parserVersion)

    Usage:
      figma-audit --in <path>  --out <path>      Parse file, write JSON
      figma-audit --stdin      --out <path>      Parse stdin, write JSON
      figma-audit --in <path>  --stdout          Parse file, write to stdout
      figma-audit --self-test                    Parse bundled samples, exit 0/1
      figma-audit --version                      Print parser version

    Optional:
      --node-id <id>         Stash nodeId in output (carried for downstream)
      --merge-into <path>    Merge result into existing c2-audit.json
                             (overwrites entry for this file's relpath)
    """
    print(msg)
}

// MARK: - Schema (matches c2-audit.json schemaVersion=2)

struct AuditOutput: Codable {
    let schemaVersion: Int
    var nodeId: String?
    var generatedAt: String
    let parserMode: String
    let parserVersion: String
    var files: [String: AuditFile]
}

struct AuditFile: Codable {
    let sha256: String
    var writeCount: Int
    var lastWriteAt: String
    let unknownModifierCount: Int
    let unknownNodeTypes: [String]
    let totalViewDecls: Int
    let knownModifierCount: Int
    let rows: [AuditRow]
}

struct AuditRow: Codable {
    let id: String
    let line: Int
    let col: Int
    let kind: String        // color|font|padding|spacing|frame|image|text|stack
    let scope: String       // init|modifier|builder|propertyDecl|conditional
    let ownerType: String?
    let literal: String
    let value: AuditValue
    let claim: AuditClaim
    let chain: [String]?
    let branchPath: [String]?
}

struct AuditValue: Codable {
    var form: String        // literal|tokenRef|assetRef|computed|systemNamedAllowed
    // Per-kind optional fields. JSONEncoder emits null when nil; downstream
    // L2 trace script ignores nulls. Keep flat to avoid a JSONValue indirection.
    var name: String?       // tokenRef/assetRef
    var hex: String?        // color literal
    var width: Double?      // frame
    var height: Double?     // frame
    var maxWidth: String?   // frame (".infinity" or numeric as string)
    var maxHeight: String?  // frame (".infinity" or numeric as string)
    var size: Double?       // font
    var weight: String?     // font
    var preset: String?     // font (ikFont preset name)
    var amount: Double?     // padding/spacing
    var edge: String?       // padding edge
    var text: String?       // Text content
    var stackKind: String?  // VStack/HStack/ZStack
    var spacing: Double?    // stack spacing
    var alignment: String?  // stack alignment
    var systemName: String? // Image(systemName:)
    var raw: String?        // fallback when parser can't extract structured
    var textHint: String?   // font/spacing modifier — closest Text("…") literal in same chain (L2 typography-perline lookup key)
    var edges: String?      // safearea row — parsed edges argument (e.g. ".top", ".all")
    var target: String?     // safearea row — closest enclosing constructor name in chain (e.g. "ScrollView", "Color", "VStack")
}

struct AuditClaim: Codable {
    var tokenLookup: String?
    var registryEntry: String?
    var nodeIdHint: String?
    var designContextHint: String?
}

// MARK: - Helpers

func sha256(_ data: Data) -> String {
    // Use CommonCrypto via shell-out fallback — SwiftCrypto would add a dep.
    // Write to tmp, shasum, parse.
    let tmpPath = "/tmp/figma-audit-sha-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max)).bin"
    let tmpURL = URL(fileURLWithPath: tmpPath)
    do {
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let process = Process()
        process.launchPath = "/usr/bin/shasum"
        process.arguments = ["-a", "256", tmpPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: out, encoding: .utf8) {
            let hash = str.split(separator: " ").first.map(String.init) ?? ""
            return hash
        }
    } catch {
        return ""
    }
    return ""
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

func relativeFilePath(_ absPath: String) -> String {
    // Heuristic: chop off any prefix up to the first `Sources/`, `Screens/`, or
    // project root marker. Falls back to basename if no marker found.
    let markers = ["/Sources/", "/Screens/", "/App/", "/Features/"]
    for marker in markers {
        if let range = absPath.range(of: marker) {
            return String(absPath[range.lowerBound...].dropFirst())  // remove leading /
        }
    }
    return (absPath as NSString).lastPathComponent
}

// MARK: - Parse + emit

func parseAndEmit(source: String, filePath: String, nodeId: String?) -> AuditOutput {
    let sourceFile = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: sourceFile)
    let fileBaseName = (filePath as NSString).lastPathComponent

    let visitor = AuditVisitor(converter: converter, fileBaseName: fileBaseName)
    visitor.walk(sourceFile)

    let relPath = relativeFilePath(filePath)
    let data = Data(source.utf8)

    let file = AuditFile(
        sha256: sha256(data),
        writeCount: 1,
        lastWriteAt: isoNow(),
        unknownModifierCount: visitor.unknownModifierCount,
        unknownNodeTypes: Array(visitor.unknownNodeTypes).sorted(),
        totalViewDecls: visitor.totalViewDecls,
        knownModifierCount: visitor.knownModifierCount,
        rows: visitor.rows
    )

    return AuditOutput(
        schemaVersion: 2,
        nodeId: nodeId,
        generatedAt: isoNow(),
        parserMode: "swift-syntax",
        parserVersion: parserVersion,
        files: [relPath: file]
    )
}

// MARK: - Merge

func mergeOutputs(existing: AuditOutput, new: AuditOutput) -> AuditOutput {
    var merged = existing
    merged.generatedAt = new.generatedAt
    if let nid = new.nodeId, !nid.isEmpty {
        merged.nodeId = nid
    }
    for (path, newFile) in new.files {
        if var prior = merged.files[path] {
            // Increment writeCount, overwrite rows + counts (fresh parse wins)
            var fresh = newFile
            fresh.writeCount = prior.writeCount + 1
            fresh.lastWriteAt = newFile.lastWriteAt
            merged.files[path] = fresh
            _ = prior  // silence unused warning
        } else {
            merged.files[path] = newFile
        }
    }
    return merged
}

// MARK: - IO

func readExisting(_ path: String) -> AuditOutput? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return nil
    }
    let decoder = JSONDecoder()
    return try? decoder.decode(AuditOutput.self, from: data)
}

func encode(_ output: AuditOutput) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(output)
}

func writeOutput(_ output: AuditOutput, to path: String) throws {
    var data = try encode(output)
    data.append(0x0A)  // trailing newline (matches Python convention)
    // Atomic write: tmp + rename.
    let dir = (path as NSString).deletingLastPathComponent
    if !FileManager.default.fileExists(atPath: dir) {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let tmpPath = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    try data.write(to: URL(fileURLWithPath: tmpPath))
    _ = try? FileManager.default.removeItem(atPath: path)
    try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
}

// MARK: - Self-test

let selfTestSamples: [(name: String, source: String, mustContainKinds: [String])] = [
    (
        name: "Simple screen with color + image",
        source: """
        import SwiftUI
        struct LoginScreen: View {
            var body: some View {
                VStack(spacing: 16) {
                    Image(.icAILogo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                    Text("Welcome")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .padding(.top, 24)
                }
            }
        }
        """,
        mustContainKinds: ["stack", "image", "text", "frame", "font", "color", "padding"]
    ),
    (
        name: "Subview with ikFont",
        source: """
        import SwiftUI
        struct LoginFormView: View {
            var body: some View {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "envelope.fill")
                    Text("Email")
                        .ikFont(.bodySemi)
                        .foregroundColor(.figmaGray400)
                }
                .padding(.horizontal, 16)
            }
        }
        """,
        mustContainKinds: ["stack", "image", "text", "font", "color", "padding"]
    ),
    (
        name: "Safe area + typography per-line",
        source: """
        import SwiftUI
        struct WelcomeScreen: View {
            var body: some View {
                ZStack {
                    Color(.appBackground)
                        .ignoresSafeArea(edges: .top)
                    VStack(spacing: 24) {
                        Text("Welcome back")
                            .font(.system(size: 28, weight: .bold))
                            .lineSpacing(8)
                            .tracking(-0.2)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button("Continue") { }
                }
            }
        }
        """,
        // Row coverage check: must include safearea (.ignoresSafeArea +
        // .safeAreaInset) and text/font (so we know textHint linking has data).
        mustContainKinds: ["stack", "text", "font", "color", "safearea"]
    ),
    (
        name: "Nav bar visibility modifiers",
        source: """
        import SwiftUI
        struct ProfileScreen: View {
            var body: some View {
                NavigationStack {
                    VStack {
                        Text("Your Profile")
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        """,
        mustContainKinds: ["stack", "text", "navbar"]
    ),
]

func runSelfTest() -> Int32 {
    var failures = 0
    for (idx, sample) in selfTestSamples.enumerated() {
        let output = parseAndEmit(source: sample.source, filePath: "/tmp/sample-\(idx).swift", nodeId: nil)
        guard let file = output.files.values.first else {
            print("FAIL [\(sample.name)]: no file emitted")
            failures += 1
            continue
        }
        let kinds = Set(file.rows.map { $0.kind })
        let missing = sample.mustContainKinds.filter { !kinds.contains($0) }
        if missing.isEmpty {
            print("PASS [\(sample.name)] — \(file.rows.count) rows, kinds: \(kinds.sorted().joined(separator: ","))")
        } else {
            print("FAIL [\(sample.name)] — missing kinds: \(missing.joined(separator: ","))  (got: \(kinds.sorted().joined(separator: ",")))")
            failures += 1
        }
    }
    return failures == 0 ? 0 : 1
}

// MARK: - Main

let args = parseArgs()

if args.printVersion {
    print(parserVersion)
    exit(0)
}

if args.selfTest {
    exit(runSelfTest())
}

// Read source
let source: String
let filePath: String

if args.stdin {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    source = String(data: data, encoding: .utf8) ?? ""
    filePath = args.inPath ?? "<stdin>"
} else if let path = args.inPath {
    guard let data = FileManager.default.contents(atPath: path),
          let s = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("FAIL: cannot read \(path)\n".utf8))
        exit(65)
    }
    source = s
    filePath = path
} else {
    FileHandle.standardError.write(Data("FAIL: need --in <path> or --stdin\n".utf8))
    exit(64)
}

// Parse + emit
let parsed = parseAndEmit(source: source, filePath: filePath, nodeId: args.nodeIdHint)

// Merge into existing if requested
let final: AuditOutput
if let existingPath = args.existingJSON, let existing = readExisting(existingPath) {
    final = mergeOutputs(existing: existing, new: parsed)
} else {
    final = parsed
}

// Write
if args.stdout {
    do {
        var data = try encode(final)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    } catch {
        FileHandle.standardError.write(Data("FAIL: encode error: \(error)\n".utf8))
        exit(1)
    }
} else if let outPath = args.outPath {
    do {
        try writeOutput(final, to: outPath)
    } catch {
        FileHandle.standardError.write(Data("FAIL: write error: \(error)\n".utf8))
        exit(1)
    }
} else {
    FileHandle.standardError.write(Data("FAIL: need --out <path> or --stdout\n".utf8))
    exit(64)
}

exit(0)
