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

TEMP_DIR=${TEMP_DIR:-/tmp}
VERSION=0.8-cpu
VERSION=0.8-cuda
SPEACHES_AI=${SPEACHES_AI:-ghcr.io/speaches-ai/speaches:${VERSION}}
ARISTOTE_TW_NAME=${ARISTOTE_TW_NAME:-aristote-transcription_worker}
ARISTOTE_TW_TAG=${ARISTOTE_TW_TAG:-${VERSION}}

# Load local env

which podman > /dev/null && PODMAN=$(which podman)
which docker > /dev/null && PODMAN=$(which docker)
test -z "${PODMAN:-}" && error "Docker/podman not found"
which jq > /dev/null || error "Install 'jq' for processing Json"

# Dockerfile variables

SPEACHES_AI_ENV=docker/standalone/speaches_ai-${VERSION}.env
SPEACHES_AI_BASE_ENV=docker/standalone/speaches_ai-${VERSION}-base.env
SPEACHES_AI_SH=docker/standalone/speaches_ai-${VERSION}.sh

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

    ${PODMAN} inspect ${SPEACHES_AI} | jq -r '.[].Config.Env | [ .[] | "export " + . ].[]' | \
	sed 's/^\([^=]*\)=\(.*\)$/\1="\2"/' \
	    > ${SPEACHES_AI_ENV}
    grep -v '^export NV_\|^export NVIDIA_\|^export CUDA_\|^export NCCL_\|^export LD_LIBRARY_PATH' \
	 ${SPEACHES_AI_ENV} > ${SPEACHES_AI_BASE_ENV}
    chmod a+x ${SPEACHES_AI_SH}
}

build_image() {
    ${PODMAN} build -f docker/standalone/Dockerfile.${VERSION} -t ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG} .
}

run_image() {
    test -r .env || error "Environment file .env not found"
    install -d -m 777 ./logs ./locks
    echo ${PODMAN} run --rm  -it --name ${ARISTOTE_TW_NAME} \
	      --env-file .env \
	      -v ./logs:/app/logs \
	      -v ./locks:/app/locks \
	      -v hf-cache:/home/ubuntu/.cache/huggingface/hub \
	      ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG}
}

build_sif() {
    export TMPDIR=${TEMP_DIR}
    local ocifile=${TEMP_DIR}/aristote-transcription_worker.oci
    echo "======== Process ${ocifile} ======="
    rm -f ${ocifile}
    ${PODMAN}  save -o ${ocifile} ${ARISTOTE_TW_NAME}:${ARISTOTE_TW_TAG}
    #apptainer cache clean
    echo "======== build ${ARISTOTE_TW_NAME}_${ARISTOTE_TW_TAG}.sif ======="
    apptainer build ${ARISTOTE_TW_NAME}_${ARISTOTE_TW_TAG}.sif docker-archive://${ocifile}
    #rm -f ${ocifile}
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

client_login() {
    local envfile=$(pwd)/.env
    test -r .env && . ${envfile} || error "No config"
    test -r .token ||
	curl -v -X POST ${ARISTOTE_API_BASE_URL}/token \
	     --data '{"grant_type": "client_credentials"}' \
	     --header "Content-Type: application/json" \
	     -u "${ARISTOTE_API_CLIENT_ID}:${ARISTOTE_API_CLIENT_SECRET}"  > .token
}

client_list() {
    client_login
    curl -s -X GET ${ARISTOTE_API_BASE_URL}/v1/enrichments \
	 -H "Authorization: Bearer $(jq -r .access_token < .token)" \
	 -H "accept: application/json"
}

client_extract() {
    local index="${1:-0}"
    client_login
    local last=$(client_list | jq -r '[ .content[] | select(.status != "WAITING_MEDIA_TRANSCRIPTION") | .id ]['${index}']')
    test -z "${last}" && error "Nothing to extract"
    curl -s -X GET "${ARISTOTE_API_BASE_URL}/v1/enrichments/${last}/versions/latest" \
	 -H "Authorization: Bearer $(jq -r .access_token < .token)" \
	 -H "accept: application/json"
}

client_post() {
    client_login
    local file="${1:-astatquest.mp4}"
    local params=$(jq -cr <<EOF
{
    "aiModel":          "",
    "infrastructure":   "ILaaS",
    "disciplines":      ["test"],
    "aiEvaluation":     "",
    "generateMetadata": true,
    "translateTo":      "",
    "generateQuiz":     true,
    "generateNotes":    true,
    "mediaTypes":       ["mp4"],
    "language":"fr"
}
EOF
	  )
    curl -s -X POST ${ARISTOTE_API_BASE_URL}/v1/enrichments/upload \
	 -H "Authorization: Bearer $(jq -r .access_token < .token)" \
	 -H "accept: application/json" \
	 -H 'Content-Type: multipart/form-data' \
	 -F "file=@${file};type=audio/mp4" \
	 -F 'notificationWebhookUrl=https://stt.ilaas.fr/api/v1/health' \
	 -F "enrichmentParameters=${params}" \
	| jq .
}

cmd=${cmd:-${1:-build}}
shift 1
test "${cmd}" = build   && extract_speaches_ai && build_image
test "${cmd}" = run_d   && run_image
test "${cmd}" = run_s   && run_sif
test "${cmd}" = all     && extract_speaches_ai && build_image && build_sif
test "${cmd}" = list    && client_list
test "${cmd}" = send    && client_post "$@"
test "${cmd}" = extract && client_extract "$@"
