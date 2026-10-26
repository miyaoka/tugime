// 配布物に含める依存とデータの利用条件を 1 つのファイルにまとめる。
// 使い方: swift collect-notices.swift <パッケージのディレクトリ> <.app の Contents/Resources> <書き出すファイル>
//
// 依存は SwiftPM の show-dependencies で列挙し、各パッケージにある利用条件のファイル（LICENSE・COPYING・NOTICE）を写す。
// 利用条件が LICENSE に書かれていないデータは、App/Notices の出典のファイルを写す。出典のファイルの 1 行目は、
// Contents/Resources から見たそのデータの場所で、.app に無ければ失敗する（データが外れたのに出典だけ残るのを防ぐ）。
// .app に入る *.bundle ごとに、そのパッケージの利用条件を写したかを確かめ、無ければ失敗する。
// bundle の中に、パッケージの LICENSE とは別の利用条件のデータが増えたことは検出できない
import Foundation

struct Dependency: Decodable {
    var identity: String
    var name: String
    var url: String
    var version: String
    var path: String
    var dependencies: [Dependency]
}

struct Resolved: Decodable {
    struct Pin: Decodable {
        struct State: Decodable { var revision: String }
        var identity: String
        var state: State
    }
    var pins: [Pin]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("collect-notices: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard args.count == 3 else { fail("引数は <パッケージのディレクトリ> <Contents/Resources> <書き出すファイル>") }
let packageDir = URL(fileURLWithPath: args[args.startIndex])
let resources = URL(fileURLWithPath: args[args.startIndex + 1])
let output = URL(fileURLWithPath: args[args.startIndex + 2])
let fileManager = FileManager.default

func showDependencies() -> Dependency {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "--package-path", packageDir.path, "show-dependencies", "--format", "json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("swift package show-dependencies を起動できない: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("swift package show-dependencies が失敗した") }
    do { return try JSONDecoder().decode(Dependency.self, from: data) } catch { fail("show-dependencies の出力を読めない: \(error)") }
}

/// 依存の木を identity で重複を除いて平らにする
func flatten(_ root: Dependency) -> [Dependency] {
    var seen: Set<String> = []
    var result: [Dependency] = []
    func walk(_ node: Dependency) {
        for child in node.dependencies where seen.insert(child.identity).inserted {
            result.append(child)
            walk(child)
        }
    }
    walk(root)
    return result.sorted { $0.identity < $1.identity }
}

/// 利用条件のファイルの名前。Apache-2.0 は NOTICE があればその写しも求める
func isLicenseFile(_ name: String) -> Bool {
    let upper = name.uppercased()
    return ["LICENSE", "COPYING", "NOTICE"].contains { upper == $0 || upper.hasPrefix("\($0).") }
}

/// パッケージの中の利用条件のファイル。同梱するデータが別のリポジトリ（submodule）の場合があるので、下の階層も探す
func licenseFiles(in directory: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
        if url.lastPathComponent == ".git" {
            enumerator.skipDescendants()
            continue
        }
        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if isFile, isLicenseFile(url.lastPathComponent) { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
}

func read(_ url: URL) -> String {
    do { return try String(contentsOf: url, encoding: .utf8) } catch { fail("\(url.path) を読めない: \(error)") }
}

let root = showDependencies()
let dependencies = flatten(root)
// 依存が無ければ SwiftPM は Package.resolved を作らない
let revisions: [String: String] = dependencies.isEmpty ? [:] : {
    let url = packageDir.appendingPathComponent("Package.resolved")
    do {
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: resolved.pins.map { ($0.identity, $0.state.revision) })
    } catch { fail("\(url.path) を読めない: \(error)") }
}()

var sections: [(title: String, body: String)] = []
var coveredPackages: Set<String> = [root.name]
for dependency in dependencies {
    let directory = URL(fileURLWithPath: dependency.path)
    let files = licenseFiles(in: directory)
    guard !files.isEmpty else { fail("\(dependency.url) に利用条件のファイルが無い") }
    guard let revision = revisions[dependency.identity] else { fail("Package.resolved に \(dependency.identity) が無い") }
    let version = dependency.version == "unspecified" ? revision : "\(dependency.version)（\(revision)）"
    for file in files {
        let relative = String(file.path.dropFirst(directory.path.count + 1))
        sections.append(("\(dependency.url) \(version) の \(relative)", read(file)))
    }
    coveredPackages.insert(dependency.name)
}

let noticesDir = packageDir.appendingPathComponent("App/Notices")
let dataNotices: [URL]
do {
    dataNotices = try fileManager.contentsOfDirectory(at: noticesDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "txt" }
        .sorted { $0.path < $1.path }
} catch { fail("\(noticesDir.path) を読めない: \(error)") }
for notice in dataNotices {
    let lines = read(notice).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let target = String(lines[0])
    guard fileManager.fileExists(atPath: resources.appendingPathComponent(target).path) else {
        fail("\(notice.lastPathComponent) の対象 \(target) が .app に無い")
    }
    sections.append((target, lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""))
}

// SwiftPM はリソースを「パッケージ名_ターゲット名.bundle」に入れる。どの bundle も、利用条件を写したパッケージか tugime のものであること
let bundles: [String]
do {
    bundles = try fileManager.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".bundle") }.sorted()
} catch { fail("\(resources.path) を読めない: \(error)") }
for bundle in bundles {
    guard coveredPackages.contains(where: { bundle.hasPrefix("\($0)_") }) else {
        fail("\(bundle) がどのパッケージのものか分からず、利用条件を写せない")
    }
}

var text = "tugime は次のソフトウェアとデータを含む。\n"
for section in sections {
    text += "\n==== \(section.title) ====\n\n\(section.body)\n"
}
do { try text.write(to: output, atomically: true, encoding: .utf8) } catch { fail("\(output.path) に書けない: \(error)") }
print("== 利用条件 \(sections.count) 件（パッケージ \(dependencies.count) 件、bundle \(bundles.count) 件を確認）\(output.path)")
