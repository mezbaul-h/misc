#!/usr/bin/env bash
# Download the original assets plus the five additional LoRAs into an existing ComfyUI.
# Required environment variables (no defaults): HF_TOKEN, COMFYUI_BASE_DIR.
# Dependencies: Bash, curl, Python 3 (standard library only).
#
# Usage:
#   export HF_TOKEN='hf_...'
#   export COMFYUI_BASE_DIR='/path/to/ComfyUI'
#   bash download_krea2.sh
#
# Image 1 contains Q8_0 GGUF, NOT FP8. This script selects its 8-bit GGUF.
# Downloads only models/workflows, not custom nodes or Python dependencies.
# The original workflow is preserved; select the GGUF with Unet Loader (GGUF).

set +x +v
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
: "${HF_TOKEN:?Set HF_TOKEN to a Hugging Face token with read access to mezattn/krea2-turbo}"
: "${COMFYUI_BASE_DIR:?Set COMFYUI_BASE_DIR to your existing ComfyUI directory}"
[[ "$HF_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || die 'HF_TOKEN contains unexpected characters.'
[[ $# -eq 0 ]] || die 'Use HF_TOKEN and COMFYUI_BASE_DIR; no positional arguments are accepted.'
for command in curl python3; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done
[[ -d "$COMFYUI_BASE_DIR" ]] || die "Directory does not exist: $COMFYUI_BASE_DIR"
COMFYUI_BASE_DIR=$(cd -- "$COMFYUI_BASE_DIR" && pwd -P)
[[ -f "$COMFYUI_BASE_DIR/main.py" && -f "$COMFYUI_BASE_DIR/folder_paths.py" ]] ||
    die 'COMFYUI_BASE_DIR must point at ComfyUI itself (the folder containing main.py and folder_paths.py).'

work_dir=$(mktemp -d "$COMFYUI_BASE_DIR/.krea2-download.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Feed authentication through stdin, keeping the token out of curl's argv.
# curl strips Authorization on redirects to a different host. Do not add
# --location-trusted: Hugging Face redirects large downloads to signed URLs.
hf_curl() {
    printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN" |
        curl --disable --config - --fail --location \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
            --retry 5 --retry-delay 3 --retry-max-time 600 "$@"
}

printf 'Checking repositories and resolving exact revisions...\n'
hf_curl --silent --show-error --output "$work_dir/private.json" \
    'https://huggingface.co/api/models/mezattn/krea2-turbo?blobs=true' ||
    die 'Cannot read mezattn/krea2-turbo. Check your token and private-repository permissions.'
hf_curl --silent --show-error --output "$work_dir/public.json" \
    'https://huggingface.co/api/models/vantagewithai/Krea-2-Turbo-GGUF?blobs=true' ||
    die 'Cannot read vantagewithai/Krea-2-Turbo-GGUF.'

# Original screenshot assets plus five additional LoRAs.
# No private-repository diffuser is downloaded.
# Pin both repositories to the API's commit so retries use the same bytes.
python3 - "$work_dir" <<'PY' > "$work_dir/manifest.tsv"
import json
import pathlib
import re
import sys
from urllib.parse import quote

root = pathlib.Path(sys.argv[1])
assets = [
    ("private", "Eyes.pt", "models/ultralytics/bbox"),
    ("private", "KNPV3_1.safetensors", "models/loras"),
    ("private", "KNP_000003000.safetensors", "models/loras"),
    ("private", "Qwen3-VL-4B-Instruct-Uncensored-FP8.safetensors", "models/text_encoders"),
    ("private", "RealisticSnapshotKrea2V2.safetensors", "models/loras"),
    ("private", "face_yolov8m.pt", "models/ultralytics/bbox"),
    ("private", "hand_yolov8s.pt", "models/ultralytics/bbox"),
    ("private", "image_krea2_turbo_t2i_v3.json", "user/default/workflows"),
    ("private", "image_krea2_turbo_t2i_v5.json", "user/default/workflows"),
    ("private", "image_krea2_turbo_t2i_v6.json", "user/default/workflows"),
    ("private", "qwen_image_vae.safetensors", "models/vae"),
    ("private", "yara_lora_v2_000002000.safetensors", "models/loras"),
    ("private", "yara_lora_v2_000002250.safetensors", "models/loras"),
    ("private", "yara_lora_v2_000002500.safetensors", "models/loras"),
    ("private", "yara_lora_v2_000002750.safetensors", "models/loras"),
    ("private", "snofs_krea_v1_5.safetensors", "models/loras"),
    ("public", "krea2_turbo-Q8_0.gguf", "models/unet"),
]
repos = {"private": "mezattn/krea2-turbo", "public": "vantagewithai/Krea-2-Turbo-GGUF"}
metadata = {key: json.loads((root / (key + ".json")).read_text()) for key in repos}
for key, name, directory in assets:
    info = metadata[key]
    revision = info.get("sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        sys.exit(f"Invalid repository revision for {repos[key]}")
    files = {item["rfilename"]: item for item in info.get("siblings", [])}
    if name not in files:
        sys.exit(f"Required file missing from {repos[key]}: {name}")
    item = files[name]
    lfs = item.get("lfs") or {}
    size = lfs.get("size", item.get("size"))
    algorithm = "sha256" if lfs else "git-sha1"
    digest = lfs.get("sha256") if lfs else item.get("blobId")
    pattern = r"[0-9a-f]{64}" if lfs else r"[0-9a-f]{40}"
    if not isinstance(size, int) or size <= 0 or not re.fullmatch(pattern, digest or ""):
        sys.exit(f"Missing size/checksum metadata for {name}; refusing an unverified download")
    url = f"https://huggingface.co/{repos[key]}/resolve/{revision}/{quote(name)}?download=true"
    print(url, f"{directory}/{name}", size, algorithm, digest, sep="\t")
PY

cat > "$work_dir/verify.py" <<'PY'
import hashlib
import json
import pathlib
import sys

path, size, algorithm, expected = sys.argv[1:]
path = pathlib.Path(path)
try:
    if not path.is_file() or path.stat().st_size != int(size):
        sys.exit(1)
    digest = hashlib.sha256() if algorithm == "sha256" else hashlib.sha1()
    if algorithm == "git-sha1":
        digest.update(f"blob {size}\0".encode())
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        sys.exit(1)
    if path.name.endswith((".json", ".json.part")):
        with path.open(encoding="utf-8") as stream:
            json.load(stream)
except (OSError, ValueError):
    sys.exit(1)
PY

verify() { python3 "$work_dir/verify.py" "$1" "$size" "$algorithm" "$digest"; }

while IFS=$'\t' read -r url relative_path size algorithm digest; do
    destination="$COMFYUI_BASE_DIR/$relative_path"
    partial="${destination}.part"
    mkdir -p -- "$(dirname -- "$destination")"
    if verify "$destination"; then
        printf 'Verified; skipping: %s\n' "$relative_path"
        continue
    fi
    printf '\nDownloading: %s\n' "$relative_path"
    if ! verify "$partial"; then
        status=0
        hf_curl --show-error --progress-bar --continue-at - --output "$partial" "$url" || status=$?
        if (( status == 33 || status == 36 )) || { (( status == 22 )) && [[ -s "$partial" ]]; }; then
            # Server refused a range (including HTTP 416). Restart this file.
            printf 'Range download refused; restarting this file.\n' >&2
            rm -f -- "$partial"
            hf_curl --show-error --progress-bar --output "$partial" "$url" ||
                die "Download failed: $relative_path. Rerun the script to resume."
        elif (( status != 0 )); then
            die "Download failed: $relative_path. Partial file retained; rerun to resume."
        fi
        if ! verify "$partial"; then
            # A stale or corrupt partial may have been resumed. Retry cleanly once.
            printf 'Checksum mismatch; retrying this file from the beginning.\n' >&2
            rm -f -- "$partial"
            hf_curl --show-error --progress-bar --output "$partial" "$url" ||
                die "Download failed: $relative_path. Rerun the script to resume."
            if ! verify "$partial"; then
                rm -f -- "$partial"
                die "Checksum/JSON verification failed: $relative_path"
            fi
        fi
    fi
    mv -f -- "$partial" "$destination"
    printf 'Installed and verified: %s\n' "$relative_path"
done < "$work_dir/manifest.tsv"

printf '\nDone: all 15 files installed and verified.\n'
printf 'Workflow: %s/user/default/workflows/image_krea2_turbo_t2i_v3.json\n' "$COMFYUI_BASE_DIR"
printf '%s\n' \
    'Diffuser: krea2_turbo-Q8_0.gguf (8-bit GGUF, not FP8).' \
    'The downloaded workflow is unchanged. For this diffuser, use ComfyUI-GGUF:' \
    'https://github.com/city96/ComfyUI-GGUF' \
    'Replace its diffusion-model loader with Unet Loader (GGUF), select krea2_turbo-Q8_0.gguf, and reconnect MODEL.' \
    'Install any other custom nodes required by the workflow, then restart/refresh ComfyUI.'
