//
//  TermsOfServiceView.swift
//  TextlinkEditor
//
//  이용약관 표시 뷰
//

import SwiftUI

struct TermsOfServiceView: View {
    @Environment(\.dismiss) private var dismiss

    /// 현재 언어에 맞는 이용약관 내용
    private var termsContent: String {
        loadTermsContent()
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            SheetHeader(title: L10n.get("terms.title")) { dismiss() }
            .padding()
            .background(.bar)

            Divider()

            // 이용약관 내용
            ScrollView {
                Text(termsContent)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(ThemeAwareBackground(material: .contentBackground, blendingMode: .behindWindow))
    }

    /// 현재 언어에 맞는 이용약관 파일 로드
    private func loadTermsContent() -> String {
        let language = LocalizationManager.shared.currentLanguage
        let fileName: String

        switch language {
        case .korean:
            fileName = "terms_ko"
        case .english:
            fileName = "terms_en"
        case .japanese:
            fileName = "terms_ja"
        }

        // 1. Bundle에서 파일 로드 (subdirectory 방식)
        if let url = Bundle.main.url(forResource: fileName, withExtension: "md", subdirectory: "Localization/Terms"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        // 2. Bundle에서 파일 로드 (플랫 방식 - Xcode가 번들을 평탄화할 경우)
        if let url = Bundle.main.url(forResource: fileName, withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        // 3. 기본값 (영어) - subdirectory 방식
        if let url = Bundle.main.url(forResource: "terms_en", withExtension: "md", subdirectory: "Localization/Terms"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        // 4. 기본값 (영어) - 플랫 방식
        if let url = Bundle.main.url(forResource: "terms_en", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        return L10n.get("terms.loadError")
    }
}

// MARK: - Terms Window Controller

/// 이용약관 윈도우 관리
final class TermsWindowController {
    static let shared = TermsWindowController()

    private var termsWindow: NSWindow?

    private init() {}

    /// 이용약관 윈도우 열기
    func openTermsWindow() {
        // 이미 열려있으면 포커스
        if let window = termsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let termsView = TermsOfServiceView()
        let hostingController = NSHostingController(rootView: termsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.get("terms.title")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 600))
        window.center()
        window.isReleasedWhenClosed = false

        self.termsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    TermsOfServiceView()
        .frame(width: 700, height: 600)
}
