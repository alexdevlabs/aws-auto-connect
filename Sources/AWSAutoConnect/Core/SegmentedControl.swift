import SwiftUI

/// A segmented control whose segments share the full width it's given, drawn like the system one.
/// SwiftUI's segmented Picker keeps its natural width on macOS, and NSSegmentedControl can't dim
/// part of a label (the count in "DNS 32").
struct SegmentedControl: View {
    struct Item {
        let id: String
        let label: String
        /// Shown dimmed after the label, e.g. a count.
        var detail: String?
    }

    let items: [Item]
    @Binding var selection: String
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // Like the system control: accent when the window is key, grey otherwise.
        let active = activeState == .key || activeState == .active
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let selected = item.id == selection
                let lit = selected && active
                Button { selection = item.id } label: {
                    HStack(spacing: 4) {
                        Text(item.label)
                        if let detail = item.detail {
                            Text(detail).foregroundStyle(lit ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                                .monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .overlay(alignment: .leading) {
                    // A divider between two unselected segments.
                    if i > 0, !selected, items[i - 1].id != selection {
                        Rectangle().fill(.separator).frame(width: 1, height: 12)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
