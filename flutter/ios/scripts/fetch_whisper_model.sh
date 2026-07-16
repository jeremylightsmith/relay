#!/usr/bin/env bash
# RLY-99 D2: downloads the WhisperKit CoreML model + tokenizer this app bundles.
# Idempotent — skips files already present. NOT committed (no git-lfs in this
# repo; ~147MB would also burn CI checkout time and LFS quota). The Xcode build
# phase "[Relay] Bundle Whisper model" runs this and copies the result into the
# app bundle, so `flutter run`, `flutter build ios`, and CI all just work.
#
# Expect ~147MB on first run. That is the real WhisperKit .mlmodelc figure for
# base.en — the old ~60MB estimate was GGML/whisper.cpp and is stale (spec
# "Size note").
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)" # flutter/ios
DEST="$DIR/Runner/Models"
MODEL_REPO="argmaxinc/whisperkit-coreml"
MODEL_DIR="openai_whisper-base.en"
# The tokenizer is bundled too: WhisperKit otherwise downloads it from HF on
# first transcription, which would silently break airplane mode (criterion 6).
TOKENIZER_REPO="openai/whisper-base.en"

fetch() { # $1 repo  $2 remote-path  $3 local-path
  [ -s "$3" ] && return 0
  mkdir -p "$(dirname "$3")"
  echo "fetching $1/$2"
  curl --fail --silent --show-error --location --retry 3 \
    "https://huggingface.co/$1/resolve/main/$2" -o "$3"
}

list_model_files() {
  python3 - "$MODEL_REPO" "$MODEL_DIR" <<'PYEOF'
import json, sys, urllib.request
repo, prefix = sys.argv[1], sys.argv[2]
url = f"https://huggingface.co/api/models/{repo}/tree/main/{prefix}?recursive=true"
with urllib.request.urlopen(url) as r:
    for entry in json.load(r):
        # .mlmodelc is the runtime format; the repo's duplicate .mlpackage
        # copies are dead weight we do not ship (spec "Size note").
        if entry["type"] == "file" and ".mlpackage" not in entry["path"]:
            print(entry["path"])
PYEOF
}

list_model_files | while IFS= read -r remote; do
  fetch "$MODEL_REPO" "$remote" "$DEST/$remote"
done

for f in config.json generation_config.json tokenizer.json \
         tokenizer_config.json vocab.json merges.txt \
         special_tokens_map.json added_tokens.json normalizer.json; do
  # Not every tokenizer file exists in every Whisper repo; absent ones are fine.
  fetch "$TOKENIZER_REPO" "$f" "$DEST/tokenizer/$f" || true
done

# A truncated model would surface as a runtime "model_load_failed"; fail the
# build here instead, where the cause is legible.
for required in \
  "$DEST/$MODEL_DIR/AudioEncoder.mlmodelc" \
  "$DEST/$MODEL_DIR/TextDecoder.mlmodelc" \
  "$DEST/$MODEL_DIR/MelSpectrogram.mlmodelc" \
  "$DEST/tokenizer/tokenizer.json"; do
  [ -e "$required" ] || { echo "fetch_whisper_model: missing $required" >&2; exit 1; }
done
echo "Whisper model ready at $DEST"
