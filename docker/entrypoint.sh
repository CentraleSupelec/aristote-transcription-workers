#!/bin/sh

set -e

TRANSCRIPTION_COUNTER_FILE="/app/locks/transcription-counter"
TRANSCRIPTION_COUNTER_FILE_LOCK="/app/locks/transcription-counter-lock"

rm -f "$TRANSCRIPTION_COUNTER_FILE"
rm -f "$TRANSCRIPTION_COUNTER_FILE_LOCK"

LOG_PATH="/app/logs/transcription-$(date +\%d-\%m-\%Y).log"
LOG_PATTERN_FOR_TAIL="/app/logs/*.log"
touch "$LOG_PATH"

if [ -z "$CRON_SCHEDULE" ]; then
  echo "[INFO] No CRON_SCHEDULE defined. Running transcribe.py once..."
  python3 /app/transcribe.py
else
  echo "[INFO] CRON_SCHEDULE is set to '$CRON_SCHEDULE'. Scheduling job..."
  echo "" > /etc/crontabs/root

  env | grep -v "^_" | while read line; do
    echo "$line" >> /etc/crontabs/root
  done

  echo "$CRON_SCHEDULE /app/transcription-cronjob.sh >> $LOG_PATH 2>&1" >> /etc/crontabs/root
  echo "* * * * * /app/clean-up-logs.sh >> /app/logs/clean-up.log 2>&1" >> /etc/crontabs/root
  chmod 600 /etc/crontabs/root

  crond -f &
  tail -n 0 -f -q $LOG_PATTERN_FOR_TAIL &

  inotifywait -m -e create --format '%f' /app/logs | while read -r newfile; do
    echo "New file detected"
    if [[ "$newfile" == *.log ]]; then
      echo "Tailing new file: $newfile"
      tail -f "/app/logs/$newfile" &
    fi
  done
fi
