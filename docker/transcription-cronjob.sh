#!/bin/sh

# Define the lock file
TRANSCRIPTION_COUNTER_FILE="/app/locks/transcription-counter"
TRANSCRIPTION_COUNTER_FILE_LOCK="/app/locks/transcription-counter-lock"
MAX_PARALLEL=3

log() {
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $*"
}

while [ -e "$TRANSCRIPTION_COUNTER_FILE_LOCK" ]; do
    log "Counter Lock file exists. Waiting..."
    sleep $(echo "scale=3; $RANDOM/32767" | bc)
done

touch "$TRANSCRIPTION_COUNTER_FILE_LOCK"

# Check the counter file and increment the counter
counter=0
if [ -e "$TRANSCRIPTION_COUNTER_FILE" ]; then
    counter=$(cat "$TRANSCRIPTION_COUNTER_FILE")
    if [ "$counter" -ge "$MAX_PARALLEL" ]; then
        log "Maximum parallel executions reached. Exiting."
        rm -f "$TRANSCRIPTION_COUNTER_FILE_LOCK"
        exit 1
    fi
fi

counter=$((counter + 1))
echo "$counter" > "$TRANSCRIPTION_COUNTER_FILE"

rm -f "$TRANSCRIPTION_COUNTER_FILE_LOCK"

log "Starting transcription $counter / $MAX_PARALLEL"

if curl -s -X GET -I $STT_BASE_URL | grep -E "200 OK|421"  &> /dev/null; then
    /usr/local/bin/python3 /app/transcribe.py
else
    echo "$STT_BASE_URL is not yet responsive. Skipping cron job"
fi

while [ -e "$TRANSCRIPTION_COUNTER_FILE_LOCK" ]; do
    log "Counter Lock file exists. Waiting..."
    sleep $((RANDOM % 1))
done

touch "$TRANSCRIPTION_COUNTER_FILE_LOCK"

# Check if the counter is 1 before removing the counter file
updated_counter=$(cat "$TRANSCRIPTION_COUNTER_FILE")
if [ "$updated_counter" -eq 1 ]; then
    log "Current job is the only one running. Removing $TRANSCRIPTION_COUNTER_FILE"
    rm -f "$TRANSCRIPTION_COUNTER_FILE"
else
    updated_counter=$((updated_counter - 1))
    echo "$updated_counter" > "$TRANSCRIPTION_COUNTER_FILE"
    log "Decremented transcription counter to $updated_counter"
fi

rm -f "$TRANSCRIPTION_COUNTER_FILE_LOCK"
