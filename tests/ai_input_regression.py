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
  var draft = "next message"
  var queued = 0, steered = 0
  let submission = MultiLineInputView(text:Binding(get:{draft},set:{draft=$0}),contentHeight:.constant(48),placeholder:"Write",isDisabled:false,onSubmit:{queued += 1},onImmediateSubmit:{steered += 1})
  let submitCoordinator=submission.makeCoordinator()
  let submitScroll=submission.makeNSView(coordinator:submitCoordinator)
  let submitText=submitScroll.documentView as! NSTextView
  submission.updateNSView(submitScroll,coordinator:submitCoordinator)
  _ = submitCoordinator.textView(submitText,doCommandBy:#selector(NSResponder.insertNewline(_:)))
  expect(queued == 1 && steered == 0,"Enter queues a message")
  let commandReturn = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\\r",charactersIgnoringModifiers:"\\r",isARepeat:false,keyCode:36)!
  expect(submitText.performKeyEquivalent(with:commandReturn),"Command Return is handled as a key equivalent")
  expect(steered == 1 && queued == 1,"Command Return submits an additional instruction exactly once")
  submitText.setMarkedText("한",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:0))
  _ = submitCoordinator.textView(submitText,doCommandBy:#selector(NSResponder.insertNewline(_:)))
  expect(queued == 1 && steered == 1,"IME confirmation does not submit")
  var nextDraft = "다른 채팅 초안"
  let nextComposer = MultiLineInputView(text:Binding(get:{nextDraft},set:{nextDraft=$0}),contentHeight:.constant(48),placeholder:"Write",isDisabled:false,onSubmit:{},composerID:"other-chat")
  nextComposer.updateNSView(submitScroll,coordinator:submitCoordinator)
  expect(!submitText.hasMarkedText() && submitText.string == "다른 채팅 초안", "switch restores target draft during IME composition")
  expect(nextDraft == "다른 채팅 초안", "old composition cannot overwrite destination binding")
  expect(submitText.undoManager?.canUndo != true, "conversation switch clears previous input Undo")
  print("AI input regression passed: \\(n) assertions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='textlinkeditor-ai-input-') as d:
 p=Path(d);(p/'Test.swift').write_text(prefix+s+harness)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'Test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
