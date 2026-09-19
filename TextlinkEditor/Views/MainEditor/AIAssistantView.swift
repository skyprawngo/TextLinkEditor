//
//  AIAssistantView.swift
//  TextlinkEditor
//
//  AI 어시스턴트 메인 뷰 - AIAssistant/ 폴더 내 뷰들의 진입점
//
//  계층 구조:
//  - AIAssistantView (이 파일 - 프레임/래퍼)
//    └── AIAssistantContainerView (상태별 분기)
//        ├── AIInactiveView (비활성화 상태)
//        ├── AISetupView (AI 선택)
//        ├── CLIInstallGuideView (CLI 설치 안내)
//        ├── AIChatView (채팅)
//        └── errorView (오류)
//

import SwiftUI

/// AI 어시스턴트 메인 뷰
/// MainEditorView에서 우측 패널로 사용됨
struct AIAssistantView: View {
    /// 상세 뷰 모드 여부 바인딩 (외부에서 관찰 및 수정 가능)
    @Binding var isInDetailView: Bool

    var body: some View {
        AIAssistantContainerView(
            isInDetailView: $isInDetailView
        )
    }
}

#Preview {
    AIAssistantView(isInDetailView: .constant(false))
        .frame(width: 350, height: 600)
}
