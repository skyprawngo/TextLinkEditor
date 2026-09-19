import SwiftUI

/// A single glass track with a sliding selection, rather than separate glass buttons.
struct LiquidGlassSegmentedControl<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [Value]
  let label: (Value) -> String
  @Namespace private var indicator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        ForEach(options, id: \.self) { item in
          Button {
            selection = item
          } label: {
            Text(label(item))
              .lineLimit(1)
              .fontWeight(selection == item ? .semibold : .regular)
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .help(label(item))
          .background {
            if selection == item {
              Capsule()
                .fill(.background)
                .matchedGeometryEffect(id: "selection", in: indicator)
            }
          }
          .accessibilityAddTraits(selection == item ? .isSelected : [])
        }
      }
      .padding(4)
      // HIG Materials: use regular Liquid Glass for the navigation layer.
      // https://developer.apple.com/design/human-interface-guidelines/materials
      .glassEffect(.regular, in: .capsule)
      .highPriorityGesture(
        DragGesture(minimumDistance: 4)
          .onChanged { value in
            guard isEnabled, !options.isEmpty else { return }
            let segmentWidth = max(1, (geometry.size.width - 8) / CGFloat(options.count))
            let index = min(options.count - 1, max(0, Int((value.location.x - 4) / segmentWidth)))
            selection = options[index]
          }
      )
      .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
      .onMoveCommand { direction in
        guard isEnabled, let index = options.firstIndex(of: selection) else { return }
        if direction == .left { selection = options[max(0, index - 1)] }
        if direction == .right { selection = options[min(options.count - 1, index + 1)] }
      }
    }
    .frame(height: 38)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}
