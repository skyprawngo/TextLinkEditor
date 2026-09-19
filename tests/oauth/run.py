#!/usr/bin/env python3
from pathlib import Path
import tempfile,subprocess,os
root=Path(__file__).resolve().parents[2]
fixture=r'''#!/usr/bin/env python3
import sys,json,os
assert 'CODEX_HOME' in os.environ
assert 'OPENAI_API_KEY' not in os.environ
assert 'CODEX_ACCESS_TOKEN' not in os.environ
for line in sys.stdin:
 q=json.loads(line);m=q.get('method');i=q.get('id')
 if i is None:continue
 if m=='initialize':r={'userAgent':'fixture'}
 elif m=='account/read':r={'account':{'type':'chatgpt','email':'fixture@example.test','planType':'plus'}}
 elif m=='account/login/start':r={'loginId':'fixture-id','authUrl':'https://auth.openai.com/oauth/authorize?state=fixture'}
 elif m=='account/logout':r={}
 elif m=='fixture/hang':continue
 elif m=='fixture/error':
  print(json.dumps({'id':i,'error':{'code':-1,'message':'fixture'}}),flush=True);continue
 else:r={}
 print(json.dumps({'id':i,'result':r}),flush=True)
'''
harness=r'''
import Foundation
import AppKit
struct L10n { static func get(_ key:String)->String { key } }
final class CLIDetector {
 static let shared = CLIDetector()
 static let searchPaths = ["/usr/bin","/bin"]
 enum Kind { case chatgpt }
 func resolvedPath(for: Kind) async -> String? { nil }
}
@main struct Regression {
 @MainActor static func main() async throws {
  var count=0
  func expect(_ ok:Bool,_ label:String){ precondition(ok,label);count+=1;print("PASS "+label) }
  expect(ChatGPTAccountService.validLoginURL("https://auth.openai.com/oauth/authorize") != nil,"OpenAI browser URL")
  expect(ChatGPTAccountService.validLoginURL("https://chatgpt.com/auth") != nil,"ChatGPT browser URL")
  expect(ChatGPTAccountService.validLoginURL("http://auth.openai.com/auth") == nil,"reject HTTP")
  expect(ChatGPTAccountService.validLoginURL("https://auth.openai.com.attacker.test/") == nil,"reject foreign host")
  expect(ChatGPTAccountService.validLoginURL("https://user:secret@auth.openai.com/") == nil,"reject URL credentials")
  expect(ChatGPTAccount.parse(["account":["type":"apiKey"]]) == nil,"API key cannot become subscription")
  expect(ChatGPTAccount.parse(["account":NSNull()]) == nil,"logged out remains logged out")
  let root=URL(fileURLWithPath:CommandLine.arguments[2])
  let env=LoreCodexEnvironment.environment(root:root)
  expect(env["CODEX_HOME"]==root.path,"private account directory")
  expect(env["OPENAI_API_KEY"]==nil && env["CODEX_ACCESS_TOKEN"]==nil,"inherited credentials removed")
  expect(LoreCodexEnvironment.arguments.contains("cli_auth_credentials_store=\"keyring\""),"Keychain required without plaintext fallback")
  let rpc=CodexRPCConnection()
  try rpc.start(path:CommandLine.arguments[1],root:root)
  let initResult=try await rpc.request("initialize",["clientInfo":["name":"textlinkeditor-test","version":"1"]])
  expect(initResult["userAgent"] as? String == "fixture","initialize round trip")
  try rpc.notify("initialized")
  let result=try await rpc.request("account/read",["refreshToken":false])
  expect(ChatGPTAccount.parse(result)?.plan == "plus","subscription identity parsing")
  let login=try await rpc.request("account/login/start",["type":"chatgpt"])
  expect(login["loginId"] as? String == "fixture-id","login correlation id")
  do { _ = try await rpc.request("fixture/error");preconditionFailure() } catch { expect(true,"RPC error fails request") }
  let hanging=Task { try await rpc.request("fixture/hang") }
  await Task.yield()
  rpc.close()
  do { _ = try await hanging.value;preconditionFailure() } catch { expect(true,"close rejects pending request") }
  expect(!rpc.running,"cancel terminates callback server")
  let attrs=try FileManager.default.attributesOfItem(atPath:root.path)
  expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,"private directory permissions")
  print("OAuth regression passed: \(count) assertions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='textlinkeditor-oauth-test-') as d:
 p=Path(d);f=p/'fixture';f.write_text(fixture);f.chmod(0o700);h=p/'Regression.swift';h.write_text(harness)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'TextlinkEditor/Services/AI/Auth/ChatGPTAccountService.swift'),str(root/'TextlinkEditor/Services/AI/CLI/CodexRPCConnection.swift'),str(root/'TextlinkEditor/Services/AI/Models/AICLIType.swift'),str(h),'-o',str(p/'test')],check=True)
 env=dict(os.environ,OPENAI_API_KEY='fixture-not-real',CODEX_ACCESS_TOKEN='fixture-not-real')
 subprocess.run([str(p/'test'),str(f),str(p/'private')],env=env,check=True,timeout=40)
