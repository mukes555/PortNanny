import PortNannyCore
import SwiftUI

/// Agents ⟷ Simple ⟷ Advanced: a pill with a sliding selection over the
/// list. Agents is the grouping by session; the other two are the plain list
/// with less or more in each row.
struct ViewModeToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var mode: PortManager.ViewMode
    @Namespace private var slider

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PortManager.ViewMode.allCases, id: \.self) { value in
                segment(value)
            }
        }
        .padding(2)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .help("Agents groups what is listening by the session that started it. Simple lists every port by kind; Advanced adds the command, chips, CPU, and process tree.")
    }

    private func segment(_ value: PortManager.ViewMode) -> some View {
        let selected = mode == value
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) {
                mode = value
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: value.icon)
                    .font(.system(size: 10, weight: .medium))
                // Three labels share the header with the brand; one of them
                // wrapped to "Advance / d" before these two lines.
                Text(value.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "slider", in: slider)
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value.label) view")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
