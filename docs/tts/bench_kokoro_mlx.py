import time, numpy as np, soundfile as sf
from mlx_audio.tts.utils import load_model

t0=time.time()
model = load_model("mlx-community/Kokoro-82M-4bit")
print(f"load: {time.time()-t0:.2f}s", flush=True)

SENTS = [
  "Done.",
  "I found the bug in VoiceManager dot swift.",
  "The test suite passed with forty two tests green and no failures, so the change is safe to merge.",
  "I refactored the audio pipeline so that speech synthesis now runs off the main thread, which removes the stutter you were hearing when Claude started talking while the microphone was still active.",
]
for warm in (True, False):
    for s in SENTS:
        t=time.time(); first=None; chunks=[]
        for seg in model.generate(text=s, voice="af_heart", speed=1.0):
            if first is None: first=time.time()-t
            chunks.append(np.asarray(seg.audio))
        total=time.time()-t
        a=np.concatenate(chunks); dur=len(a)/24000
        if not warm:
            print(f"{len(s):4d} chars | audio {dur:5.2f}s | first {first*1000:6.0f}ms | total {total*1000:6.0f}ms | RTF {total/dur:.2f}", flush=True)
            sf.write(f"/tmp/k{len(s)}.wav", a, 24000)
    if warm: print("--- warm ---", flush=True)
