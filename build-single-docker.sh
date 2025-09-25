#!/bin/bash
set -o ignoreeof
set -o nounset

error() {
    echo "error: $*" >&2
    exit 1
}

# Load local env
test -r .env && . .env

# Global variable, replaceble by the local env

SPEACHES_AI=${SPEACHES_AI:-ghcr.io/speaches-ai/speaches:0.8-cpu}
ARISTOTE_TW_NAME=${ARISTOTE_TW_NAME:-aristote-transcription_worker}
ARISTOTE_TW_TAG=${ARISTOTE_TW_TAG:-0.8-cpu}

# Load local env

which podman > /dev/null && PODMAN=$(which podman)
which docker > /dev/null && PODMAN=$(which docker)
test -z "${PODMAN:-}" && error "Docker/podman not found"
which jq > /dev/null || error "Install 'jq' for processing Json"

# Dockerfile variables

SPEACHES_AI_ENV=docker/standalone/speaches_ai.env
SPEACHES_AI_SH=docker/standalone/speaches_ai.sh

#
# Extract runtime from container
extract_speaches_ai() {
    ${PODMAN} pull ${SPEACHES_AI} || error "Could not fetch ${SPEACHES_AI}"
    local workdir=$(${PODMAN} inspect ${SPEACHES_AI} | jq -r '.[].Config.WorkingDir')
    local cmdline=$(${PODMAN} inspect ${SPEACHES_AI} | jq -r '.[].Config.Cmd|join(" ")')
    ( echo "#!/bin/bash"
      echo "cd ${workdir}"
      echo "${cmdline}"
    ) > ${SPEACHES_AI_SH}

    ${PODMAN} inspect ${SPEACHES_AI} | jq -r '.[].Config.Env | [ .[] | "export " + . ].[]' > ${SPEACHES_AI_ENV}
    chmod a+x ${SPEACHES_AI_SH}
}

build_image() {
    ${PODMAN} build -f docker/standalone/Dockerfile -t ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG} .   
}

run_image() {
    test -r .env || error "Environment file .env not found"
    install -d -m 777 ./logs ./locks
    ${PODMAN} run --rm  -it --name ${ARISTOTE_TW_NAME} \
	      --env-file .env \
	      -v ./logs:/app/logs \
	      -v ./locks:/app/locks \
	      -v hf-cache:/home/ubuntu/.cache/huggingface/hub \
	      ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG}
}

build_sif() {
    local ocifile=/tmp/aristote-transcription_worker.oci
    ${PODMAN}  save -o ${ocifile} ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG}
    apptainer build ${ARISTOTE_TW_NAME}_${ARISTOTE_TW_TAG}.sif docker-archive://${ocifile} 
}

run_sif() {
    echo apptainer run \
	      --writable-tmpfs \
	      --env-file .env \
	      -B ./logs:/app/logs \
	      -B ./locks:/app/locks \
	      -B ./hf-cache:/home/ubuntu/.cache/huggingface/hub \
	      ${ARISTOTE_TW_NAME}_${ARISTOTE_TW_TAG}.sif
}

cmd=${1:-build}
test "${cmd}" = build   && extract_speaches_ai && build_image
test "${cmd}" = run_d   && run_image
test "${cmd}" = run_s   && run_sif
test "${cmd}" = all     && extract_speaches_ai && build_image && build_sif

