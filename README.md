# Aristote Transcription Worker

Aristote Transcription Worker is a Python project that acts as a middleware between AristoteAPI and an audio transcription server.

## Usage

### Environment variables

Copy environment variables file from .env.dist and make the necessary changes in .env file

```
cp -f .env.dist .env
```

There are 2 modes :

- If CRON_SCHEDULE is not set, the worker is started only once, and the container exits once the treatment is finished
- If CRON_SCHEDULE is set (example to run every 5 minutes : CRON_SCHEDULE="*/5 * * * *"), the container stays running, and the worker is started regularly according to the scheduled cron

### Run the container

```
docker-compose up
```
