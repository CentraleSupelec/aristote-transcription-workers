FROM python:3.13-alpine

RUN apk add --no-cache ffmpeg cronie

WORKDIR /app/

RUN ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime && echo Europe/Paris > /etc/timezone

RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel pip-tools

COPY requirements.txt ./
COPY transcribe.py ./

RUN pip install --no-cache-dir -r requirements.txt

# Copy entrypoint script
COPY docker/entrypoint.sh ./
COPY docker/transcription-cronjob.sh ./
COPY docker/clean-up-logs.sh ./

RUN chmod +x ./entrypoint.sh
RUN chmod +x ./transcription-cronjob.sh
RUN chmod +x ./clean-up-logs.sh

# Create necessary dirs for cron
RUN mkdir -p /var/spool/cron/crontabs && chmod 600 /var/spool/cron/crontabs

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
