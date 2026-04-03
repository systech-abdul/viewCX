import os
import sys
import signal
import logging
import json
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

from freeswitchESL import ESL
import psycopg2
from psycopg2 import pool
import requests

# ---------------- Configuration ----------------
PG_CONN = {
    'dbname': 'fusionpbx',
    'user': 'fusionpbx',
    'password': 'pyiEcKPfI75X22Q4JNU0HGgoYjk',
    'host': '127.0.0.1',
    'port': 5432
}

ESL_HOST = "127.0.0.1"
ESL_PORT = "8021"
ESL_PASSWORD = "ClueCon"

MAX_WORKERS = 10
DB_POOL_MIN = 1
DB_POOL_MAX = 10

DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY")
DEEPGRAM_URL = "https://api.deepgram.com/v1/listen?model=nova-3&language=en&multichannel=true&punctuate=true"
PAUSE_THRESHOLD = 1.0  # seconds

# ---------------- Logging ----------------
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)

# ---------------- Global Objects ----------------
executor = ThreadPoolExecutor(max_workers=MAX_WORKERS)
DB_POOL = None

# ---------------- DB Pool ----------------
def init_db_pool():
    global DB_POOL
    DB_POOL = psycopg2.pool.SimpleConnectionPool(DB_POOL_MIN, DB_POOL_MAX, **PG_CONN)
    if not DB_POOL:
        logging.error("❌ Failed to initialize DB pool")
        sys.exit(1)
    logging.info("✅ Database connection pool ready")

def get_db_conn():
    try:
        return DB_POOL.getconn()
    except Exception:
        logging.exception("❌ Could not get DB connection from pool")
        return None

def release_db_conn(conn):
    if conn:
        DB_POOL.putconn(conn)

# ---------------- Deepgram Integration ----------------
def transcribe_audio(file_path):
    if not os.path.exists(file_path):
        logging.error(f"File not found for transcription: {file_path}")
        return None

    with open(file_path, "rb") as f:
        response = requests.post(
            DEEPGRAM_URL,
            headers={
                "Authorization": f"Token {DEEPGRAM_API_KEY}",
                "Content-Type": "audio/wav"
            },
            data=f
        )

    if response.status_code != 200:
        logging.error(f"Deepgram API error: {response.text}")
        return None

    result = response.json()
    try:
        channels = result["results"]["channels"]
    except KeyError:
        logging.error(f"Invalid Deepgram response: {json.dumps(result, indent=2)}")
        return None

    def get_segments(channel_data):
        alt = channel_data["alternatives"][0]
        words = alt.get("words", [])
        segments = []
        current_words = []
        start_time = None
        last_end = None

        for w in words:
            word = w["word"]
            w_start = w["start"]
            w_end = w["end"]

            if start_time is None:
                start_time = w_start

            if last_end is not None and (w_start - last_end) > PAUSE_THRESHOLD:
                segments.append((start_time, last_end, " ".join(current_words)))
                current_words = []
                start_time = w_start

            current_words.append(word)
            last_end = w_end

            if word.endswith((".", "?", "!")):
                segments.append((start_time, w_end, " ".join(current_words)))
                current_words = []
                start_time = None
                last_end = None

        if current_words:
            segments.append((start_time, last_end, " ".join(current_words)))
        return segments

    caller_segments = get_segments(channels[0])
    callee_segments = get_segments(channels[1])

    # Merge chronologically
    i = j = 0
    dialogue = []
    while i < len(caller_segments) or j < len(callee_segments):
        if i < len(caller_segments) and (j >= len(callee_segments) or caller_segments[i][0] <= callee_segments[j][0]):
            dialogue.append({"speaker": "Caller", "start": caller_segments[i][0], "end": caller_segments[i][1], "text": caller_segments[i][2]})
            i += 1
        else:
            dialogue.append({"speaker": "Callee", "start": callee_segments[j][0], "end": callee_segments[j][1], "text": callee_segments[j][2]})
            j += 1
    return dialogue

def save_transcript(db_conn, call_uuid, domain_name, recording_file, transcript):
    try:
        with db_conn.cursor() as cur:
            cur.execute("""
                INSERT INTO call_recording_transcript (call_uuid, domain_name, recording_file, transcript)
                VALUES (%s, %s, %s, %s)
            """, (call_uuid, domain_name, recording_file, json.dumps(transcript)))
        db_conn.commit()
        logging.info(f"✅ Transcript saved for call {call_uuid}")
    except Exception:
        db_conn.rollback()
        logging.exception("❌ Failed to save transcript")

# ---------------- ESL Event Handler ----------------
def handle_channel_hangup_complete(db_conn, e):
    try:
        recording_file = e.getHeader("variable_record_path")
        call_uuid = e.getHeader("Unique-ID")
        domain_name = e.getHeader("variable_domain_name")
        direction = e.getHeader("variable_direction")

        #logging.info(f"[CHANNEL_HANGUP_COMPLETE] Processing event...{e.serialize()}")
        logging.info(f"[CHANNEL_HANGUP_COMPLETE] Processing event...{recording_file}")
        
        if recording_file and os.path.exists(recording_file) and direction =='inbound':
            logging.info(f"Transcribing recording for call {call_uuid}")
            transcript = transcribe_audio(recording_file)
            if transcript:
                save_transcript(db_conn, call_uuid, domain_name, recording_file, transcript)

    except Exception:
        logging.exception("❌ Error in handle_channel_hangup_complete")

# ---------------- Dispatcher ----------------
def handle_event(e, esl_conn):
    db_conn = get_db_conn()
    if not db_conn:
        return
    try:
        event_name = e.getHeader("Event-Name")
        if event_name == "CHANNEL_HANGUP_COMPLETE":
            handle_channel_hangup_complete(db_conn, e)
    except Exception:
        logging.exception("❌ Error in handle_event")
    finally:
        release_db_conn(db_conn)

# ---------------- ESL Listener ----------------
def listen_esl():
    esl_con = ESL.ESLconnection(ESL_HOST, ESL_PORT, ESL_PASSWORD)
    if not esl_con.connected():
        logging.error("❌ ESL connection failed")
        sys.exit(1)

    esl_con.events("plain", "ALL")
    init_db_pool()

    def cleanup(signum, frame):
        logging.info("🛑 Shutting down...")
        if DB_POOL:
            DB_POOL.closeall()
        executor.shutdown(wait=False)
        esl_con.disconnect()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    logging.info("🎧 Listening for ESL events...")

    while True:
        try:
            e = esl_con.recvEvent()
            if e:
                executor.submit(handle_event, e, esl_con)
        except Exception:
            logging.exception("❌ ESL event loop crashed")
            sys.exit(1)

# ---------------- Main ----------------
if __name__ == "__main__":
    listen_esl()
