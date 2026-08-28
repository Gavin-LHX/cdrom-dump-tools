import SwiftUI

struct ReleaseSelectionView: View {
    let candidates: [ReleaseCandidate]
    let onChoose: (ReleaseCandidate) -> Void
    let onCancel: () -> Void

    @State private var selectedIndex: Int?

    init(
        candidates: [ReleaseCandidate],
        onChoose: @escaping (ReleaseCandidate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.candidates = candidates
        self.onChoose = onChoose
        self.onCancel = onCancel
        _selectedIndex = State(initialValue: candidates.first?.index)
    }

    private var selectedCandidate: ReleaseCandidate? {
        candidates.first { $0.index == selectedIndex }
    }

    var body: some View {
        ZStack {
            CdromGlassWindowBackground()
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择 MusicBrainz 发行版本")
                            .font(.title2.weight(.semibold))
                        Text("多个发行版本与这张光盘的 Disc ID/TOC 匹配。请核对日期、地区、碟号和条码。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .cdromGlassSurface(cornerRadius: 18)
                .accessibilityElement(children: .combine)

                List(candidates, selection: $selectedIndex) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("[\(candidate.index)]")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(candidate.artist).fontWeight(.medium)
                            Text("—")
                            Text(candidate.title).fontWeight(.medium)
                            Spacer()
                        }
                        HStack(spacing: 14) {
                            CandidateField(label: "日期", value: candidate.date)
                            CandidateField(label: "地区", value: candidate.country)
                            CandidateField(label: "碟号", value: candidate.disc)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(candidate.index)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onChoose(candidate) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("双击使用此发行版本")
                }
                .listStyle(.inset)

                if let selectedCandidate {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MusicBrainz ID: \(selectedCandidate.releaseID.isEmpty ? "—" : selectedCandidate.releaseID)")
                        Text("条码: \(selectedCandidate.barcode.isEmpty ? "—" : selectedCandidate.barcode)")
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.06))
                }

                CdromGlassEffectGroup(spacing: 10) {
                    HStack {
                        Button("取消转换") { onCancel() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("使用所选版本") {
                            if let selectedCandidate { onChoose(selectedCandidate) }
                        }
                        .cdromGlassButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCandidate == nil)
                    }
                    .padding(16)
                    .cdromGlassSurface(cornerRadius: 18)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 760, minHeight: 520)
        .interactiveDismissDisabled()
    }
}

private struct CandidateField: View {
    let label: String
    let value: String

    var body: some View {
        Text("\(label)：\(value.isEmpty ? "—" : value)")
    }
}
