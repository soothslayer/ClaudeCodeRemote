import sys, time, numpy as np, soundfile as sf
from kokoro_onnx import Kokoro
m = sys.argv[1]
t0=time.time(); k = Kokoro(m, "voices-v1.0.bin"); print(f"{m}  load: {time.time()-t0:.2f}s", flush=True)
SENTS=["Done.",
 "I found the bug in VoiceManager dot swift.",
 "The test suite passed with forty two tests green and no failures, so the change is safe to merge.",
 "I refactored the audio pipeline so that speech synthesis now runs off the main thread, which removes the stutter you were hearing when Claude started talking while the microphone was still active."]
for p in (0,1):
    for s in SENTS:
        t=time.time(); a,sr = k.create(s, voice="af_heart", speed=1.0, lang="en-us"); el=time.time()-t
        dur=len(a)/sr
        if p: print(f"{len(s):4d} chars | audio {dur:5.2f}s | total {el*1000:6.0f}ms | RTF {el/dur:.3f}", flush=True)
        if p and m.endswith("v1.0.onnx"): sf.write(f"{sys.path[0]}/onnx_{len(s)}.wav", a, sr)
