import Foundation

/// Meeting minutes from a finished transcript via an OpenAI-compatible chat model.
/// Long meetings are summarized in chunks first, then merged (map-reduce), so any context size works.
struct MinutesGenerator {
    var baseURL: String
    var apiKey: String
    var model: String
    var language: Language            // language the minutes are written in
    var extraInstructions = ""        // user's own wishes (format, focus, names…)
    /// Transcript characters per request; bigger transcripts go through chunk notes first.
    var chunkChars = 40_000

    struct Line {
        let time: Date
        let speaker: String?          // "화자 1", nil = unknown
        let lang: String
        let source: String
        let translation: String
    }

    static func transcript(_ lines: [Line]) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return lines.map { l in
            var s = "[\(f.string(from: l.time))] \(l.speaker ?? "?") (\(l.lang)): \(l.source)"
            if !l.translation.isEmpty { s += "\n    → \(l.translation)" }
            return s
        }.joined(separator: "\n")
    }

    func generate(_ lines: [Line], progress: (String) -> Void = { _ in }) async throws -> String {
        let text = Self.transcript(lines)
        guard text.count > chunkChars else {
            progress("회의록 작성 중…")
            return try await complete(system: minutesPrompt, user: text)
        }
        // Map: notes per chunk (split on line boundaries), then reduce into one set of minutes.
        var chunks: [String] = [], cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if cur.count + line.count > chunkChars, !cur.isEmpty { chunks.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { chunks.append(cur) }
        var notes: [String] = []
        for (i, c) in chunks.enumerated() {
            progress("회의록 작성 중… (\(i + 1)/\(chunks.count + 1))")
            notes.append(try await complete(system: notesPrompt, user: c))
        }
        progress("회의록 작성 중… (\(chunks.count + 1)/\(chunks.count + 1))")
        let merged = notes.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
        return try await complete(system: minutesPrompt + "\n\nThe input is detailed notes of consecutive parts of one meeting (not the raw transcript). Merge them.",
                                  user: merged)
    }

    private var minutesPrompt: String {
        let l = language.name
        var s = """
        You write meeting minutes from an automatic speech-recognition transcript.
        Each line: [time] speaker (language): original text, optionally followed by "→ translation".
        Speakers were labeled automatically by voice ("화자 1", "화자 2", …; "?" = unknown) and may occasionally be wrong.
        The transcript may contain recognition errors; infer the intended meaning, never invent facts.

        Write the minutes in \(l), as Markdown, with exactly these sections (headings translated into \(l)):
        ## Summary — 3-6 sentences: purpose, main outcome.
        ## Discussion — bullet points per topic, who said what that matters (use speaker labels).
        ## Decisions — bullet list; if nothing was decided, say so in one short line in \(l).
        ## Action items — a table with columns Owner | Task | Due (column headers also in \(l)). Owner = speaker label; if the transcript makes a speaker's
           real name clear (e.g. someone is addressed as "Evan"), write it as "화자 4 (Evan)". Unknown due date = "-".
        ## Open questions — unresolved points; omit the section if there are none.

        Rules: be concise and factual; keep names, numbers and dates exactly; no preamble, no closing remarks,
        output only the Markdown (no code fences).
        """
        let extra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { s += "\n\nAdditional instructions from the user:\n\(extra)" }
        return s
    }

    private var notesPrompt: String {
        """
        This is one part of a longer meeting transcript (format: [time] speaker (language): text, optional "→ translation").
        Write detailed notes in \(language.name): topics discussed, who said what (keep speaker labels and any real names),
        every decision, every task with its owner and due date, open questions. Keep numbers and dates exactly. Markdown bullets only.
        """
    }

    private func complete(system: String, user: String) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw AppError.translate("LLM API 엔드포인트가 설정되지 않았습니다 (설정 ⌘,).") }
        guard let url = URL(string: base.hasSuffix("/chat/completions") ? base : base + "/chat/completions") else {
            throw AppError.translate("잘못된 URL: \(base)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ] as [String: Any])
        var lastError: Error?
        for attempt in 0..<2 {   // one retry for transient failures
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                    throw AppError.translate("회의록 LLM HTTP \(http.statusCode): \(body)")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                      let content = msg["content"] as? String else { throw AppError.translate("회의록 응답 파싱 실패") }
                return Self.stripFences(LLMTranslator.clean(content, final: true))
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        throw lastError!
    }

    /// Models sometimes wrap the whole answer in ```markdown … ``` despite being told not to.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
