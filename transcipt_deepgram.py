import requests
import sys
import json
import os

# ===== CONFIG =====
API_KEY = os.getenv("DEEPGRAM_API_KEY")

if not API_KEY:
    print("❌ Set DEEPGRAM_API_KEY")
    sys.exit(1)

if len(sys.argv) < 2:
    print("Usage: python3 deepgram.py <audio_file>")
    sys.exit(1)

audio_file = sys.argv[1]

if not os.path.exists(audio_file):
    print(f"❌ File not found: {audio_file}")
    sys.exit(1)

# ===== API =====
url = "https://api.deepgram.com/v1/listen?model=nova-3&language=en&multichannel=true&punctuate=true"

with open(audio_file, "rb") as f:
    response = requests.post(
        url,
        headers={
            "Authorization": f"Token {API_KEY}",
            "Content-Type": "audio/wav"
        },
        data=f
    )

if response.status_code != 200:
    print("❌ Error:", response.text)
    sys.exit(1)

result = response.json()

# ===== SAVE RAW JSON =====
json_file = os.path.splitext(os.path.basename(audio_file))[0] + "_deepgram.json"
with open(json_file, "w") as f:
    json.dump(result, f, indent=2)

# ===== EXTRACT =====
try:
    channels = result["results"]["channels"]
except KeyError:
    print("❌ Invalid response")
    print(json.dumps(result, indent=2))
    sys.exit(1)

# ===== SMART SEGMENT FUNCTION =====
def get_segments(channel_data):
    alt = channel_data["alternatives"][0]
    words = alt.get("words", [])

    segments = []
    current_words = []
    start_time = None
    last_end = None

    PAUSE_THRESHOLD = 1.0  # adjust (0.8 = more splits, 1.5 = fewer)

    for w in words:
        word = w["word"]
        w_start = w["start"]
        w_end = w["end"]

        if start_time is None:
            start_time = w_start

        # Split on pause
        if last_end is not None and (w_start - last_end) > PAUSE_THRESHOLD:
            segments.append((start_time, last_end, " ".join(current_words)))
            current_words = []
            start_time = w_start

        current_words.append(word)
        last_end = w_end

        # Split on punctuation
        if word.endswith((".", "?", "!")):
            segments.append((start_time, w_end, " ".join(current_words)))
            current_words = []
            start_time = None
            last_end = None

    if current_words:
        segments.append((start_time, last_end, " ".join(current_words)))

    return segments

# ===== GET BOTH SIDES =====
caller_segments = get_segments(channels[0])  # Channel 0 = Caller
callee_segments = get_segments(channels[1])  # Channel 1 = Callee

# ===== MERGE =====
i = j = 0
dialogue = []

while i < len(caller_segments) or j < len(callee_segments):
    if i < len(caller_segments) and (
        j >= len(callee_segments) or caller_segments[i][0] <= callee_segments[j][0]
    ):
        dialogue.append(("Caller", caller_segments[i]))
        i += 1
    else:
        dialogue.append(("Callee", callee_segments[j]))
        j += 1

# ===== PRINT OUTPUT =====
print("\n📝 Conversation:\n")

for speaker, (start, end, text) in dialogue:
    print(f"[{start:.2f}s - {end:.2f}s] {speaker}: {text}")

# ===== SAVE TXT =====
txt_file = os.path.splitext(audio_file)[0] + "_dialogue.txt"

with open(txt_file, "w") as f:
    for speaker, (start, end, text) in dialogue:
        f.write(f"[{start:.2f}-{end:.2f}] {speaker}: {text}\n")

print(f"\n✅ Saved JSON: {json_file}")
print(f"✅ Saved TXT: {txt_file}")
