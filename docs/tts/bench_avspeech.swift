import AVFoundation
import Foundation

let sents = [
 "Done.",
 "I found the bug in VoiceManager dot swift.",
 "The test suite passed with forty two tests green and no failures, so the change is safe to merge.",
 "I refactored the audio pipeline so that speech synthesis now runs off the main thread, which removes the stutter you were hearing when Claude started talking while the microphone was still active."
]
let synth = AVSpeechSynthesizer()
let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
let best = voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? voices.first!
print("voice: \(best.name) quality=\(best.quality.rawValue) (0=default,1=enhanced,2=premium)")
print("installed en voices: default=\(voices.filter{$0.quality == .default}.count) enhanced=\(voices.filter{$0.quality == .enhanced}.count) premium=\(voices.filter{$0.quality == .premium}.count)")

var idx = 0, pass = 0
func runOne() {
  if idx == sents.count { idx = 0; pass += 1; if pass == 2 { exit(0) } }
  let s = sents[idx]; idx += 1
  let u = AVSpeechUtterance(string: s); u.voice = best; u.rate = 0.5
  let t = Date(); var first: Double? = nil; var frames = 0.0; var sr = 22050.0
  synth.write(u) { buf in
    guard let p = buf as? AVAudioPCMBuffer else { return }
    if p.frameLength == 0 {
      let total = Date().timeIntervalSince(t), dur = frames/sr
      if pass == 1 {
        print(String(format: "%4d chars | audio %5.2fs | first %6.0fms | total %6.0fms | RTF %.3f", s.count, dur, (first ?? 0)*1000, total*1000, dur > 0 ? total/dur : 0))
      }
      DispatchQueue.main.async { runOne() }
      return
    }
    if first == nil { first = Date().timeIntervalSince(t) }
    frames += Double(p.frameLength); sr = p.format.sampleRate
  }
}
DispatchQueue.main.async { runOne() }
RunLoop.main.run()
