#!/bin/sh

set -e

LOG_PATH="/app/logs/transcription-$(date +\%d-\%m-\%Y).log"
touch "$LOG_PATH"

if [ -z "$CRON_SCHEDULE" ]; then
  echo "[INFO] No CRON_SCHEDULE defined. Running transcribe.py once..."
  python3 /app/transcribe.py
else
  echo "[INFO] CRON_SCHEDULE is set to '$CRON_SCHEDULE'. Scheduling job..."
  echo "" > /etc/crontabs/root

  # Dump all env vars into crontab
  env | grep -v "^_" | while read line; do
    echo "$line" >> /etc/crontabs/root
  done

  # Add cron job
  echo "$CRON_SCHEDULE /app/transcription-cronjob.sh >> $LOG_PATH 2>&1" >> /etc/crontabs/root
  echo "* * * * * /app/clean-up-logs.sh >> /app/logs/clean-up.log 2>&1" >> /etc/crontabs/root
  chmod 600 /etc/crontabs/root

  # Start crond
  crond -f &
  tail -n 0 -f "$LOG_PATH"

fi
