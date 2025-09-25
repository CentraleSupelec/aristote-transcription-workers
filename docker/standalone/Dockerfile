FROM ghcr.io/speaches-ai/speaches:0.8-cpu

USER 0:0
RUN apt update && apt -y dist-upgrade
RUN apt install -y ffmpeg cronie curl inotify-tools  && \
    ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime && \
    echo Europe/Paris > /etc/timezone

RUN python3 -mvenv /venv/ && \
    . /venv/bin/activate && \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel pip-tools

COPY requirements.txt /venv/requirements.txt
RUN . /venv/bin/activate && \
    pip install --no-cache-dir -r /venv/requirements.txt

# #/var/spool/cron/crontabs && chmod 600 /var/spool/cron/crontabs

USER 1000:1000
WORKDIR /app/
RUN     mkdir -p ./logs ./locks

COPY --chown=1000:1000 transcribe.py \
    docker/transcription-cronjob.sh docker/clean-up-logs.sh \
    docker/standalone/entrypoint.sh \
    docker/standalone/speaches_ai.sh docker/standalone/speaches_ai.env \
    ./
RUN chmod +x ./*.sh

ENTRYPOINT ["/app/entrypoint.sh"]
