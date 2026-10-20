import SwiftUI
import AppKit

/// Archive ▸ Recover ZIP Password…: trying passwords against an encrypted zip
/// that is your own. Two ways in -- outward from a password you half-remember,
/// or brute force up to a length you set, with the time that would take shown
/// first. The window says plainly that this is lawful on your own archives and
/// not on others', and points at the GPU tools that do it in earnest.
@MainActor
@Observable
final class PasswordRecoveryModel {

    enum Mode: String, CaseIterable, Identifiable { case guess, bruteForce; var id: String { rawValue } }

    enum Outcome: Equatable { case none, found(String), stopped, exhausted }

    let archive: URL
    /// Nil when the file turned out not to be an encrypted zip this can try.
    private let verifier: Archiving.ZipPasswordVerifier?
    /// Measured once, so the estimate suits the scheme and the machine.
    private let perGuess: Double

    var mode: Mode = .guess
    var guess = ""
    var alphabet: PasswordRecovery.Alphabet = .lowerDigits
    var maxLength = 4

    private(set) var running = false
    private(set) var outcome: Outcome = .none
    private(set) var tried: UInt64 = 0
    private(set) var total: UInt64?
    private(set) var rate: Double = 0
    private(set) var latest = ""
    private(set) var problem: String?

    private var search: PasswordRecovery.Search?

    init(_ request: PasswordRecoveryRequest) {
        archive = request.archive
        let verifier = Archiving.ZipPasswordVerifier(request.archive)
        self.verifier = verifier
        perGuess = verifier.map { PasswordRecovery.secondsPerGuess($0) } ?? 1e-6
    }

    var canTry: Bool { verifier != nil }
    var guessIsExpensive: Bool { verifier?.guessIsExpensive ?? false }

    /// The scheme, for the note about how fast a guess is.
    var schemeNote: String {
        guard let verifier else { return "" }
        return verifier.guessIsExpensive
            ? "This zip uses WinZip AES: each guess runs a slow key derivation by design, "
              + "so brute force reaches only short passwords. A guess you half-remember is "
              + "the better hope."
            : "This zip uses the original ZipCrypto: guesses are fast, millions a second, "
              + "though still no match for the GPU tools below past a short password."
    }

    var searchSize: UInt64? {
        PasswordRecovery.space(alphabet: alphabet.characters.count, maxLength: maxLength)
    }

    var estimate: String {
        PasswordRecovery.estimate(space: searchSize, secondsPerGuess: perGuess)
    }

    /// True when the brute-force search is large enough to be worth a warning.
    var estimateIsGrim: Bool {
        guard let size = searchSize else { return true }
        return Double(size) * perGuess / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1)) > 3_600
    }

    var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(tried) / Double(total))
    }

    func start() {
        guard let verifier, !running else { return }
        problem = nil
        let source: PasswordRecovery.CandidateSource
        switch mode {
        case .guess:
            let seed = guess
            guard !seed.isEmpty else {
                problem = "Type the password you remember, even if it is not quite right."
                return
            }
            source = PasswordRecovery.NearGuessSource(seed: seed)
        case .bruteForce:
            source = PasswordRecovery.BruteForceSource(alphabet: alphabet.characters,
                                                       maxLength: maxLength)
        }
        let archive = self.archive
        let search = PasswordRecovery.Search(verifier: verifier, source: source,
                                             confirm: { Archiving.zipPasswordOpens($0, archive) })
        self.search = search
        running = true
        outcome = .none
        tried = 0
        total = source.total
        rate = 0
        latest = ""

        Task { [weak self] in
            // The report callback runs on worker threads; it hops to the main
            // actor through a weak reference, so a closed window is ignored.
            let result = await BlockingWork.run { [weak self] in
                search.run { progress in
                    Task { @MainActor in self?.apply(progress) }
                }
            }
            guard let self else { return }
            self.search = nil
            self.running = false
            switch result {
            case .found(let password): self.outcome = .found(password)
            case .cancelled:           self.outcome = .stopped
            case .exhausted:           self.outcome = .exhausted
            }
        }
    }

    private func apply(_ progress: PasswordRecovery.Search.Progress) {
        guard running else { return }
        tried = progress.tried
        total = progress.total
        rate = progress.rate
        latest = progress.latest
    }

    func stop() {
        search?.cancel()
    }

    static func copy(_ password: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }
}

struct PasswordRecoveryView: View {

    let request: PasswordRecoveryRequest

    @State private var model: PasswordRecoveryModel
    @Environment(\.dismiss) private var dismiss

    init(request: PasswordRecoveryRequest) {
        self.request = request
        _model = State(initialValue: PasswordRecoveryModel(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            legalNotice
            if model.canTry {
                modePicker
                Divider()
                switch model.mode {
                case .guess:      guessControls
                case .bruteForce: bruteForceControls
                }
                Text(model.schemeNote)
                    .font(.callout).foregroundStyle(.secondary)
                professionalTools
                Spacer(minLength: 0)
                status
                bottom
            } else {
                Text("This file is not a password-protected zip, so there is nothing to recover.")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("Close") { dismiss() } }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 540)
        .navigationTitle("Recover Password \u{2014} \(request.archive.lastPathComponent)")
    }

    // MARK: -

    private var legalNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange).font(.title3)
            Text(PasswordRecovery.legalNotice)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            Text("From a password I remember").tag(PasswordRecoveryModel.Mode.guess)
            Text("Try every combination").tag(PasswordRecoveryModel.Mode.bruteForce)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.running)
    }

    private var guessControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The password as you remember it, even if a letter or two is wrong. "
                 + "Diptych tries it first, then passwords a key away, a case different, "
                 + "two letters swapped, and so on \u{2014} nearest first.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Remembered password", text: $model.guess)
                .textFieldStyle(.roundedBorder)
                .disabled(model.running)
        }
    }

    private var bruteForceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Characters", selection: $model.alphabet) {
                ForEach(PasswordRecovery.Alphabet.allCases) { Text($0.label).tag($0) }
            }
            .disabled(model.running)
            Stepper("Up to \(model.maxLength) characters", value: $model.maxLength, in: 1...12)
                .disabled(model.running)
            HStack(spacing: 6) {
                Image(systemName: model.estimateIsGrim ? "hourglass.bottomhalf.filled" : "hourglass")
                    .foregroundStyle(model.estimateIsGrim ? .orange : .secondary)
                Text("At worst \(model.estimate) on this Mac"
                     + (model.searchSize.map { ", \($0.formatted()) combinations" } ?? "") + ".")
                    .font(.callout)
                    .foregroundStyle(model.estimateIsGrim ? .primary : .secondary)
            }
            if model.estimateIsGrim {
                Text("That is too long to wait for. Shorten the password, narrow the characters, "
                     + "or use a GPU tool below.")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var professionalTools: some View {
        Text(PasswordRecovery.professionalTools)
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch model.outcome {
        case .found(let password):
            VStack(alignment: .leading, spacing: 8) {
                Label("The password is", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.headline)
                HStack {
                    Text(password).font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") { PasswordRecoveryModel.copy(password) }
                }
            }
        case .stopped:
            Label("Stopped after \(model.tried.formatted()) tried.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .exhausted:
            Label("Every password was tried and none opened it.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .none:
            if model.running { runningStatus } else if let problem = model.problem {
                Text(problem).foregroundStyle(.orange).font(.callout)
            }
        }
    }

    private var runningStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = model.progress {
                ProgressView(value: progress)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 12) {
                Text("\(model.tried.formatted()) tried")
                if model.rate > 0 { Text("\(Int(model.rate).formatted())/s") }
                Spacer()
                if !model.latest.isEmpty {
                    Text(model.latest).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bottom: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            if model.running {
                Button("Stop") { model.stop() }.keyboardShortcut(.cancelAction)
            } else {
                Button(model.mode == .guess ? "Search" : "Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.mode == .guess && model.guess.isEmpty)
            }
        }
    }
}
