// Проверка запросов к моделям: Anthropic и совместимые с OpenAI (vLLM, Ollama, OpenRouter…).
//   swiftc -swift-version 5 Sources/UniMail/Core/Services/AIConnection.swift Tests/LinuxChecks/AI/main.swift -o aitest && ./aitest

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var passed = 0
var failed: [String] = []
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if ok { passed += 1; print("PASS \(name)") } else { failed.append("\(name) (line \(line))"); print("FAIL \(name)") }
}

func json(_ data: Data?) -> [String: Any] {
    (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
}

// Адреса.
check(AIWire.openAIURL("http://gpu:8000/v1", path: "chat/completions")?.absoluteString == "http://gpu:8000/v1/chat/completions", "vLLM url")
check(AIWire.openAIURL("http://gpu:8000/v1/", path: "models")?.absoluteString == "http://gpu:8000/v1/models", "trailing slash")
check(AIWire.openAIURL("http://gpu:8000", path: "models")?.absoluteString == "http://gpu:8000/v1/models", "adds /v1")
check(AIWire.openAIURL("http://gpu:8000/v1/chat/completions", path: "chat/completions")?.absoluteString == "http://gpu:8000/v1/chat/completions", "full endpoint pasted")
check(AIWire.openAIURL("https://api.groq.com/openai/v1", path: "models")?.absoluteString == "https://api.groq.com/openai/v1/models", "groq")
check(AIWire.openAIURL("https://openrouter.ai/api/v1", path: "chat/completions")?.absoluteString == "https://openrouter.ai/api/v1/chat/completions", "openrouter")
check(AIWire.anthropicURL("https://api.anthropic.com", path: "messages")?.absoluteString == "https://api.anthropic.com/v1/messages", "anthropic url")

// Запрос OpenAI-совместимый: без ключа — без Authorization.
var local = AIPreset.all.first { $0.id == "vllm" }!.makeConnection()
local.baseURL = "http://10.0.0.5:8000/v1"
local.model = "Qwen/Qwen2.5-7B-Instruct"
check(local.isLocal && !local.redact, "vLLM preset is local, no masking")
let r1 = try AIWire.completionRequest(local, key: nil, system: "S", user: "U")
check(r1.value(forHTTPHeaderField: "Authorization") == nil, "no auth header without key")
let b1 = json(r1.httpBody)
let msgs = b1["messages"] as? [[String: Any]] ?? []
check(b1["model"] as? String == "Qwen/Qwen2.5-7B-Instruct" && msgs.count == 2 && msgs[0]["role"] as? String == "system", "chat body")
check(r1.timeoutInterval >= 300, "long timeout for local models")
let r2 = try AIWire.completionRequest(local, key: "token", system: "S", user: "U")
check(r2.value(forHTTPHeaderField: "Authorization") == "Bearer token", "bearer key")

// Anthropic.
var claude = AIPreset.all[0].makeConnection()
let r3 = try AIWire.completionRequest(claude, key: "sk-ant", system: "S", user: "U", maxTokens: 64)
check(r3.value(forHTTPHeaderField: "x-api-key") == "sk-ant" && r3.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "anthropic headers")
check(json(r3.httpBody)["system"] as? String == "S" && json(r3.httpBody)["max_tokens"] as? Int == 64, "anthropic body")
check(!claude.isLocal && claude.redact, "cloud masks by default")
claude.baseURL = "http://localhost:4000"
check(claude.isLocal, "localhost is local")

// Ответы.
let openAIReply = Data(#"{"choices":[{"message":{"role":"assistant","content":"<think>размышляю…</think>\nГотово: встреча во вторник."}}]}"#.utf8)
check((try? AIWire.completionText(openAIReply, kind: .openAI)) == "Готово: встреча во вторник.", "openai text, think stripped")
let anthropicReply = Data(#"{"content":[{"type":"text","text":"Сводка"}]}"#.utf8)
check((try? AIWire.completionText(anthropicReply, kind: .anthropic)) == "Сводка", "anthropic text")
let empty = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
check((try? AIWire.completionText(empty, kind: .openAI)) == nil, "empty → error")
check(AIWire.errorMessage(Data(#"{"error":{"message":"model not found"}}"#.utf8)) == "model not found", "openai error")
check(AIWire.errorMessage(Data(#"{"detail":"Not Found"}"#.utf8)) == "Not Found", "vllm detail error")
check(AIWire.errorMessage(Data(#"{"error":"bad key"}"#.utf8)) == "bad key", "string error")
check(AIWire.modelIDs(Data(#"{"object":"list","data":[{"id":"b-model"},{"id":"a-model"}]}"#.utf8)) == ["a-model", "b-model"], "models list")
check(AIWire.modelIDs(Data(#"{"models":[{"name":"llama3:8b"}]}"#.utf8)) == ["llama3:8b"], "ollama native list")
check(AIRequestError.http(404, nil).errorDescription?.contains("/v1") == true, "404 hint")

print("\n\(passed) passed, \(failed.count) failed")
for f in failed { print("  FAIL \(f)") }
exit(failed.isEmpty ? 0 : 1)
