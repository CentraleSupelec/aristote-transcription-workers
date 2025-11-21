#!/bin/bash

set -e

SPEACH_PORT=${SPEACH_PORT:-8000}

checkPort8000Open() {
    local port=$(printf '%X\n' "${SPEACH_PORT}")
    egrep -qi ": [0-9A-AF]*:${port} " /proc/net/tcp
}

loadModelPort8000() {
    local model=${1:-${MODEL:-}}
    test -z "${model}" && error "No model provided"

    local surl=http://localhost:${SPEACH_PORT}
    for ((i=0; i<${SPEACHES_AI_TIMEOUT:-20}; i++)); do
	if [ "$(curl -s -o /dev/null -w "%{http_code}" ${surl}/health 2>/dev/null)" = "200" ]; then
	    echo "Sending model load request for ${model}...";
	    curl -sS -X POST ${surl}/v1/models/${model};
	    break
	fi
        echo "Waiting for speaches service to become healthy...";
        sleep 2;
    done;
}

# A potential venv was setup
test -f /venv/bin/activate && . /venv/bin/activate

# Setup and run speach
if [ -e /app/speaches_ai.sh ]; then
    test -e /app/speaches_ai.env || error "speaches_ai env missing"
    (
	test -z "${APPTAINER_NAME:-}" &&
	    . /app/speaches_ai.env ||
		. /app/speaches_ai_base.env
	export UVICORN_PORT=${SPEACH_PORT}
	/app/speaches_ai.sh
    ) &
    for ((i=0; i<${SPEACHES_AI_TIMEOUT:-20}; i++)); do
	sleep 1
	checkPort8000Open && break
    done
    checkPort8000Open || error "Timeout waiting for speaches AI."
fi
export STT_BASE_URL=http://localhost:${SPEACH_PORT}

TRANSCRIPTION_COUNTER_FILE="/app/locks/transcription-counter"
TRANSCRIPTION_COUNTER_FILE_LOCK="/app/locks/transcription-counter-lock"

rm -f "$TRANSCRIPTION_COUNTER_FILE"
rm -f "$TRANSCRIPTION_COUNTER_FILE_LOCK"

LOG_PATH="/app/logs/transcription-$(date +\%d-\%m-\%Y).log"
LOG_PATTERN_FOR_TAIL="/app/logs/*.log"
touch "$LOG_PATH"

if [ -z "$ARISTOTE_API_BASE_URL" -o -z "ARISTOTE_API_CLIENT_ID" ]; then
    echo "Error: missing environment variables 'ARISTOTE_API_...'" >&2
    exit
fi

loadModelPort8000 &

if [ -z "$CRON_SCHEDULE" ]; then
    echo "[INFO] No CRON_SCHEDULE defined. Running transcribe.py once..."
    python3 /app/transcribe.py
    sleep 2
else
    echo "[INFO] CRON_SCHEDULE is set to '$CRON_SCHEDULE'. Scheduling job..."
    (
	env | grep -v "^_" | while read line; do
	    echo "$line"
	done
	printf "${CRON_SCHEDULE} /app/transcription-cronjob.sh >> $LOG_PATH 2>&1\n" | tr -d '"'
	echo "* * * * * /app/clean-up-logs.sh >> /app/logs/clean-up.log 2>&1"
    ) | crontab -
    crontab -l
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
echo "End of script: terminating all jobs"
pkill -P $$
