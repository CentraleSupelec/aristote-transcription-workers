#!/bin/sh

MAX_LOGS_DAYS=${MAX_LOGS_DAYS:-15}
LOG_DIR="/app/logs"
find "$LOG_DIR" -type f -name "*.log" -mtime +"$MAX_LOG_DAYS" -exec rm -f {} \;
