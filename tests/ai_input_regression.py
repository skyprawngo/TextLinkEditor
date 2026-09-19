#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'TextlinkEditor/Views/MainEditor/AIAssistant/Chat/MultiLineInputView.swift').read_text()
s=s[s.index('struct MultiLineInputView:'):s.index('// MARK: - 대화 카드 뷰')]
# NSViewRepresentable.Context has no public initializer. Replace only construction signature.
s=s.replace('struct MultiLineInputView: NSViewRepresentable','struct MultiLineInputView').replace('context: Context','coordinator: Coordinator').replace('context.coordinator','coordinator')
s += '\n' + (root/'TextlinkEditor/Services/AI/Requests/AIChatMode.swift').read_text()
prefix='''import AppKit
import SwiftUI
enum L10n { static func get(_ key: String) -> String { key } }
enum AppColors { static let textPrimary = Color.primary; static let accent = Color.blue }
'''
harness='''
@main struct Test {
 @MainActor static func main() {
  var n=0
  func expect(_ ok:Bool,_ label:String){ precondition(ok,label);n+=1;print("PASS "+label) }
  let view=MultiLineInputView(text:.constant(""),contentHeight:.constant(32),placeholder:"Write",isDisabled:false,onSubmit:{})
  let coordinator=view.makeCoordinator()
  let scroll=view.makeNSView(coordinator:coordinator)
  scroll.frame=NSRect(x:0,y:0,width:250,height:32)
  scroll.layoutSubtreeIfNeeded()
  view.updateNSView(scroll,coordinator:coordinator)
  let text=scroll.documentView as! NSTextView
  expect(text.frame.height >= 32,"empty input has clickable height")
  expect(text.frame.width >= 200,"input follows available width")
  expect(text.textContainer!.containerSize.width <= 250,"text wraps within input width")
  let placeholder=text.subviews.first!
  expect(placeholder.hitTest(NSPoint(x:2,y:2)) == nil,"placeholder cannot intercept typing focus")
  text.insertText("한글 😀",replacementRange:NSRange(location:0,length:0))
  expect(text.string == "한글 😀","native Unicode input")
  text.setSelectedRange(NSRange(location:0,length:(text.string as NSString).length))
  text.insertText("replacement",replacementRange:text.selectedRange())
  expect(text.string == "replacement","native selection replacement")
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:250,height:80),styleMask:[.titled],backing:.buffered,defer:false)
  window.contentView=scroll
  expect(window.makeFirstResponder(text),"input can become first responder")
  print("AI input regression passed: \\(n) assertions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='textlinkeditor-ai-input-') as d:
 p=Path(d);(p/'Test.swift').write_text(prefix+s+harness)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'Test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
