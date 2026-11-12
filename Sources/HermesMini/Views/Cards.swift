import SwiftUI

struct ApprovalCard: View {
    @StateObject private var store = AppStore.shared
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent žádá o schválení", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text(approval.command ?? approval.description ?? "Spustit příkaz?")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Povolit jednou") {
                    Task { await store.respondApproval(.once) }
                }
                .buttonStyle(.borderedProminent)
                Button("Vždy") {
                    Task { await store.respondApproval(.always) }
                }
                .buttonStyle(.bordered)
                Button("Zamítnout") {
                    Task { await store.respondApproval(.deny) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.14)))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

struct ClarificationCard: View {
    @StateObject private var store = AppStore.shared
    let clarification: PendingClarification
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent se ptá", systemImage: "questionmark.circle")
                .font(.headline)
            Text(clarification.question ?? "")
                .font(.callout)
                .textSelection(.enabled)
            if let choices = clarification.choicesOffered, !choices.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) {
                            Task { await store.respondClarification(choice) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    TextField("Odpověď…", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendAnswer() }
                    Button("Odeslat") { sendAnswer() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private func sendAnswer() {
        let text = answer
        answer = ""
        Task { await store.respondClarification(text) }
    }
}

/// Minimal flow layout: arranges views left-to-right, wrapping to the next row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
