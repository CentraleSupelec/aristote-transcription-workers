import base64
import json
import os
import sys
import tempfile
import uuid
import asyncio
import logging
import ffmpeg

import requests
from requests.models import Response

ARISTOTE_API_BASE_URL = os.environ["ARISTOTE_API_BASE_URL"]
ARISTOTE_API_CLIENT_ID = os.environ["ARISTOTE_API_CLIENT_ID"]
ARISTOTE_API_CLIENT_SECRET = os.environ["ARISTOTE_API_CLIENT_SECRET"]
STT_BASE_URL = os.environ["STT_BASE_URL"]
MODEL = os.environ.get("MODEL")
API_KEY = os.environ.get("API_KEY")

if API_KEY:
    headers = {"Authorization": f"Bearer {API_KEY}"}
else:
    headers = {}

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


def extract_audio(video_path, output_path, bitrate="64k", codec="mp3"):
    probe = ffmpeg.probe(video_path)
    duration = float(probe["format"]["duration"])
    logger.debug("Media duration: %s seconds", duration)

    input_file = ffmpeg.input(video_path)
    audio = input_file["a:0"]
    output_file = ffmpeg.output(audio, output_path, acodec=codec, audio_bitrate=bitrate)
    ffmpeg.run(output_file, quiet=True)


def download_video(url, save_path) -> bool:
    response = requests.get(url, stream=True, timeout=60)
    if response.status_code == 200:
        with open(save_path, "wb") as file:
            for chunk in response.iter_content(chunk_size=1024):
                if chunk:
                    file.write(chunk)
        logger.debug("Video downloaded successfully to %s", save_path)
        return True

    logger.error("Failed to download media. Status code: %s", response.status_code)
    return False


def get_token():
    token_response: Response = requests.post(
        f"{ARISTOTE_API_BASE_URL}/token",
        json={
            "grant_type": "client_credentials",
        },
        headers={
            "Authorization": "Basic "
            + base64.b64encode(
                f"{ARISTOTE_API_CLIENT_ID}:{ARISTOTE_API_CLIENT_SECRET}".encode()
            ).decode(),
        },
        timeout=1000,
    )

    if token_response.status_code == 200:
        return token_response.json()["access_token"]
    else:
        logger.error("Couldn't get token. Error code : %s", token_response.status_code)
        raise Exception(
            "Couldn't get token. Error code : %s", token_response.status_code
        )


def transcription_fail(
    enrichment_id: str,
    task_id: str,
    token: str,
    failure_cause: str,
    exit_with_error: bool = True,
):
    failure_cause_trucated = (
        (failure_cause[:252] + "...") if len(failure_cause) > 255 else failure_cause
    )
    transcription_failure_response: Response = requests.post(
        f"{ARISTOTE_API_BASE_URL}/v1/enrichments/{enrichment_id}/versions/initial/transcript",
        data={
            "taskId": task_id,
            "status": "KO",
            "failureCause": failure_cause_trucated,
        },
        headers={"Authorization": "Bearer " + token},
        timeout=30,
    )

    if transcription_failure_response.status_code == 200:
        logger.info("Transcription failure response sent")
    else:
        logger.error("Couldn't send failure response")

    if exit_with_error:
        raise Exception(failure_cause)


async def aristote_worklow():

    stt_readiness: Response = requests.get(STT_BASE_URL, timeout=5, headers=headers)
    if stt_readiness.status_code != 200 and stt_readiness.status_code != 421:
        logger.info("Couldn't connect to stt.")
        raise Exception("Couldn't connect to stt.")

    models_response: Response = requests.get(
        f"{STT_BASE_URL}/v1/models", timeout=5, headers=headers
    )

    open_ai_compatible_server = True

    if models_response.status_code != 200:
        open_ai_compatible_server = False

    token = get_token()

    task_id = str(uuid.uuid4())

    job_response: Response = requests.get(
        f"{ARISTOTE_API_BASE_URL}/v1/enrichments/transcription/job/oldest?taskId={task_id}",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
        },
        timeout=30,
    )

    if job_response.status_code == 200:
        json_response = job_response.json()
        enrichment_id = json_response["enrichmentId"]
        media_temporary_url = json_response["mediaTemporaryUrl"]
        language = json_response["language"]
    else:
        logger.info("Couldn't get a job. Error code : %s", job_response.status_code)
        return

    logger.info("Transcribing enrichment : %s", enrichment_id)

    media_file_path = f"media-{task_id}.mp4"
    audio_file_path = f"media-{task_id}.mp3"

    try:
        video_downloaded = download_video(media_temporary_url, media_file_path)
        if not video_downloaded:
            logger.error("Video could not be downloaded")
            return
    except Exception:
        if os.path.exists(media_file_path):
            os.remove(media_file_path)
        logger.error("Error downloading video")
        return

    try:
        extract_audio(media_file_path, audio_file_path)
    except Exception:
        if os.path.exists(media_file_path):
            os.remove(media_file_path)

        if os.path.exists(audio_file_path):
            os.remove(audio_file_path)
        logger.error("Error converting video to audio")

        transcription_fail(
            enrichment_id=enrichment_id,
            task_id=task_id,
            token=token,
            failure_cause="Error converting video to audio. Maybe the video has no audio ?",
        )
        return

    # files = {"audio": (audio_file_path, open(audio_file_path, "rb"), "audio/wave")}
    files = {
        "file" if open_ai_compatible_server else "audio": (
            audio_file_path,
            open(audio_file_path, "rb"),
            "audio/wave",
        )
    }

    if open_ai_compatible_server:
        data = {
            "model": MODEL,
            "timestamp_granularities[]": "word",
            "response_format": "verbose_json",
        }
    else:
        params = {}
        if language:
            params["language"] = language
        data = {"params": json.dumps(params)}

    try:
        stt_response = requests.post(
            f"{STT_BASE_URL}/{'v1/audio/transcriptions' if open_ai_compatible_server else 'predict'}",
            files=files,
            data=data,
            timeout=10000,
            headers=headers,
        )
        logger.debug(stt_response.text)
    except Exception as error:
        if os.path.exists(media_file_path):
            os.remove(media_file_path)

        if os.path.exists(audio_file_path):
            os.remove(audio_file_path)

        logger.error("Whisper did not respond. Error : %s", error)
        transcription_fail(
            enrichment_id=enrichment_id,
            task_id=task_id,
            token=token,
            failure_cause=f"Whisper error : {error}",
        )
        return
    if os.path.exists(media_file_path):
        os.remove(media_file_path)
    if os.path.exists(audio_file_path):
        os.remove(audio_file_path)
    if stt_response.status_code == 200:
        transcript_json = stt_response.json()
    else:
        logger.error(
            "Whisper failed transcription. Error code : %s",
            stt_response.status_code,
        )
        transcription_fail(
            enrichment_id=enrichment_id,
            task_id=task_id,
            token=token,
            failure_cause=f"Whisper error : {stt_response.json()}",
        )
        return

    segments = transcript_json.get("chunks") or transcript_json.get("segments") or []

    if 0 == len(segments):
        if "words" in transcript_json and len(transcript_json["words"]) > 0:
            segments = [
                {
                    "text": transcript_json["text"],
                    "start": transcript_json["words"][0]["start"],
                    "end": transcript_json["words"][-1]["end"],
                    "words": transcript_json["words"],
                }
            ]
        else:
            transcription_fail(
                enrichment_id=enrichment_id,
                task_id=task_id,
                token=token,
                failure_cause="Generated empty transcript",
                exit_with_error=False,
            )
            return

    def _seg_start(segment: dict) -> float:
        return (
            float(segment["start"])
            if open_ai_compatible_server
            else float(segment["timestamp"][0])
        )

    def _seg_end(segment: dict) -> float:
        return (
            float(segment["end"])
            if open_ai_compatible_server
            else float(segment["timestamp"][1])
        )

    def _normalize_word(word: dict) -> dict:
        return {
            "text": word["word"] if open_ai_compatible_server else word["text"],
            "start": (
                float(word["start"])
                if open_ai_compatible_server
                else float(word["timestamp"][0])
            ),
            "end": (
                float(word["end"])
                if open_ai_compatible_server
                else float(word["timestamp"][1])
            ),
        }

    def _global_words_norm() -> list:
        return [_normalize_word(w) for w in (transcript_json.get("words") or [])]

    def _words_for_segment_from_global(
        seg_s: float, seg_e: float, global_words: list
    ) -> list:
        eps = 1e-6
        out = []
        for w in global_words:
            if w["end"] >= seg_s - eps and w["start"] <= seg_e + eps:
                out.append(w)
        return out

    global_words = _global_words_norm()

    transcript = {
        "original_file_name": "",
        "language": transcript_json["language"],
        "text": transcript_json["text"],
        "sentences": [
            {
                "text": segment["text"],
                "start": _seg_start(segment),
                "end": _seg_end(segment),
                "words": (
                    [_normalize_word(w) for w in segment.get("words", [])]
                    if segment.get("words")
                    else _words_for_segment_from_global(
                        _seg_start(segment), _seg_end(segment), global_words
                    )
                ),
            }
            for segment in segments
        ],
    }

    with tempfile.NamedTemporaryFile(mode="w+", delete=False) as temp_file:
        json.dump(transcript, temp_file)

    files = {"transcript": (temp_file.name, open(temp_file.name, "rb"))}

    transcription_response: Response = requests.post(
        f"{ARISTOTE_API_BASE_URL}/v1/enrichments/{enrichment_id}/versions/initial/transcript",
        data={"taskId": task_id, "status": "OK"},
        files=files,
        headers={"Authorization": "Bearer " + token},
        timeout=30,
    )

    if transcription_response.status_code == 200:
        logger.info("Transcription successful !")
    else:
        try:
            error_message = transcription_response.json()
        except ValueError:
            error_message = transcription_response.text

        logger.error(
            "Transcription failed. Error code : %s / Error message : %s",
            transcription_response.status_code,
            error_message,
        )
        raise Exception(
            "Transcription failed. Error code : %s / Error message : %s",
            transcription_response.status_code,
            error_message,
        )


if __name__ == "__main__":
    asyncio.run(aristote_worklow())
