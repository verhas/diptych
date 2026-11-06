import SwiftUI

/// The open-source packages built into Diptych, each with its licence in
/// full, as `make-licenses.sh` read them into the bundled `Licenses.json`.
struct Acknowledgements {

    struct Package: Decodable, Identifiable, Hashable {
        struct File: Decodable, Hashable {
            let name: String
            let text: String
        }
        let id: String
        let name: String
        let use: String
        let version: String
        let url: String
        let license: String
        let files: [File]
    }

    static let packages: [Package] = {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Package].self, from: data)) ?? []
    }()
}

struct AcknowledgementsView: View {

    @State private var selection: Acknowledgements.Package.ID?

    private let packages = Acknowledgements.packages

    var body: some View {
        NavigationSplitView {
            List(packages, selection: $selection) { package in
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                    Text("\(package.version) \u{00B7} \(package.license)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let package = packages.first(where: { $0.id == selection }) {
                detail(package)
            } else {
                overview
            }
        }
        .navigationTitle("Acknowledgements")
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { if selection == nil { selection = packages.first?.id } }
    }

    private var overview: some View {
        VStack(spacing: 8) {
            Text("Diptych is built with \(packages.count) open-source packages.")
            Text("Choose one to read its licence.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ package: Acknowledgements.Package) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name).font(.title2.bold())
                    if !package.use.isEmpty {
                        Text(package.use).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("Version \(package.version) \u{00B7} \(package.license)")
                        if let url = URL(string: package.url) {
                            Text("\u{00B7}")
                            Link((url.host() ?? "") + url.path(), destination: url)
                        }
                    }
                    .font(.callout)
                }
                ForEach(package.files, id: \.name) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        if package.files.count > 1 {
                            Text(file.name).font(.headline)
                        }
                        Text(file.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(package.id)
    }
}
