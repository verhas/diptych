import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar preview, the way Finder does it.
///
/// `QLPreviewPanel` is a shared, app-wide floating panel. It normally finds its
/// controller by walking the responder chain for something that answers
/// `acceptsPreviewPanelControl` -- machinery SwiftUI gives us no hook into, so
/// this assigns itself as the panel's data source directly instead.
@MainActor
final class QuickLookController: NSObject {

    static let shared = QuickLookController()

    private var items: [URL] = []

    /// The model whose pane the panel is previewing, so arrow keys that land on
    /// the panel can be pushed back into the file list.
    private(set) weak var owner: AppModel?
    /// The files the panel was last given: a change to the same list is no change.
    private var shownURLs: [URL] = []

    /// Space toggles: a second press closes the panel, as in Finder.
    /// `owner` is nil for a window with no pane behind it -- the EXIF
    /// editor's list of images -- whose arrow keys the panel keeps.
    func toggle(_ urls: [URL], owner: AppModel?) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if isVisible {
            close()
            return
        }
        guard !urls.isEmpty else { return }

        // One folder: Diptych's own panel, a tree of what is in it.
        if urls.count == 1, FolderPreview.shows(urls[0]) {
            self.owner = owner
            shownURLs = urls
            JournalViewing.previewing(urls)
            FolderPreview.shared.show(urls[0], owner: owner, pane: owner?.active)
            return
        }

        items = urls.map(previewable)
        shownURLs = urls
        JournalViewing.previewing(urls)
        self.owner = owner
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()

        // orderFront rather than makeKeyAndOrderFront -- though measurement
        // shows QLPreviewPanel makes itself key either way, so this alone does
        // not keep focus in the file list. What actually preserves Finder's
        // behaviour is previewPanel(_:handle:) below, which pushes the panel's
        // arrow keys back into the pane. Our window's first responder stays the
        // table throughout, so focus returns to it when the panel closes.
        panel.orderFront(nil)
        keepAbove(panel)

        // The panel takes the keyboard, as a preview panel does: it closes
        // when it stops being key, so it cannot be persuaded to float.
        // `previewPanel(_:handle:)` pushes its arrow keys back into the pane.
    }

    /// Finder's preview floats: rename the file in the window behind it and
    /// the preview stays in view, even over a window it half covers. A shared
    /// QLPreviewPanel sits at the normal window level when its controller is
    /// not found through the responder chain, so the window that took the
    /// keyboard back for a rename covered it. Floating, it stays on top.
    private func keepAbove(_ panel: QLPreviewPanel) {
        panel.level = .floating
    }

    /// Gives the keyboard back to a browser window -- for a rename or a value
    /// edit typed in its rows -- and leaves the panel where it is, in front.
    /// `makeKey`, not `makeKeyAndOrderFront`: bringing the window forward is
    /// what buried the preview.
    func yieldKey(to window: NSWindow?) {
        guard isVisible, let window else { return }
        keepAbove(QLPreviewPanel.shared())
        window.makeKey()
    }

    /// Quick Look's panel, or the folder preview standing in for it.
    var isVisible: Bool { panelIsVisible || FolderPreview.shared.isVisible }

    private var panelIsVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func close() {
        guard isVisible else { return }
        FolderPreview.shared.close()
        if panelIsVisible { QLPreviewPanel.shared().orderOut(nil) }
        shownURLs = []
        JournalViewing.previewClosed()
        clearScratch()
    }

    /// Keep the panel in step while the cursor moves, rather than making the
    /// user close and reopen it.
    ///
    /// Also after the previewed file *goes away* -- trashed, or renamed, which
    /// to Quick Look is the same thing. The panel then dropped to "No items
    /// selected" and stayed there while the pane had already moved the cursor
    /// to the next file: `reloadData` alone does not bring a panel back once
    /// the item it was showing has vanished. Asserting the data source again
    /// and refreshing the *item*, not only the list, does.
    func update(_ urls: [URL], force: Bool = false) {
        guard isVisible, let panel = QLPreviewPanel.shared() else { return }
        // The same files as the panel shows: nothing to redraw. Redrawing on
        // every cursor move made the preview blink, and a long one lose its place.
        // `force` is for files changed in place, which must be read again.
        if !force, urls == shownURLs { return }
        shownURLs = urls
        JournalViewing.previewing(urls)

        // Nothing left to show -- the last file in the folder was just
        // deleted. Closing is honest; a panel reading "No items selected"
        // looks like a fault.
        guard !urls.isEmpty else {
            close()
            return
        }

        // The cursor on a folder: the folder preview, in place of the panel.
        if urls.count == 1, FolderPreview.shows(urls[0]) {
            if panelIsVisible {
                panel.orderOut(nil)
                owner?.window?.makeKey()
            }
            FolderPreview.shared.show(urls[0], owner: owner, pane: owner?.active)
            return
        }

        items = urls.map(previewable)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if FolderPreview.shared.isVisible {
            // From a folder to a file: Quick Look's panel again.
            FolderPreview.shared.close()
            panel.orderFront(nil)
        }
        panel.refreshCurrentPreviewItem()
        keepAbove(panel)
    }

    /// The same files, changed in place -- turned, their location removed:
    /// drawn again rather than from what the panel kept of them.
    func refresh() {
        guard panelIsVisible, let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
    }

    // MARK: - Text fallback

    /// Files whose extension the system does not recognise get no preview at
    /// all -- Quick Look just shows a name and a size. Most of those, in a
    /// developer's home directory, are plain text: .env, .gitconfig, Dockerfile,
    /// a stray config with an invented suffix. If the bytes look like text,
    /// preview a .txt copy so you actually see the contents.
    /// Types Quick Look genuinely renders. "Is a declared type" was the old
    /// test and it was wrong: .cfg is declared as public.toml, which conforms to
    /// public.text but has no generator, so the panel showed a name and a size.
    /// public.toml and com.microsoft.ini conform to none of these -- which is
    /// exactly the distinction that matters.
    private static let renderable: [UTType] = [
        .plainText, .sourceCode, .rtf, .html, .xml, .json, .yaml, .propertyList,
        .image, .pdf, .movie, .audio, .archive, .spreadsheet, .presentation, .font,
    ]

    private func previewable(_ url: URL) -> URL {
        if let rendered = linkReport(for: url) { return rendered }
        if let rendered = bundleReport(for: url) { return rendered }
        if let rendered = packageReport(for: url) { return rendered }
        if let rendered = diskImageReport(for: url) { return rendered }
        if let rendered = mailReport(for: url) { return rendered }
        if let rendered = crashReport(for: url) { return rendered }
        if let rendered = provisioningReport(for: url) { return rendered }
        if let rendered = locationReport(for: url) { return rendered }
        if let rendered = propertiesReport(for: url) { return rendered }
        if let rendered = listingReport(for: url) { return rendered }
        if url.lastPathComponent == ".DS_Store", let rendered = dsStoreReport(for: url) {
            return rendered
        }
        if url.pathExtension.lowercased() == "plist", let rendered = plistReport(for: url) {
            return rendered
        }
        if CertificateReport.handles(url), let rendered = certificateReport(for: url) {
            return rendered
        }
        if KeyStoreReport.extensions.contains(url.pathExtension.lowercased()),
           let rendered = keyStoreReport(for: url) {
            return rendered
        }
        if url.pathExtension.lowercased() == "class", let rendered = classFileReport(for: url) {
            return rendered
        }
        if let rendered = executableReport(for: url) { return rendered }
        if ["tif", "tiff"].contains(url.pathExtension.lowercased()),
           let rendered = oldJPEGTiffReport(for: url) {
            return rendered
        }
        if Self.markdownExtensions.contains(url.pathExtension.lowercased()),
           let rendered = markdownReport(for: url) {
            return rendered
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.isDeclared,
           Self.renderable.contains(where: { type.conforms(to: $0) }) {
            // Quick Look reads plain text as UTF-8 or by its mark, and shows a
            // Latin-2 or Windows-1251 file as nonsense: one that is not is
            // shown from a UTF-8 copy, read as Text Edit reads it.
            guard Self.isPlainTextual(type), let text = reencodedText(at: url) else { return url }
            return scratchText(text, for: url) ?? url
        }
        guard let text = readableText(at: url) else { return url }

        let target = scratch.appendingPathComponent(url.lastPathComponent + ".txt")
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return url
        }
        return target
    }

    /// `.DS_Store` has no Quick Look generator, so the panel shows a name and a
    /// size for a file that is actually full of readable structure: where every
    /// icon sat, how the window was arranged, which columns were showing. Decode
    /// it and preview an HTML rendering instead.
    ///
    /// A failure to parse gets a page of its own rather than falling back to the
    /// empty panel -- "this is not a Bud1 file at all" is worth being told.
    private func dsStoreReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= DSStore.maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        let directory = url.deletingLastPathComponent().path
        let html: String
        do {
            let store = try DSStore(data: data)
            html = DSStoreReport.html(for: store, name: url.lastPathComponent, path: directory)
        } catch {
            html = DSStoreReport.html(failure: error, name: url.lastPathComponent)
        }

        // Named after the folder it describes: several .DS_Store previews in one
        // session would otherwise overwrite each other in the scratch directory.
        let stem = directory.replacingOccurrences(of: "/", with: "_")
        let target = scratch.appendingPathComponent("DS_Store\(stem).html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// A property list as the structure Text Edit's tree shows, rather than
    /// Quick Look's source text -- or, for a binary list, a name and a size.
    private func plistReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= PlistReport.maximumSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let html = PlistReport.html(for: data, name: url.lastPathComponent,
                                    path: url.deletingLastPathComponent().path)
        // The panel's title is the previewed file's name, so the page is named
        // after the plist itself -- in a folder of its own per path, so two
        // Info.plist files do not overwrite each other.
        let folder = scratch.appendingPathComponent(
            "plist" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// Certificates, requests, revocation lists and keys -- PEM, DER, PKCS#7,
    /// SSH -- as what each is for and how they fit together. A `.key` or `.pub`
    /// that holds no key is left to Quick Look: Keynote and Publisher use them.
    private func certificateReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= CertificateFile.maximumSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let html = CertificateReport.html(for: data, url: url) else { return nil }
        let folder = scratch.appendingPathComponent(
            "certificate" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// A key store -- JKS, JCEKS or PKCS#12 -- as its aliases and their
    /// certificates. Only read: no password is asked for, no key decrypted.
    private func keyStoreReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= KeyStore.maximumSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let html = KeyStoreReport.html(for: data, name: url.lastPathComponent,
                                       path: url.deletingLastPathComponent().path)
        let folder = scratch.appendingPathComponent(
            "keystore" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// A Java class file -- a name and a size to Quick Look -- as the outline
    /// of its source: declaration, fields, methods, and the Java release.
    private func classFileReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= ClassFile.maximumSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let html = ClassFileReport.html(for: data, name: url.lastPathComponent,
                                        path: url.deletingLastPathComponent().path)
        // Named after the class file, in a folder of its own per path: two
        // Main.class files in one session do not overwrite each other.
        let folder = scratch.appendingPathComponent(
            "class" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// A Mach-O or ELF binary, a script, or text marked executable -- all a
    /// "Unix executable file" with a name and a size to Quick Look -- as what
    /// it is, what it needs, and whether it would run. The contents decide;
    /// the name only says whether to look: no extension, one binaries use, or
    /// one no application claims (`libc.so.6`).
    private func executableReport(for url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || ExecutableReport.extensions.contains(ext)
                || UTType(filenameExtension: ext)?.isDeclared != true else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let name = url.lastPathComponent, path = url.deletingLastPathComponent().path
        let html: String
        if MachOFile.looksLikeMachO(data) {
            do {
                html = ExecutableReport.html(for: try MachOFile(data: data), name: name, path: path, size: size)
            } catch {
                html = ExecutableReport.html(failure: error, kind: "Mach-O file", name: name, path: path, size: size)
            }
        } else if ELF.looksLikeELF(data) {
            do {
                html = ExecutableReport.html(for: try ELF(data: data), name: name, path: path, size: size)
            } catch {
                html = ExecutableReport.html(failure: error, kind: "ELF file", name: name, path: path, size: size)
            }
        } else if PEFile.looksLikePE(data) {
            do {
                html = ExecutableReport.html(for: try PEFile(data: data), name: name, path: path, size: size)
            } catch {
                html = ExecutableReport.html(failure: error, kind: "Windows program", name: name, path: path, size: size)
            }
        } else if ArArchive.looksLikeArchive(data) {
            do {
                html = ExecutableReport.html(for: try ArArchive(data: data), name: name, path: path, size: size)
            } catch {
                html = ExecutableReport.html(failure: error, kind: "Library", name: name, path: path, size: size)
            }
        } else if ext == "obj", let machine = COFFObject.machine(of: data) {
            html = ExecutableReport.html(objectFile: data, machine: machine, name: name, path: path)
        } else if BatchFile.extensions.contains(ext) {
            guard let text = readableText(at: url) else { return nil }
            html = ExecutableReport.html(for: BatchFile(data: data.prefix(4 * 1024 * 1024), text: text),
                                         name: name, path: path, size: size)
        } else {
            // Text: a script by its #! line, or a plain file only when marked
            // executable, and without an extension that says what it is.
            let executable = FileManager.default.isExecutableFile(atPath: url.path)
            guard Script.startsLikeScript(data) || (executable && ext.isEmpty),
                  let text = readableText(at: url) else { return nil }
            html = ExecutableReport.html(for: Script(data: data.prefix(4096), text: text, executable: executable),
                                         name: name, path: path, size: size)
        }
        let folder = scratch.appendingPathComponent(
            "executable" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    /// A TIFF of old-style JPEG pages, which macOS shows only as a thumbnail:
    /// its pages, taken out of it.
    private func oldJPEGTiffReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= OldJPEGTiff.maximumSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let pages = OldJPEGTiff.pages(of: data) else { return nil }
        let html = OldJPEGTiff.html(for: pages, name: url.lastPathComponent,
                                    path: url.deletingLastPathComponent().path)
        // Named after the TIFF, so the panel's title is its name.
        let folder = scratch.appendingPathComponent(
            "tiff" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// A symbolic link gets a page of its own -- that it is a link, and every
    /// step to where it ends -- rather than a preview of its target, which
    /// made a link look like the file and a broken one like nothing.
    private func linkReport(for url: URL) -> URL? {
        guard let chain = LinkChain.follow(url) else { return nil }
        let html = LinkReport.html(for: chain, name: url.lastPathComponent, path: url.path)
        let target = scratch.appendingPathComponent(
            "link" + url.path.replacingOccurrences(of: "/", with: "_") + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    // MARK: - What is inside

    /// Pages already built, so moving up and down a pane does not read the same
    /// folder again on every keystroke.
    private var listings: [String: URL] = [:]
    /// Bundles whose seal and size are worked out, by path.
    private var bundles: [String: URL] = [:]
    /// Pages finished in the background -- disk images, mailboxes -- by kind and path.
    private var finished: [String: URL] = [:]
    private var reading: Set<String> = []

    /// A folder or an archive, listed.
    ///
    /// Quick Look gives a folder a large blue icon and a size, which answers
    /// none of the question anybody presses Space to ask.
    ///
    /// The page is written *before* anything is read and says "Reading...".
    /// Reading a folder on a sleeping disk, or an archive that must be
    /// decompressed from end to end, takes as long as it takes -- and this is
    /// called while drawing, on the main thread. The listing arrives behind it
    /// and the panel is told to draw again. Nothing waits for a disk.
    private func listingReport(for url: URL) -> URL? {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        // A package is a folder, but somebody pressing Space on one means the
        // application, not its contents.
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        let kind: ListingReport.Kind
        if isFolder, !isPackage { kind = .folder }
        else if !isFolder, Listing.isArchive(url) { kind = .archive }
        else { return nil }

        if let ready = listings[url.path] { return ready }

        let target = scratch.appendingPathComponent(
            "listing" + url.path.replacingOccurrences(of: "/", with: "_") + ".html")
        write(ListingReport.html(for: Listing.Result(), name: url.lastPathComponent,
                                 path: url.path, kind: kind, stillReading: true),
              to: target)
        fetchListing(for: url, kind: kind, into: target)
        return target
    }

    private func fetchListing(for url: URL, kind: ListingReport.Kind, into target: URL) {
        guard !reading.contains(url.path) else { return }
        reading.insert(url.path)

        Task { [weak self] in
            let result = await BlockingWork.run {
                kind == .folder ? Listing.folder(at: url) : Listing.archive(at: url)
            }
            guard let self else { return }
            reading.remove(url.path)
            write(ListingReport.html(for: result, name: url.lastPathComponent,
                                     path: url.path, kind: kind),
                  to: target)
            listings[url.path] = target
            // Only if the panel is still showing this very thing: by now the
            // cursor may have moved on, and redrawing then would drag it back.
            if isVisible, items.contains(target) {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }

    /// An application or another bundle of code: at once what its Info.plist
    /// and signature say, then -- every file hashed and counted -- whether it
    /// is still as signed, and how big it is.
    private func bundleReport(for url: URL) -> URL? {
        guard AppBundle.extensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let bundle = try? AppBundle.read(url) else { return nil }
        if let ready = bundles[url.path] { return ready }
        let folder = scratch.appendingPathComponent("bundle" + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        let icon = Self.iconPNG(for: url)
        write(BundleReport.html(for: bundle, seal: nil, size: nil, icon: icon), to: target)
        guard !reading.contains(url.path) else { return target }
        reading.insert(url.path)
        Task { [weak self] in
            let html = await BlockingWork.run { () -> String? in
                guard let checked = try? AppBundle.read(url, verify: true) else { return nil }
                return BundleReport.html(for: checked, seal: checked.seal(), size: AppBundle.size(of: url), icon: icon)
            }
            guard let self else { return }
            reading.remove(url.path)
            guard let html else { return }
            write(html, to: target)
            bundles[url.path] = target
            if isVisible, items.contains(target) { QLPreviewPanel.shared().reloadData() }
        }
        return target
    }

    /// An installer package: what it installs, where, who signed it, and the
    /// scripts it runs. Read from the archive; nothing is extracted or run.
    private func packageReport(for url: URL) -> URL? {
        guard InstallerPackage.extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        let html: String
        if values.isDirectory == true {
            guard let package = try? InstallerPackage(bundle: url) else { return nil }
            html = PackageReport.html(for: package, size: AppBundle.size(of: url).bytes)
        } else {
            guard let size = values.fileSize, size > 0, size <= InstallerPackage.maximumSize,
                  let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  InstallerPackage.looksLikePackage(data) else { return nil }
            do {
                html = PackageReport.html(for: try InstallerPackage(url: url, data: data), size: Int64(size))
            } catch {
                html = PackageReport.html(failure: error, url: url, size: Int64(size))
            }
        }
        return page(html, kind: "package", for: url)
    }

    /// A disk image, without attaching it: at once what its trailer says,
    /// then -- its volumes read, its signed bytes hashed -- the rest.
    private func diskImageReport(for url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard DiskImage.extensions.contains(ext),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        if let ready = finished["image" + url.path] { return ready }
        let quick: DiskImage, full: @Sendable () -> String
        if values.isDirectory == true {
            guard ext == "sparsebundle", let image = try? DiskImage(bundle: url, listing: false) else { return nil }
            quick = image
            full = { (try? DiskImage(bundle: url)).map { DiskImageReport.html(for: $0, checking: false) } ?? "" }
        } else {
            guard let size = values.fileSize, size >= 512,
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
            // A raw image says what it is only in the partitions and volumes
            // read in the background: an .img or .iso that turns out to be
            // none is left to Quick Look.
            guard DiskImage.looksLikeImage(data) || ["dmg", "cdr", "iso", "img", "toast"].contains(ext),
                  let image = try? DiskImage(url: url, data: data, verify: false, listing: false) else {
                return ext == "dmg" ? page(DiskImageReport.html(failure: DiskImage.Problem.damaged("It is not a disk image."),
                                                                url: url, size: Int64(size)), kind: "image", for: url) : nil
            }
            if image.format == "UDRW" || image.format == "ISO" {
                guard let read = try? DiskImage(url: url, data: data, verify: false) else { return nil }
                return page(DiskImageReport.html(for: read, checking: false), kind: "image", for: url)
            }
            quick = image
            full = {
                do {
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    return DiskImageReport.html(for: try DiskImage(url: url, data: data, verify: true), checking: false)
                } catch {
                    return DiskImageReport.html(failure: error, url: url, size: Int64(size))
                }
            }
        }
        let target = page(DiskImageReport.html(for: quick, checking: true), kind: "image", for: url)
        if let target { finish(target, key: "image" + url.path, work: full) }
        return target
    }

    /// An e-mail message, or a mailbox of them. A mailbox can be large: its
    /// list is made in the background.
    private func mailReport(for url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        if MailMessage.extensions.contains(ext), values.isDirectory != true {
            guard let size = values.fileSize, size > 0, size <= MailMessage.maximumSize,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return page(MailReport.html(for: MailMessage(data: data), url: url), kind: "mail", for: url)
        }
        // Mail exports a mailbox as a folder with the messages in "mbox".
        var file = url
        if values.isDirectory == true {
            guard ext == "mbox" else { return nil }
            file = url.appendingPathComponent("mbox")
        } else if !Mailbox.extensions.contains(ext) {
            guard ext.isEmpty, let size = values.fileSize, size > 0,
                  let handle = try? FileHandle(forReadingFrom: url),
                  let head = try? handle.read(upToCount: 1024), Mailbox.looksLikeMailbox(head) else { return nil }
            try? handle.close()
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        if let ready = finished["mail" + url.path] { return ready }
        let mailbox = file
        let target = page(MailReport.html(reading: url), kind: "mail", for: url)
        if let target {
            finish(target, key: "mail" + url.path) {
                guard let data = try? Data(contentsOf: mailbox, options: .alwaysMapped) else { return "" }
                return MailReport.html(for: Mailbox(data: data), url: url)
            }
        }
        return target
    }

    /// A page named after the file, in a folder of its own per path.
    /// A file of a kind read in one go, its size checked first.
    private func small(_ url: URL, extensions: Set<String>, limit: Int) -> (data: Data, size: Int)? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true,
              let size = values.fileSize, size <= limit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (data, size)
    }

    /// A diagnostic report: what crashed, why in words, and the stack.
    private func crashReport(for url: URL) -> URL? {
        guard let (data, size) = small(url, extensions: CrashLog.extensions, limit: CrashLog.maximumSize),
              size > 0 else { return nil }
        let html: String
        do {
            html = CrashReport.html(for: try CrashLog(data: data), url: url, size: size)
        } catch {
            html = CrashReport.html(failure: error, url: url, size: size)
        }
        return page(html, kind: "crash", for: url)
    }

    /// A provisioning profile: app, team, expiry, devices, entitlements,
    /// certificates, and whether Apple's signature on it holds.
    private func provisioningReport(for url: URL) -> URL? {
        guard let (data, size) = small(url, extensions: ProvisioningProfile.extensions, limit: ProvisioningProfile.maximumSize),
              size > 0 else { return nil }
        let html: String
        do {
            html = ProvisioningReport.html(for: try ProvisioningProfile(data: data), url: url, size: size)
        } catch {
            html = ProvisioningReport.html(failure: error, url: url, size: size)
        }
        return page(html, kind: "profile", for: url)
    }

    /// A `.webloc`, `.inetloc` or Windows `.url`: where it goes, and with what.
    private func locationReport(for url: URL) -> URL? {
        guard let (data, size) = small(url, extensions: InternetLocation.extensions, limit: InternetLocation.maximumSize) else {
            return nil
        }
        let html: String
        do {
            let location: InternetLocation
            if url.pathExtension.lowercased() == "url" {
                location = try InternetLocation(windows: data)
            } else {
                let fork = data.isEmpty ? try? Data(contentsOf: url.appendingPathComponent("..namedfork/rsrc")) : nil
                location = try InternetLocation(finder: data, resourceFork: fork)
            }
            var opener: String?
            if let target = URL(string: location.target.trimmingCharacters(in: .whitespaces)), target.scheme != nil,
               let app = NSWorkspace.shared.urlForApplication(toOpen: target) {
                opener = FileManager.default.displayName(atPath: app.path)
            }
            html = LocationReport.html(for: location, url: url, size: size, opener: opener)
        } catch InternetLocation.Problem.notAShortcut {
            return nil // a text file that happens to end in .url: shown as text
        } catch {
            html = LocationReport.html(failure: error, url: url, size: size)
        }
        return page(html, kind: "location", for: url)
    }

    /// Java properties: keys and values as Java reads them, comments kept.
    private func propertiesReport(for url: URL) -> URL? {
        guard let (data, size) = small(url, extensions: JavaProperties.extensions, limit: JavaProperties.maximumSize),
              JavaProperties.looksLikeText(data) else { return nil }
        return page(PropertiesReport.html(for: JavaProperties(data: data), url: url, size: size), kind: "properties", for: url)
    }

    private func page(_ html: String, kind: String, for url: URL) -> URL? {
        let folder = scratch.appendingPathComponent(kind + url.path.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent + ".html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    /// The finished page, made in the background, written over the quick
    /// one -- and shown, if the panel still shows it.
    private func finish(_ target: URL, key: String, work: @escaping @Sendable () -> String) {
        guard !reading.contains(key) else { return }
        reading.insert(key)
        Task { [weak self] in
            let html = await BlockingWork.run(work)
            guard let self else { return }
            reading.remove(key)
            guard !html.isEmpty else { return }
            write(html, to: target)
            finished[key] = target
            if isVisible, items.contains(target) { QLPreviewPanel.shared().reloadData() }
        }
    }

    /// The icon Finder shows, as a 128-point PNG for the page.
    private static func iconPNG(for url: URL) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 128, height: 128)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func write(_ html: String, to target: URL) {
        try? html.write(to: target, atomically: true, encoding: .utf8)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Markdown is typed `net.daringfireball.markdown`, which conforms to
    /// public.plain-text and has no generator of its own -- so Quick Look shows
    /// the source. Render it instead.
    private func markdownReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= MarkdownReport.maximumSize,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // The document's own directory, so that a relative image path in a
        // README resolves against the README rather than against the temporary
        // file this preview is written to.
        let html = MarkdownReport.html(for: text, name: url.lastPathComponent,
                                       baseURL: url.deletingLastPathComponent())

        // Named after the full path: two READMEs previewed in one session would
        // otherwise overwrite each other in the scratch directory.
        let stem = url.path.replacingOccurrences(of: "/", with: "_")
        let target = scratch.appendingPathComponent("md\(stem).html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// Text shown as text, not rendered: what is not UTF-8 is worth a copy.
    /// HTML and RTF name their own encoding inside and are rendered.
    private static func isPlainTextual(_ type: UTType) -> Bool {
        type.conforms(to: .plainText) || type.conforms(to: .sourceCode)
            || [.json, .yaml, .xml].contains(where: { type.conforms(to: $0) })
    }

    /// The bytes of a text file to preview, when it is small enough to copy.
    private func textData(at url: URL) -> Data? {
        let limit = 4 * 1024 * 1024
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= limit else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// A text file's text, when it is in something other than plain UTF-8 --
    /// nil when Quick Look can show the file as it is. A file too short for its
    /// encoding to be told is read as UTF-8, as Quick Look itself would.
    private func reencodedText(at url: URL) -> String? {
        guard let data = textData(at: url),
              let reading = TextEncodings.reading(of: data, at: url, fallback: .utf8),
              reading.encoding != .utf8 || reading.guessed else { return nil }
        return TextEncodings.decodeForShowing(data, reading)
    }

    private func scratchText(_ text: String, for url: URL) -> URL? {
        let target = scratch.appendingPathComponent(url.lastPathComponent + ".txt")
        // The mark makes sure Quick Look does not guess again.
        guard let data = TextEncodings.encode(text, .utf8, bom: true),
              (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        return target
    }

    /// Heuristic, deliberately conservative: better to fall back to Quick Look's
    /// own "no preview" panel than to render a binary as mojibake.
    private func readableText(at url: URL) -> String? {
        guard let data = textData(at: url),
              // A NUL byte early on is the classic "this is binary" signal --
              // unless a byte-order mark says it is UTF-16 or UTF-32.
              let reading = TextEncodings.reading(of: data, at: url, fallback: .utf8) else { return nil }
        let text = TextEncodings.decodeForShowing(data, reading)

        // Control characters other than tab and the line endings mean it is
        // structured binary that happens to decode.
        let sample = text.prefix(8192)
        let controls = sample.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        return Double(controls) / Double(max(sample.count, 1)) < 0.02 ? text : nil
    }

    /// Per-process scratch directory for those .txt copies.
    private var scratch: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiptychPreview-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func clearScratch() {
        try? FileManager.default.removeItem(at: scratch)
        // The pages went with it, so a folder looked at again is read again
        // rather than served from a file that is no longer there.
        listings.removeAll()
        bundles.removeAll()
        finished.removeAll()
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // assumeIsolated must return something Sendable, and QLPreviewItem is
        // not. A URL is, so hand that across the boundary and cast outside.
        let url: URL? = MainActor.assumeIsolated {
            items.indices.contains(index) ? items[index] : nil
        }
        return url as NSURL?
    }
}

extension QuickLookController: QLPreviewPanelDelegate {

    /// If the panel does end up with key focus -- clicking it will do that --
    /// arrow keys still drive the file list rather than dead-ending in the
    /// panel. This is the hook AppKit provides for exactly that, and it is how
    /// Finder keeps working while its preview is frontmost.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = event.keyCode
        return MainActor.assumeIsolated {
            switch code {
            case 125: owner?.moveCursor(by: 1); return true    // down arrow
            case 126: owner?.moveCursor(by: -1); return true   // up arrow
            default:  return false
            }
        }
    }
}
