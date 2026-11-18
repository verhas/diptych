import SwiftUI

/// What Apple Intelligence makes of a comparison, in a box of its own: a
/// spinner while it is thinking, then its few sentences, selectable. Shows
/// nothing at all while there is nothing to explain.
struct DifferenceExplanationView: View {

    let explanation: DifferenceExplanation

    var body: some View {
        switch explanation.state {
        case .idle:
            EmptyView()
        case .working:
            box {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Apple Intelligence is reading the differences\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
        case .done(let text):
            box {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let why):
            box {
                Text(why).foregroundStyle(.orange)
            }
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .help("Written by Apple Intelligence on this Mac. It can be wrong.")
            content()
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }
}
