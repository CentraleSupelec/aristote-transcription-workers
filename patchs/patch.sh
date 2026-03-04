#/bin/bash

error() { echo "error: $@" >&2 ; exit 1; }

patchf() {
    local src="${1:-none}"
    local dst="${2:-none}"
    test -r "${src}"          || error "Missing input file"
    test -r "${dst}"          || error "No destination file"
    diff -q "${src}" "${dst}" && error "Patching has no effect"
    cp -p ${dst} ${dst}_ref   || error "Could not patch file"
    cat ${src} > ${dst}       || error "Could not patch file"
    diff -q "${src}" "${dst}" || error "Patching had no effect"
}

stt_file=/home/ubuntu/speaches/src/speaches/routers/stt.py
test "${CUDA_VERSION:-none}" = "none" &&
    patchf /app/patchs/cpu_speaches_src_speaches_routers_stt.py ${stt_file} ||
	patchf /app/patchs/cuda_speaches_src_speaches_routers_stt.py ${stt_file}
