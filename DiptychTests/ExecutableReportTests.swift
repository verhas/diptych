import XCTest
@testable import Diptych

/// The "Unix executable" preview: Mach-O, ELF, scripts, and text marked
/// executable.
final class ExecutableReportTests: XCTestCase {

    private let appleSilicon = ExecutableReport.Host(
        appleSilicon: true, macOS: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))

    private func page(_ data: Data, host: ExecutableReport.Host? = nil) throws -> String {
        ExecutableReport.html(for: try MachOFile(data: data), name: "sample", path: "/samples",
                              size: data.count, host: host ?? appleSilicon)
    }

    // MARK: - Mach-O

    func testAThinProgramSaysWhatItIsAndWhatItNeeds() throws {
        let file = try MachOFile(data: ExecutableFixtures.helloArm64)
        XCTAssertFalse(file.universal)
        let image = try XCTUnwrap(file.slices.first?.image)
        XCTAssertEqual(image.architecture, "arm64")
        XCTAssertEqual(MachOFile.kind(image.fileType), "Executable")
        XCTAssertEqual(image.platform, "macOS")
        XCTAssertEqual(image.minimumOS, "13.0")
        XCTAssertTrue(image.hasMain)
        XCTAssertNotNil(image.uuid)
        XCTAssertEqual(image.dynamicLinker, "/usr/lib/dyld")
        XCTAssertTrue(image.libraries.contains { $0.path == "/usr/lib/libSystem.B.dylib" })
        XCTAssertTrue(image.segments.contains { $0.name == "__TEXT" && $0.sections.contains("__text") })
    }

    func testTheLinkersSignatureIsCheckedPageByPage() throws {
        let signature = try XCTUnwrap(MachOFile(data: ExecutableFixtures.helloArm64).slices[0].image?.signature)
        XCTAssertTrue(signature.isLinkerSigned)
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertEqual(signature.hashName, "SHA-256")
        XCTAssertEqual(signature.isIntact, true)
        XCTAssertTrue(signature.certificates.isEmpty)
        let html = try page(ExecutableFixtures.helloArm64)
        XCTAssertTrue(html.contains("ad hoc, by the linker"))
        XCTAssertTrue(html.contains("all match the contents"))
        XCTAssertFalse(html.contains("class=warn"))
    }

    func testAChangeAfterSigningIsFound() throws {
        var data = ExecutableFixtures.helloEntitled
        let text = Data("Hello from a Diptych".utf8)
        let found = try XCTUnwrap(data.range(of: text))
        data[found.lowerBound] = UInt8(ascii: "J")
        let signature = try XCTUnwrap(MachOFile(data: data).slices[0].image?.signature)
        XCTAssertEqual(signature.isIntact, false)
        XCTAssertEqual(signature.mismatch, "Page 1 of 3 changed since it was signed.")
        XCTAssertTrue(try page(data).contains("The signature does not match."))
    }

    func testAnAdHocSignatureWithEntitlementsAndTheHardenedRuntime() throws {
        let signature = try XCTUnwrap(MachOFile(data: ExecutableFixtures.helloEntitled).slices[0].image?.signature)
        XCTAssertEqual(signature.identifier, "example.diptych.hello")
        XCTAssertTrue(signature.hasHardenedRuntime)
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertFalse(signature.isLinkerSigned)
        XCTAssertEqual(signature.isIntact, true)
        XCTAssertEqual(signature.entitlements.map(\.key), ["com.apple.security.cs.allow-jit",
                                                            "com.apple.security.get-task-allow",
                                                            "com.apple.security.network.client"])
        XCTAssertEqual(signature.entitlements.first?.value, "yes")
        let html = try page(ExecutableFixtures.helloEntitled)
        XCTAssertTrue(html.contains("Runtime: may generate code (JIT)"))
        XCTAssertTrue(html.contains("<h2>Entitlements <span class=count>3</span>"))
    }

    func testAnUnsignedProgramIsToldItWillNotRunOnAppleSilicon() throws {
        let image = try XCTUnwrap(MachOFile(data: ExecutableFixtures.helloUnsigned).slices[0].image)
        XCTAssertNil(image.signature)
        XCTAssertTrue(try page(ExecutableFixtures.helloUnsigned).contains("It is not signed. Apple silicon Macs run only signed code"))
    }

    func testAUniversalProgramShowsEverySlice() throws {
        let file = try MachOFile(data: ExecutableFixtures.helloUniversal)
        XCTAssertTrue(file.universal)
        XCTAssertEqual(Set(file.slices.map(\.architecture)), ["arm64", "x86_64"])
        // The linker signs for Apple silicon only: Intel Macs run unsigned code.
        XCTAssertEqual(file.slices.first { $0.architecture == "arm64" }?.image?.signature?.isIntact, true)
        XCTAssertNil(file.slices.first { $0.architecture == "x86_64" }?.image?.signature)
        let intel = try XCTUnwrap(file.slices.first { $0.architecture == "x86_64" }?.image)
        XCTAssertEqual(intel.minimumOS, "10.13")
        let html = try page(ExecutableFixtures.helloUniversal)
        XCTAssertTrue(html.contains("Mach-O universal executable for"))
        XCTAssertTrue(html.contains("Apple silicon") && html.contains("Intel, 64-bit"))
        XCTAssertTrue(html.contains("Intel Macs run unsigned code"))
        XCTAssertFalse(html.contains("class=warn"))
        // The same libraries in both: listed once.
        XCTAssertEqual(html.components(separatedBy: "<h2>Linked Libraries").count, 2)
    }

    func testAnIntelOnlyProgramRunsUnderRosetta() throws {
        XCTAssertTrue(try page(ExecutableFixtures.helloIntel).contains("Intel only: on this Mac it runs under Rosetta 2."))
        let intelMac = ExecutableReport.Host(appleSilicon: false, macOS: appleSilicon.macOS)
        XCTAssertFalse(try page(ExecutableFixtures.helloIntel, host: intelMac).contains("Rosetta"))
        XCTAssertTrue(try page(ExecutableFixtures.helloArm64, host: intelMac).contains("this Intel Mac cannot run it"))
    }

    func testANewerMacOSThanThisOneIsSaid() throws {
        let old = ExecutableReport.Host(appleSilicon: true,
                                        macOS: OperatingSystemVersion(majorVersion: 12, minorVersion: 7, patchVersion: 1))
        XCTAssertTrue(try page(ExecutableFixtures.helloArm64, host: old)
            .contains("It needs macOS 13.0 or later; this Mac has 12.7.1."))
        XCTAssertFalse(try page(ExecutableFixtures.helloArm64).contains("It needs macOS"))
        XCTAssertFalse(ExecutableReport.newer("13.0", than: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(ExecutableReport.newer("13.0.1", than: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)))
    }

    func testADynamicLibraryHasItsInstallNameAndVersions() throws {
        let image = try XCTUnwrap(MachOFile(data: ExecutableFixtures.libSample).slices[0].image)
        XCTAssertEqual(MachOFile.kind(image.fileType), "Dynamic library")
        XCTAssertEqual(image.identity, MachOFile.Library(path: "@rpath/libsample.dylib", kind: .load,
                                                         current: "1.2.3", compatible: "1.0"))
        XCTAssertFalse(image.hasMain)
        XCTAssertTrue(try page(ExecutableFixtures.libSample).contains("Install name"))
    }

    func testAnObjectFileIsNotSignedAndIsNotWarnedAbout() throws {
        let image = try XCTUnwrap(MachOFile(data: ExecutableFixtures.helloObject).slices[0].image)
        XCTAssertEqual(MachOFile.kind(image.fileType), "Object file")
        XCTAssertNil(image.signature)
        XCTAssertFalse(try page(ExecutableFixtures.helloObject).contains("It is not signed"))
    }

    func testAnApplePlatformBinaryIsSignedByApple() throws {
        let url = URL(fileURLWithPath: "/usr/bin/true")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no /usr/bin/true") }
        let file = try MachOFile(data: data)
        let signature = try XCTUnwrap(file.slices.compactMap { $0.image?.signature }.first)
        XCTAssertTrue(signature.platformBinary)
        XCTAssertGreaterThanOrEqual(signature.certificates.count, 2)
        // "Software Signing", lately "macOS Software Signing".
        XCTAssertTrue(signature.signer.map { X509.shortName($0.subject).hasSuffix("Software Signing") } == true)
        XCTAssertEqual(signature.isIntact, true)
        let html = ExecutableReport.html(for: file, name: "true", path: "/usr/bin", size: data.count, host: appleSilicon)
        XCTAssertTrue(html.contains("Apple Root CA"))
        XCTAssertTrue(html.contains("part of the operating system"))
        XCTAssertTrue(html.contains("— Apple</span>"))
    }

    func testAClassFileIsNotTakenForAUniversalBinary() {
        XCTAssertFalse(MachOFile.looksLikeMachO(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 65, 0, 0])))
        XCTAssertTrue(MachOFile.looksLikeMachO(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 0, 0])))
    }

    func testADamagedMachOFileSaysWhy() {
        let cut = ExecutableFixtures.helloArm64.prefix(40)
        XCTAssertThrowsError(try MachOFile(data: cut)) { error in
            XCTAssertTrue(String(describing: error).contains("load commands"))
        }
        let html = ExecutableReport.html(failure: MachOFile.Problem.damaged("broken"), kind: "Mach-O file",
                                         name: "x", path: "/", size: 40)
        XCTAssertTrue(html.contains("It cannot be read: broken"))
    }

    func testVersionsAreUnpacked() {
        XCTAssertEqual(MachOFile.version(0x000D_0000), "13.0")
        XCTAssertEqual(MachOFile.version(0x0001_0203), "1.2.3")
        XCTAssertEqual(MachOFile.sourceVersion(UInt64(1300) << 40 | UInt64(5) << 30), "1300.5")
        XCTAssertEqual(MachOFile.architecture(0x0100_000C, 2), "arm64e")
        XCTAssertEqual(MachOFile.architecture(0x0100_0007, 3), "x86_64")
        XCTAssertEqual(MachOFile.processor("arm64 (subtype 12)", platform: "macOS"), "Apple silicon")
        XCTAssertEqual(MachOFile.processor("armv7", platform: "iOS"), "32-bit ARM")
    }

    // MARK: - ELF

    func testADynamicLinuxProgram() throws {
        let file = try ELF(data: ExecutableFixtures.elfDynamic)
        XCTAssertTrue(file.is64)
        XCTAssertFalse(file.bigEndian)
        XCTAssertEqual(file.machine, "x86-64")
        XCTAssertEqual(file.interpreter, "/lib64/ld-linux-x86-64.so.2")
        XCTAssertTrue(file.needed.contains("libc.so.6"))
        XCTAssertEqual(file.system, "Linux")
        XCTAssertEqual(file.kind, "Executable")
        XCTAssertTrue(file.versionsNeeded.contains { $0.family == "GLIBC" })
        let html = ExecutableReport.html(for: file, name: "hello", path: "/samples", size: 1)
        XCTAssertTrue(html.contains("Built for Linux: macOS cannot run it."))
        XCTAssertTrue(html.contains("Dynamically, loaded by /lib64/ld-linux-x86-64.so.2"))
        XCTAssertTrue(html.contains("<h2>Needed Libraries"))
    }

    func testAStaticLinuxProgram() throws {
        let file = try ELF(data: ExecutableFixtures.elfStatic)
        XCTAssertEqual(file.machine, "AArch64 (64-bit ARM)")
        XCTAssertNil(file.interpreter)
        XCTAssertTrue(file.needed.isEmpty)
        XCTAssertTrue(file.linking.hasPrefix("Statically"))
        XCTAssertFalse(file.sections.contains(".symtab"))
        XCTAssertTrue(ExecutableReport.html(for: file, name: "s", path: "/", size: 1).contains("stripped"))
    }

    func testASharedLibraryHasItsName() throws {
        let file = try ELF(data: ExecutableFixtures.elfLibrary)
        XCTAssertEqual(file.soname, "libsample.so.1")
        XCTAssertEqual(file.kind, "Shared library")
    }

    func testAnObjectFileForRISCV() throws {
        let file = try ELF(data: ExecutableFixtures.elfObject)
        XCTAssertEqual(file.machine, "RISC-V")
        XCTAssertEqual(file.kind, "Relocatable object file")
        XCTAssertFalse(ExecutableReport.html(for: file, name: "o", path: "/", size: 1).contains("macOS cannot run it"))
    }

    func testADamagedELFFileSaysWhy() {
        var data = ExecutableFixtures.elfDynamic.prefix(64)
        data[4] = 9
        XCTAssertThrowsError(try ELF(data: Data(data)))
        XCTAssertFalse(ELF.looksLikeELF(Data("#!/bin/sh\n".utf8)))
    }

    // MARK: - Scripts

    private let fakeMac = Script.Environment(
        exists: { ["/bin/bash", "/bin/sh", "/usr/bin/env", "/opt/homebrew/bin/python3"].contains($0) },
        search: ["/opt/homebrew/bin", "/usr/bin", "/bin"])

    private func script(_ text: String, executable: Bool = true) -> Script {
        Script(data: Data(text.utf8), text: text, executable: executable, environment: fakeMac)
    }

    func testAScriptNamesItsInterpreter() {
        let bash = script("#!/bin/bash\necho hi\n")
        XCTAssertEqual(bash.interpreter, "/bin/bash")
        XCTAssertEqual(bash.language, "Bash")
        XCTAssertTrue(bash.problems.isEmpty)
        XCTAssertTrue(bash.notes.isEmpty)
        let html = ExecutableReport.html(for: bash, name: "run", path: "/", size: 20)
        XCTAssertTrue(html.contains("Bash script"))
        XCTAssertTrue(html.contains("<span>echo hi</span>"))
    }

    func testEnvIsFollowedToTheProgram() {
        let python = script("#!/usr/bin/env python3\nprint(1)\n")
        XCTAssertEqual(python.program, "python3")
        XCTAssertEqual(python.found, "/opt/homebrew/bin/python3")
        XCTAssertEqual(python.language, "Python")
        XCTAssertTrue(python.notes.isEmpty)
        XCTAssertEqual(python.here, .runs("/opt/homebrew/bin/python3"))
        XCTAssertNil(python.onLinux)

        let deno = script("#!/usr/bin/env -S deno run --allow-read\n")
        XCTAssertEqual(deno.program, "deno")
        XCTAssertNil(deno.found)
        XCTAssertEqual(deno.here, .depends("only if deno is in your PATH: it is not in the usual places on this Mac"))
        XCTAssertNil(deno.onLinux)
        XCTAssertTrue(ExecutableReport.html(for: deno, name: "d", path: "/", size: 1).contains("<code>run --allow-read</code>"))

        // macOS splits the line and runs it; Linux looks for "python3 -u".
        let unsplit = script("#!/usr/bin/env python3 -u\n")
        XCTAssertEqual(unsplit.here, .runs("/opt/homebrew/bin/python3"))
        XCTAssertTrue(unsplit.onLinux.map { if case .fails(let why) = $0 { why.contains("“python3 -u”") } else { false } } == true)
        let html = ExecutableReport.html(for: unsplit, name: "u", path: "/", size: 1)
        XCTAssertTrue(html.contains("On this Mac") && html.contains("On Linux"))
        XCTAssertFalse(html.contains("Runs with"))
        XCTAssertEqual(Script.envProgram(["-i", "PATH=/bin", "node"]), "node")
        XCTAssertEqual(Script.envProgram(["-Spython3", "-u"]), "python3")
    }

    func testWindowsLineEndingsInTheHashBangLineAreFound() {
        let crlf = script("#!/bin/bash\r\necho hi\r\n")
        XCTAssertEqual(crlf.interpreter, "/bin/bash")
        XCTAssertTrue(crlf.problems.contains { $0.contains("Windows line ending") })
        // Never "runs" when it does not.
        guard case .fails? = crlf.here else { return XCTFail("CR LF should not run") }
        XCTAssertFalse(ExecutableReport.html(for: crlf, name: "w", path: "/", size: 1).contains("\r"))
    }

    func testAByteOrderMarkHidesTheLine() {
        let text = "\u{FEFF}#!/bin/bash\necho hi\n"
        let marked = Script(data: Data(text.utf8), text: text, executable: true, environment: fakeMac)
        XCTAssertTrue(marked.problems.contains { $0.contains("byte-order mark") })
        guard case .fails? = marked.here else { return XCTFail("a marked line should not run as written") }
        XCTAssertTrue(Script.startsLikeScript(Data(text.utf8)))
    }

    func testInterpretersThatCannotBeFound() {
        let missing = script("#!/usr/local/bin/no-such-shell\n")
        XCTAssertTrue(missing.problems.contains { $0.contains("is not on this Mac") })
        XCTAssertEqual(missing.here, .fails("/usr/local/bin/no-such-shell is not on this Mac"))
        XCTAssertTrue(ExecutableReport.html(for: missing, name: "m", path: "/", size: 1).contains("does not run"))
        XCTAssertTrue(script("#!bash\n").problems.contains { $0.contains("not a full path") })
        XCTAssertTrue(script("#!\n").problems.contains { $0.contains("names no interpreter") })
        XCTAssertTrue(script("#!/usr/bin/env\n").problems.contains { $0.contains("not given a program") })
    }

    func testExecutableOrNot() {
        let plain = script("#!/bin/sh\n", executable: false)
        XCTAssertTrue(plain.notes.contains { $0.contains("chmod +x") })
        guard case .depends? = plain.here else { return XCTFail("not executable: only as sh file") }
        let text = script("Just some words.\n")
        XCTAssertNil(text.line)
        XCTAssertTrue(text.notes.contains { $0.contains("no #! line") })
        XCTAssertTrue(ExecutableReport.html(for: text, name: "t", path: "/", size: 1).contains("Text marked executable"))
    }

    func testLanguagesAreNamedWithoutTheirVersions() {
        XCTAssertEqual(Script.language(of: "python3.12"), "Python")
        XCTAssertEqual(Script.language(of: "osascript"), "AppleScript")
        XCTAssertEqual(Script.language(of: "node"), "JavaScript (Node.js)")
        XCTAssertNil(Script.language(of: "something-else"))
    }

    func testMarkupInAScriptIsEscaped() {
        let html = ExecutableReport.html(for: script("#!/bin/sh\necho '<b>&'\n"), name: "e", path: "/", size: 1)
        XCTAssertTrue(html.contains("echo &#39;&lt;b&gt;&amp;&#39;") || html.contains("echo '&lt;b&gt;&amp;'"))
    }

    // MARK: - Windows

    private func windowsPage(_ data: Data) throws -> String {
        ExecutableReport.html(for: try PEFile(data: data), name: "w.exe", path: "/samples", size: data.count)
    }

    func testAWindowsConsoleProgram() throws {
        let file = try PEFile(data: ExecutableFixtures.windowsConsole)
        XCTAssertEqual(file.format, .pe)
        XCTAssertTrue(file.is64)
        XCTAssertEqual(PEFile.machine(file.machine), "x64")
        XCTAssertEqual(file.kind, "Windows command-line program")
        XCTAssertEqual(file.imports.map(\.library), ["KERNEL32.dll"])
        XCTAssertEqual(file.imports.first?.functions, 3)
        XCTAssertNil(file.signature)
        let html = try windowsPage(ExecutableFixtures.windowsConsole)
        XCTAssertTrue(html.contains("Built for Windows: macOS cannot run it."))
        XCTAssertTrue(html.contains("<h2>Libraries It Uses"))
    }

    func testTheVersionResourceAndTheManifest() throws {
        let file = try PEFile(data: ExecutableFixtures.windowsAdmin)
        XCTAssertEqual(file.fixedVersion, "1.2.3.4")
        let strings = Dictionary(file.version.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(strings["ProductName"], "Diptych Sample")
        XCTAssertEqual(strings["CompanyName"], "Diptych Samples")
        XCTAssertEqual(strings["FileDescription"], "A Diptych sample program")
        XCTAssertEqual(file.executionLevel, "requireAdministrator")
        XCTAssertTrue(try windowsPage(ExecutableFixtures.windowsAdmin).contains("It asks for administrator rights"))
    }

    func testOtherProcessorsAndTheWindowsSubsystem() throws {
        let arm = try PEFile(data: ExecutableFixtures.windowsArm64)
        XCTAssertEqual(PEFile.machine(arm.machine), "ARM64")
        let x86 = try PEFile(data: ExecutableFixtures.windowsX86)
        XCTAssertFalse(x86.is64)
        XCTAssertEqual(PEFile.machine(x86.machine), "x86 (32-bit)")
        XCTAssertEqual(x86.kind, "Windows program with windows")
    }

    func testAnAuthenticodeSignatureIsReadAndItsHashChecked() throws {
        let file = try PEFile(data: ExecutableFixtures.windowsSigned)
        let signature = try XCTUnwrap(file.signature)
        XCTAssertEqual(signature.signer.map { X509.shortName($0.subject) }, "Diptych Sample Code Signing")
        XCTAssertEqual(signature.certificates.count, 2)
        XCTAssertEqual(signature.digestName, "SHA-256")
        XCTAssertNotNil(signature.signedAt)
        XCTAssertEqual(signature.intact, true)
        let html = try windowsPage(ExecutableFixtures.windowsSigned)
        XCTAssertTrue(html.contains("Diptych Sample Code Signing CA"))
        XCTAssertTrue(html.contains("the file matches it"))

        var changed = ExecutableFixtures.windowsSigned
        let found = try XCTUnwrap(changed.range(of: Data("Hello from a Diptych".utf8)))
        changed[found.lowerBound] = UInt8(ascii: "J")
        XCTAssertEqual(try PEFile(data: changed).signature?.intact, false)
        XCTAssertTrue(try windowsPage(changed).contains("The signature does not match."))
    }

    func testADLLAndItsExports() throws {
        let file = try PEFile(data: ExecutableFixtures.windowsDLL)
        XCTAssertTrue(file.isLibrary)
        XCTAssertEqual(file.kind, "Windows library (DLL)")
        XCTAssertEqual(file.exportName, "sample.dll")
        XCTAssertEqual(file.exports, ["sample_answer", "sample_twice"])
    }

    func testAnImportLibraryNamesItsDLL() throws {
        let archive = try ArArchive(data: ExecutableFixtures.windowsImportLibrary)
        XCTAssertEqual(archive.kind, "Windows import library")
        XCTAssertEqual(archive.importedFrom.map(\.library), ["sample.dll"])
        XCTAssertEqual(archive.importedFrom.first?.functions, 2)
        let html = ExecutableReport.html(for: archive, name: "sample.lib", path: "/", size: 1)
        XCTAssertTrue(html.contains("Windows import library for sample.dll"))
    }

    func testAStaticLibraryAndAnObjectFile() throws {
        let archive = try ArArchive(data: ExecutableFixtures.windowsStaticLibrary)
        XCTAssertEqual(archive.kind, "Windows static library")
        XCTAssertEqual(archive.members.map(\.name), ["sample.obj"])
        XCTAssertEqual(archive.architectures, ["COFF x64"])
        XCTAssertEqual(COFFObject.machine(of: ExecutableFixtures.windowsObject), 0x8664)
        XCTAssertNil(COFFObject.machine(of: Data("v 1.0 2.0 3.0\nf 1 2 3\n".utf8)), "a Wavefront .obj is text")
    }

    func testAnMSDOSProgram() throws {
        let file = try PEFile(data: ExecutableFixtures.dosProgram)
        XCTAssertEqual(file.format, .dos)
        XCTAssertTrue(try windowsPage(ExecutableFixtures.dosProgram).contains("DOSBox"))
        XCTAssertThrowsError(try PEFile(data: Data("not a program at all, not even close to one".utf8)))
    }

    func testAUnixStaticLibrary() throws {
        // An ar archive of one ELF object, as ar would write it.
        var data = Data("!<arch>\n".utf8)
        let object = ExecutableFixtures.elfObject
        let header = "hello.o/".padding(toLength: 16, withPad: " ", startingAt: 0) + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "0     0     644     " + String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0) + "`\n"
        data += Data(header.utf8) + object
        if object.count % 2 == 1 { data.append(0x0A) }
        let archive = try ArArchive(data: data)
        XCTAssertEqual(archive.kind, "Static library")
        XCTAssertEqual(archive.members.first?.name, "hello.o")
        XCTAssertEqual(archive.architectures, ["ELF RISC-V"])
    }

    // MARK: - Batch files

    func testABatchFileThatIsRight() {
        let text = "@echo off\r\ngoto greet\r\n:greet\r\necho hi\r\n"
        let batch = BatchFile(data: Data(text.utf8), text: text)
        XCTAssertTrue(batch.problems.isEmpty)
        XCTAssertTrue(batch.notes.isEmpty)
        XCTAssertEqual(batch.labels, 1)
        let html = ExecutableReport.html(for: batch, name: "a.bat", path: "/", size: 1)
        XCTAssertTrue(html.contains("macOS has no cmd.exe"))
        XCTAssertTrue(html.contains("<span>:greet</span>"))
    }

    func testLabelsInAFileWithUnixLineEndings() {
        let text = "@echo off\ngoto greet\n:greet\necho hi\n"
        let batch = BatchFile(data: Data(text.utf8), text: text)
        XCTAssertTrue(batch.problems.contains { $0.contains("LF only") })
        let plain = "@echo off\necho hi\n"
        XCTAssertTrue(BatchFile(data: Data(plain.utf8), text: plain).notes.contains { $0.contains("LF only") },
                      "without labels it is only a note")
    }

    func testAByteOrderMarkAndUTF8InABatchFile() {
        let marked = "\u{FEFF}@echo off\r\n"
        let batch = BatchFile(data: Data(marked.utf8), text: marked)
        XCTAssertTrue(batch.problems.contains { $0.contains("byte-order mark") })
        XCTAssertFalse(batch.notes.contains { $0.contains("beyond ASCII") }, "the mark is not a character in it")
        let accented = "echo caf\u{E9}\r\n"
        XCTAssertTrue(BatchFile(data: Data(accented.utf8), text: accented).notes.contains { $0.contains("chcp 65001") })
        let switched = "chcp 65001\r\necho caf\u{E9}\r\n"
        XCTAssertTrue(BatchFile(data: Data(switched.utf8), text: switched).notes.isEmpty)
    }

    func testInvisibleCharactersInASourceAreNamed() {
        let html = ExecutableReport.source("\u{FEFF}echo a\u{202E}b\r\nnext\n")
        XCTAssertTrue(html.contains("<i class=inv>BOM</i>echo a<i class=inv>RLO</i>b"))
        XCTAssertTrue(html.contains("<span>next</span>"), "CR LF lines are split")
        XCTAssertFalse(html.contains("\u{202E}"))
    }
}
