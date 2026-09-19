import SwiftUI
import AppKit

// MARK: - 선택 옵션 입력 뷰 (키보드 네비게이션 지원)

/// CLI 대화형 선택 UI - 방향키로 옵션 변경, 엔터로 선택 확정
struct SelectionInputView: View {
    let options: [CLISelectionOption]
    let onSelect: (Int) -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 안내 텍스트
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.caption)
                    .foregroundStyle(AppColors.accent)
                Text(L10n.get("ai.chat.selectOption"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                // 키보드 힌트
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(L10n.get("ai.chat.arrowKeys"))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("⏎")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(L10n.get("ai.chat.enterKey"))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            // 선택 옵션 버튼들
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    let isHighlighted = index == selectedIndex

                    Button(action: {
                        onSelect(option.id)
                    }) {
                        HStack(spacing: 10) {
                            // 번호 배지
                            Text("\(option.id)")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(isHighlighted ? AppColors.background : AppColors.accent)
                                .frame(width: 24, height: 24)
                                .background(isHighlighted ? AppColors.accent : AppColors.controlBackground)
                                .clipShape(Circle())

                            // 옵션 텍스트
                            Text(option.label)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AppColors.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer()

                            // 현재 선택 표시
                            if isHighlighted {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(isHighlighted ? AppColors.accent.opacity(0.1) : AppColors.controlBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isHighlighted ? AppColors.accent : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(AppColors.textEditorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 25)
        .focusable()
        .focused($isFocused)
        .onAppear {
            // 첫 번째 옵션 또는 현재 선택된 옵션으로 초기화
            if let currentIndex = options.firstIndex(where: { $0.isSelected }) {
                selectedIndex = currentIndex
            } else {
                selectedIndex = 0
            }
            // 포커스 설정
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirmSelection()
            return .handled
        }
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4"), .init("5"), .init("6"), .init("7"), .init("8"), .init("9")]) { press in
            // 숫자 키로 직접 선택
            if let digit = Int(press.characters), digit > 0 && digit <= options.count {
                if let option = options.first(where: { $0.id == digit }) {
                    onSelect(option.id)
                    return .handled
                }
            }
            return .ignored
        }
    }

    private func moveSelection(by offset: Int) {
        let newIndex = selectedIndex + offset
        if newIndex >= 0 && newIndex < options.count {
            selectedIndex = newIndex
        }
    }

    private func confirmSelection() {
        guard selectedIndex >= 0 && selectedIndex < options.count else { return }
        let option = options[selectedIndex]
        onSelect(option.id)
    }
}
