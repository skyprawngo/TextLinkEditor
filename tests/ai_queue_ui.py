#!/usr/bin/env python3
"""Build an isolated native queue/composer interaction fixture; no inference or user projects."""
from pathlib import Path
import subprocess, plistlib
root=Path(__file__).resolve().parents[1]
app=Path('/tmp/TextlinkQueueValidation.app')
binary=app/'Contents/MacOS/TextlinkQueueValidation'
binary.parent.mkdir(parents=True,exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.textlink.queue.validation','CFBundleName':'TextlinkQueueValidation','CFBundleExecutable':binary.name,'CFBundlePackageType':'APPL'}))
s='''import SwiftUI
import AppKit
struct AIQueuedMessage: Identifiable { let id = UUID(); var text: String }
enum AppColors { static let textPrimary = Color.primary; static let accent = Color.blue }
enum L10n {
 static let values = (try! JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"LOCALE_PATH")))) as! [String:String]
 static func get(_ key:String)->String { values[key] ?? key }
}
struct Fixture: View {
 @State var messages = [AIQueuedMessage(text:"첫 번째 대기 메시지"),AIQueuedMessage(text:"두 번째 대기 메시지"),AIQueuedMessage(text:"세 번째 대기 메시지")]
 @State var draft = ""
 @State var height:CGFloat = 48
 @State var focus = 0
 var body: some View {
  VStack {
   Text("AI 응답 중 · 대기열 검증").padding(20)
   Spacer()
   AIMessageQueueView(messages:messages,isProcessing:true,steeringMessageID:nil,
    onRemove:{id in messages.removeAll{$0.id==id};print("DELETE",messages.map(\\.text))},
    onRecover:{id in
     let old=messages.remove(at:messages.firstIndex{$0.id==id}!)
     if !draft.isEmpty { messages.append(.init(text:draft)) }
     draft=old.text; focus += 1; print("RECOVER",draft)
    },
    onSteer:{id in print("STEER",messages.first{$0.id==id}!.text);messages.removeAll{$0.id==id}},
    onMove:{source,target in
     guard let from=messages.firstIndex(where:{$0.id==source}),let to=messages.firstIndex(where:{$0.id==target}) else{return}
     let item=messages.remove(at:from);messages.insert(item,at:to);print("MOVE",messages.map(\\.text))
    },onResume:{})
   MultiLineInputView(text:$draft,contentHeight:$height,placeholder:"응답 중에도 입력할 수 있습니다",isDisabled:false,minHeight:48,maxHeight:160,
    onSubmit:{messages.append(.init(text:draft));print("QUEUE",draft);draft=""},
    onImmediateSubmit:{print("IMMEDIATE",draft);draft=""},focusRequest:focus)
    .frame(height:height).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:20)).padding(8)
  }.frame(width:700,height:460).preferredColorScheme(.dark)
 }
}
@main struct Main {
 @MainActor static func main() {
  freopen("/tmp/textlink-queue-ui.log","w",stdout);setbuf(stdout,nil)
  let app=NSApplication.shared;app.setActivationPolicy(.regular)
  let window=NSWindow(contentRect:NSRect(x:200,y:200,width:700,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false)
  window.title="Textlink queue validation";window.contentView=NSHostingView(rootView:Fixture());window.makeKeyAndOrderFront(nil)
  app.activate(ignoringOtherApps:true);app.run()
 }
}
'''.replace('LOCALE_PATH',str(root/'TextlinkEditor/Localization/Strings/ko.json'))
p=Path('/tmp/TextlinkQueueValidation.swift');p.write_text(s)
subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),str(root/'TextlinkEditor/Services/AI/Requests/AIChatMode.swift'),str(root/'TextlinkEditor/Views/MainEditor/AIAssistant/Chat/MultiLineInputView.swift'),str(root/'TextlinkEditor/Views/MainEditor/AIAssistant/Chat/AIMessageQueueView.swift'),str(root/'TextlinkEditor/Views/MainEditor/AIAssistant/Chat/AIQueueReordering.swift'),'-o',str(binary)],check=True)
print(app)
