#!/usr/bin/env bash
# Step 11: host directories the cluster mounts, owned by the current user (no sudo).
#   MODEL_CACHE_DIR            model1's Hugging Face cache, mounted as /models
#   MODEL_CACHE_DIR/local/<m>  hard links to LOCAL_MODELS_SRC/<m> (no extra disk space)
# Safe to re-run: existing links are kept, nothing is overwritten.
source "$(dirname "$0")/lib.sh"

mkdir -p "$MODEL_CACHE_PATH" || die "cannot create $MODEL_CACHE_PATH"
[[ -w "$MODEL_CACHE_PATH" ]] || die "$MODEL_CACHE_PATH is not writable for $(id -un)"

src_root="${LOCAL_MODELS_SRC/#\~/$HOME}"
for model in $LOCAL_MODELS; do
  src="$src_root/$model"
  dst="$MODEL_CACHE_PATH/local/$model"
  if [[ ! -f "$src/config.json" ]]; then
    warn "local model $model not found in $src_root, skipped"
    continue
  fi
  linked=0
  # every file except the git metadata of the original download
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    target="$dst/$rel"
    if [[ -e "$target" ]]; then
      [[ "$f" -ef "$target" ]] || warn "$target exists and is not a link to $f, kept"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    ln "$f" "$target" || die "cannot hard-link $f (different filesystem than $MODEL_CACHE_PATH?)"
    linked=$((linked + 1))
  done < <(find "$src" -name '.git*' -prune -o -type f -print0)
  log "Local model $model: $linked new link(s) -> MODEL_ID=/models/local/$model"
done

log "Model cache: $MODEL_CACHE_PATH ($(du -sh "$MODEL_CACHE_PATH" | cut -f1) incl. hard links)"
