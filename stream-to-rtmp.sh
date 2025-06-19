#!/bin/bash
# Ultimate Twitch Streaming Solution with Xvfb and Audio Fallback

# Configuration
LOG_DIR="/var/log/stream"
LOG_FILE="${LOG_DIR}/stream_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"
chmod 777 "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Ultimate Twitch Streaming Solution"
echo "=========================================================================="

# Cleanup function
cleanup() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Executing cleanup..."
  pkill -P $$ 2>/dev/null
  if [ -n "$XVFB_PID" ]; then kill -9 "$XVFB_PID" 2>/dev/null; fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup complete"
  exit 0
}
trap cleanup SIGTERM SIGINT

DISPLAY=${DISPLAY:-"127.0.0.1:0"}
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Display: $DISPLAY"

# Start ChromeDriver
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting ChromeDriver..."
/usr/local/bin/chromedriver \
  --port=4444 \
  --allowed-ips="" \
  --allowed-origins="*" \
  --disable-dev-shm-usage \
  --headless \
  --no-sandbox \
  --disable-gpu \
  --log-path="${LOG_DIR}/chromedriver.log" &
CHROMEDRIVER_PID=$!
sleep 2

# Verify ChromeDriver
if ! ps -p $CHROMEDRIVER_PID >/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ChromeDriver failed to start"
  exit 1
fi

# Streaming parameters
Twitch_KEY="${Twitch_KEY}"
RTMP_URL="${RTMP_BASE_URL}${Twitch_KEY}"
VIDEO_SIZE="${VIDEO_SIZE:-1920x1080}"
FRAME_RATE="${FRAME_RATE:-30}"
BITRATE="${BITRATE:-3000k}"
PRESET="${PRESET:-ultrafast}"
GOP_SIZE=$((FRAME_RATE * 2))

# Audio configuration
if pactl list sources >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] PulseAudio detected"
  AUDIO_SOURCE="-f pulse -i default"
elif arecord -l | grep -q 'card'; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALSA detected"
  AUDIO_SOURCE="-f alsa -ac 2 -i default"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No audio device found, using silent source"
  AUDIO_SOURCE="-f lavfi -i anullsrc=r=44100:cl=stereo"
fi

# Stream function
start_stream() {
  ffmpeg -loglevel warning \
    -f x11grab -video_size "$VIDEO_SIZE" -framerate "$FRAME_RATE" \
    -draw_mouse 0 -i "$DISPLAY" \
    $AUDIO_SOURCE \
    -c:v libx264 -preset "$PRESET" -tune zerolatency \
    -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$(( ${BITRATE%k} * 2 ))k" \
    -pix_fmt yuv420p -g "$GOP_SIZE" -keyint_min "$FRAME_RATE" \
    -c:a aac -b:a 128k -ar 44100 \
    -f flv "$RTMP_URL" &
  FFMPEG_PID=$!
}

# Stream with retries
MAX_RETRIES=3
RETRY_DELAY=5

for attempt in $(seq 1 $MAX_RETRIES); do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting stream attempt $attempt/$MAX_RETRIES"
  
  start_stream
  sleep 10
  
  if ps -p $FFMPEG_PID >/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stream is running (PID: $FFMPEG_PID)"
    wait $FFMPEG_PID
    STREAM_EXIT=$?
    if [ $STREAM_EXIT -eq 0 ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stream completed successfully"
      exit 0
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stream exited with code $STREAM_EXIT"
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stream failed to start"
  fi
  
  if [ $attempt -lt $MAX_RETRIES ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retrying in $RETRY_DELAY seconds..."
    
    # Reduce quality for retries
    BITRATE="2000k"
    VIDEO_SIZE="854x480"
    PRESET="ultrafast"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reduced quality to $VIDEO_SIZE @ $BITRATE"
    
    sleep $RETRY_DELAY
  fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed after $MAX_RETRIES attempts"
