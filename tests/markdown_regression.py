#!/usr/bin/env python3
"""Exercise the production CommonMark/GFM parser and source-preserving AppKit renderer."""
from pathlib import Path
import subprocess
import tempfile
from markdown_test_support import markdown_flags

root = Path(__file__).resolve().parents[1]
harness = r'''
import AppKit
setbuf(stdout, nil)
func expect(_ value: Bool, _ message: String) { precondition(value, message); print("PASS " + message) }
let source = #"""
# 한글 😀 **강조와 *중첩***

Setext 제목
===========

> 인용 **bold**
> 1. ordered
>    - nested

- [x] done
- [ ] pending

| 이름 | 값 |
| :--- | ---: |
| **한글** | 12 |

~~취소~~ [링크](https://example.com) [참조][ref]
<https://example.org> ![이미지](https://example.com/a.png)

[ref]: https://example.net "reference"

~~~swift
# code **literal**
~~~

    indented **literal**

`inline **literal**` <u>밑줄</u>

---

<script>alert('not executed')</script>

escaped \*literal\* &amp;  
hard break
"""#
let syntax = MarkdownSyntaxDocument(source: source)
let kinds = syntax.spans.map(\.kind)
expect(kinds.contains(.heading(1)), "ATX and Setext headings")
expect(kinds.contains(.strong) && kinds.contains(.emphasis) && kinds.contains(.strike), "nested inline emphasis and GFM strike")
expect(kinds.contains(.quote) && kinds.contains(.list), "nested block quote and lists")
expect(kinds.contains(.task(true)) && kinds.contains(.task(false)), "GFM task list states")
expect(kinds.contains(.table) && kinds.contains(.tableHeader), "GFM tables and header")
expect(kinds.contains(.code) && kinds.filter { $0 == .codeBlock }.count == 2, "inline, fenced and indented code")
expect(kinds.contains(.link("https://example.net")) && kinds.contains(.link("https://example.org")), "reference and autolinks resolve")
expect(kinds.contains(.image("https://example.com/a.png")) && kinds.contains(.html), "images and raw HTML are recognized without execution")
expect(kinds.contains(.thematicBreak) && kinds.contains(.underline), "thematic break and existing underline extension")
let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 16)])
MarkdownSourceStyling.apply(to: storage, selection: NSRange(location: storage.length, length: 0), font: .systemFont(ofSize: 16), document: syntax)
expect(storage.string == source, "all rendering preserves source bytes")
let body = source as NSString
let bold = storage.attribute(.font, at: body.range(of: "중첩").location, effectiveRange: nil) as! NSFont
let italic = NSFontManager.shared.traits(of: bold).contains(.italicFontMask)
    || (storage.attribute(.obliqueness, at: body.range(of: "중첩").location, effectiveRange: nil) as? Double ?? 0) > 0
expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask) && italic, "nested emphasis composes with heading traits, including CJK fallback")
let codeRange = body.range(of: "# code **literal**")
expect(!syntax.spans.contains { $0.kind == .strong && NSIntersectionRange($0.range, codeRange).length > 0 }, "code blocks never parse emphasis")
let unsafe = NSTextStorage(string: "[unsafe](javascript:alert) [safe](https://example.com)")
MarkdownSourceStyling.apply(to: unsafe, selection: .init(location: 0, length: 0), font: .systemFont(ofSize: 16))
expect(unsafe.attribute(.link, at: 1, effectiveRange: nil) == nil, "unsafe link schemes are not activated")
let unicode = "😀 한글 **굵게**\r\n다음 **둘째**"
let unicodeBold = MarkdownSyntaxDocument(source: unicode).spans.filter { $0.kind == .strong }
expect(unicodeBold.map { (unicode as NSString).substring(with: $0.range) } == ["**굵게**", "**둘째**"],
       "Korean and emoji source positions are exact across CRLF")
for text in ["😀 한글 **굵게**\r\n끝", "e\u{301} **bold**\r끝", "\t**tab**\n", "# 제목\n", "***", "~~~\n**unfinished"] {
    let parsed = MarkdownSyntaxDocument(source: text)
    expect(parsed.spans.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= text.utf16.count }, "UTF-8 source ranges map safely to UTF-16")
}
print("MARKDOWN REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-markdown-') as tmp:
    directory = Path(tmp)
    main = directory / 'main.swift'
    main.write_text(harness)
    module = root / 'TextlinkEditor/Services/Editor/Markdown'
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), str(module / 'MarkdownSyntaxDocument.swift'), str(module / 'MarkdownSourceStyling.swift'), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
