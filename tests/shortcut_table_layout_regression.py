#!/usr/bin/env python3
"""Run the production shortcut table with isolated preferences; catch offscreen row-height drift."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'TextlinkEditor/Views/Settings/ShortcutsSettingsView.swift').read_text()
view=s[s.index('struct ShortcutsSettingsView:'):len(s)]
manager=(root/'TextlinkEditor/Services/Core/KeyboardShortcutManager.swift').read_text() + '\n' + (root / 'TextlinkEditor/Services/Core/Shortcuts/ShortcutModels.swift').read_text()
a=manager.index('    private var shortcutsFileURL: URL {'); b=manager.index('    private var registrationObserver',a)
manager=manager[:a]+'''    private var shortcutsFileURL: URL { URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("keys.json") }
'''+manager[b:]
pre='''import SwiftUI
import AppKit
enum L10n {
 static let values = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String:String]
 static func get(_ key: String) -> String { values[key] ?? key }
}
enum AppColors {
 static let textSecondary = Color.secondary, textTertiary = Color.secondary, toolbarIcon = Color.primary
 static let savedIndicator = Color.green, controlBackground = Color.gray.opacity(0.1)
}
struct ShortcutEditSheet: View { let binding: ShortcutBinding; let onSave: (ShortcutBinding)->Void; var body: some View { EmptyView() } }
'''
harness='''
func descendants(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(descendants) }
let app=NSApplication.shared
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:450),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
let host=NSHostingView(rootView:ShortcutsSettingsView())
window.contentView=host
window.orderFront(nil)
func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03)); host.layoutSubtreeIfNeeded() }
settle()
let table=descendants(host).compactMap {$0 as? NSTableView}.first!
let scroll=table.enclosingScrollView!
print("INITIAL", table.usesAutomaticRowHeights, table.rowHeight,table.frame.height)
var previousHeight=table.frame.height
var changed=0
for n in 1...65 {
 let target=CGFloat(n)*12
 scroll.contentView.scroll(to:NSPoint(x:0,y:target)); scroll.reflectScrolledClipView(scroll.contentView)
 let requested=scroll.contentView.bounds.minY
 settle()
 let actual=scroll.contentView.bounds.minY
 if abs(actual-requested)>0.1 || abs(table.frame.height-previousHeight)>0.1 {
  print("SHIFT",n,requested,actual,previousHeight,table.frame.height); changed += 1
 }
 previousHeight=table.frame.height
}
precondition(changed == 0, "Revealing offscreen shortcut controls must not change document height or offset")
precondition(!table.usesAutomaticRowHeights && table.rowHeight == 32)
for width in [CGFloat(600), CGFloat(1000)] {
 window.setContentSize(NSSize(width:width,height:450)); settle()
 let expectedHeight=table.frame.height
 for n in stride(from:65,through:1,by:-1) {
  scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(n)*12)); scroll.reflectScrolledClipView(scroll.contentView)
  let requested=scroll.contentView.bounds.minY
  settle()
  precondition(abs(table.frame.height-expectedHeight)<1, "Resize/reverse scroll changed table height")
  precondition(abs(scroll.contentView.bounds.minY-requested)<1, "Middle scroll position moved without input")
 }
}
let expectedHeight=table.frame.height
let manager=KeyboardShortcutManager.shared
for binding in manager.bindings.prefix(12) { manager.toggleEnabled(for:binding.action) }
settle()
precondition(abs(table.frame.height-expectedHeight)<1, "Disabled badges must not shrink rows")
print("PASS production four-column shortcut table: stable height/offset, forward/reverse scrolling, narrow/wide windows, disabled controls")
'''
with tempfile.TemporaryDirectory() as d:
 d=Path(d);(d/'main.swift').write_text(pre+view+harness);(d/'Manager.swift').write_text(manager)
 subprocess.run(['swiftc',str(root/'TextlinkEditor/Services/Core/EditorToolRegistry.swift'),str(d/'Manager.swift'),str(d/'main.swift'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test'),str(d),str(root/'TextlinkEditor/Localization/Strings/ko.json')],check=True)
