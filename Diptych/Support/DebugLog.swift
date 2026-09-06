import AppKit
func dlog(_ s: String) {
    let u = URL(fileURLWithPath: "/tmp/diptych-dbg.log")
    let line = "DBG \(s)\n"
    if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: u, atomically: true, encoding: .utf8) }
}
@MainActor
enum WidthProbe {
    nonisolated(unsafe) static var done = false
    static func run(_ model: AppModel) {
        guard !done else { return }
        done = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            NSApp.activate(ignoringOtherApps: true)
            model.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            guard let w = model.window, let cv = w.contentView else { return }

            func tables(_ v: NSView) -> [NSTableView] {
                if let t = v as? NSTableView { return [t] }
                return ((v.subviews as NSArray).copy() as? [NSView] ?? []).flatMap(tables)
            }
            let ts = tables(cv)
            guard let t = ts.first, let header = t.headerView, t.tableColumns.count > 1 else {
                dlog("no table/header"); return }
            dlog("widths BEFORE: \(t.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" })")
            dlog("key=\(w.isKeyWindow) active=\(NSApp.isActive)")
            try? await Task.sleep(for: .seconds(1))
            let cfg = (try? String(contentsOf: ConfigStore.url, encoding: .utf8)) ?? "<none>"
            dlog("config.json now: \(cfg.replacingOccurrences(of: "\n", with: " "))")
        }
    }
}
