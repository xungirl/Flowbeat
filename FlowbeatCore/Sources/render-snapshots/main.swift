// 把 iPhone 端的 SwiftUI 视图渲染成 PNG，用于 README 截图。
// 这不是模拟器截图：这台开发机没有装 iOS 模拟器运行时，所以用 macOS 上的 ImageRenderer
// 渲染同一份视图代码（FlowbeatPhoneUI）。iOS 上的系统容器（List、导航栏）不在图里。
//
//   cd FlowbeatCore
//   swift run render-snapshots ../FlowbeatPhone/Resources/sample-session.json ../docs/screenshots

import AppKit
import FlowbeatCore
import FlowbeatPhoneUI
import SwiftUI

@MainActor
func render<V: View>(_ view: V, width: CGFloat, to url: URL, dark: Bool) throws {
    let content = view
        .padding(20)
        .frame(width: width)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: content)
    r.scale = 2
    guard let cg = r.cgImage else { throw NSError(domain: "render", code: 1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(cg.width)×\(cg.height))")
}

@MainActor
func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: render-snapshots <session.json> <out-dir>")
        exit(2)
    }
    let record = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let out = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try render(SessionDetailContent(record: record, isSample: true), width: 393,
               to: out.appendingPathComponent("phone-session-detail.png"), dark: true)
    try render(VStack(alignment: .leading, spacing: 14) {
        Text("Flowbeat").font(.largeTitle.bold())
        SessionRow(record: record, isSample: true)
    }, width: 393, to: out.appendingPathComponent("phone-session-row.png"), dark: true)
}

try MainActor.assumeIsolated { try main() }
