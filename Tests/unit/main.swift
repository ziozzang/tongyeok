// Unit checks for SentenceSplitter / NoiseFilter / Transliteration / RetryPolicy.
// build: xcrun swiftc -target arm64-apple-macosx26.0 -o build/unit Tests/unit/main.swift Sources/Shared/{SentenceAssembler,Common,Translator}.swift
import Foundation
var fails = 0
func check(_ cond: Bool, _ msg: String) { print(cond ? "ok  " : "FAIL", msg); if !cond { fails += 1 } }
func split(_ t: String, _ l: String) -> (String, String) { let r = SentenceSplitter.split(t, lang: l); return (r.complete, r.rest) }

// English
check(split("Let's start the meeting now.", "en") == ("Let's start the meeting now.", ""), "en complete")
check(split("We reviewed the results and.", "en").1 == "We reviewed the results and.", "en forced period after 'and' is held")
check(split("Good morning. Today we will review the", "en") == ("Good morning.", "Today we will review the"), "en split complete + tail")
check(split("Can everyone hear me?", "en").1 == "", "en question complete")
check(split("heart rate variability and then", "en").0 == "", "en no punctuation held")
// Korean
check(split("오늘 회의를 시작하겠습니다.", "ko").1 == "", "ko -습니다 complete")
check(split("그래서 우리가 이번 분기에는.", "ko").1 != "", "ko particle '-에는.' held")
check(split("예산을 검토했는데.", "ko").1 != "", "ko connective '-는데.' held")
check(split("좋습니다. 그럼 첫 번째 안건은", "ko") == ("좋습니다.", "그럼 첫 번째 안건은"), "ko split complete + tail")
check(split("그렇죠?", "ko").1 == "", "ko question complete")
check(split("네, 알겠어요.", "ko").1 == "", "ko -요 complete")
// Noise
check(NoiseFilter.isNoise(".", confidence: 0.9), "noise: lone period")
check(NoiseFilter.isNoise(", ..", confidence: 0.9), "noise: punctuation")
check(NoiseFilter.isNoise("Um, uh.", confidence: 0.9), "noise: fillers en")
check(NoiseFilter.isNoise("음...", confidence: 0.9), "noise: filler ko")
check(NoiseFilter.isNoise("They", confidence: 0.4), "noise: tiny + unsure")
check(!NoiseFilter.isNoise("네.", confidence: 0.9), "keep: 네 (yes)")
check(!NoiseFilter.isNoise("OK.", confidence: 0.9), "keep: OK")
check(!NoiseFilter.isNoise("Let's start.", confidence: 0.8), "keep: sentence")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")

// Continuation / merge (observed ASR output with mid-sentence pauses)
check(split("이번 분기 실적을 검토한 결과.", "ko").1 != "", "ko bare noun + forced period held")
check(split("마케팅 예산을 늘리기로.", "ko").1 != "", "ko '-로.' held")
check(split("질문 있으신가요?", "ko").1 == "", "ko question complete")
check(split("그렇게 하니까.", "ko").1 != "", "ko '-니까.' (connective) held, not '-까' question")
check(SentenceSplitter.isContinuation("And decided to increase the budget.", lang: "en"), "en 'And ...' continues")
check(SentenceSplitter.isContinuation("For the next 2 quarters.", lang: "en"), "en 'For ...' continues")
check(!SentenceSplitter.isContinuation("Any questions?", lang: "en"), "en 'Any questions?' is new")
check(SentenceSplitter.mergeContinuation("We reviewed the quarterly results.", "And decided to increase the budget.", lang: "en")
      == "We reviewed the quarterly results and decided to increase the budget.", "en merge drops fake period + lowercases")
check(SentenceSplitter.mergeContinuation("So.", "I think NASA agrees.", lang: "en") == "So I think NASA agrees.", "en merge keeps 'I'")
check(SentenceSplitter.mergeContinuation("이번 분기 실적을 검토한 결과.", "마케팅 예산을 늘리기로.", lang: "ko")
      == "이번 분기 실적을 검토한 결과 마케팅 예산을 늘리기로.", "ko merge")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
check(SentenceSplitter.clearlyContinues("we decided to increase the budget and", lang: "en"), "en tail 'and' clearly continues")
check(!SentenceSplitter.clearlyContinues("Any questions", lang: "en"), "en 'Any questions' not clearly continuing")
check(SentenceSplitter.clearlyContinues("예산을 검토했는데", lang: "ko"), "ko '-는데' clearly continues")
// Two-lane auto-detect: one lane transliterating English speech
func translit(_ en: String, _ ko: String) -> Bool { Transliteration.otherIsTransliteratedEnglish(en: en, other: ko, otherCode: "ko") }
check(translit("Yes.", "예스."), "translit: Yes / 예스")
check(translit("Hello everyone. Thank you for joining today's meeting.", "헬로 에브리원 땡큐 포 조이닝 투데이 스미팅."), "translit: hello everyone")
check(!translit("They.", "네."), "real ko: 네")
check(!translit("Maketing, timidan, kachi, firu.", "마케팅 팀이랑 같이 회의를 잡아주세요."), "real ko: en lane is gibberish")
check(!translit("Meeting schedule job a ju say yo.", "미팅 스케줄을 잡아주세요."), "real ko with loanwords: grammar wins")
check(!translit("And.", "안녕하세요 오늘 회의는 3분기 실적부터 시작하겠습니다."), "real ko: different sounds")
// Retry policy
check(RetryPolicy.isTransient(HTTPStatusError(service: "LLM", status: 503, body: "")), "retry: 503")
check(RetryPolicy.isTransient(HTTPStatusError(service: "LLM", status: 429, body: "")), "retry: 429")
check(!RetryPolicy.isTransient(HTTPStatusError(service: "LLM", status: 401, body: "")), "no retry: 401")
check(RetryPolicy.isTransient(URLError(.timedOut)), "retry: timeout")
check(!RetryPolicy.isTransient(URLError(.cancelled)), "no retry: cancelled")
check(!RetryPolicy.isTransient(AppError.translate("no endpoint")), "no retry: config error")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
