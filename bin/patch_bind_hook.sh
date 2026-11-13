#!/bin/bash
# patch_bind_hook.sh — one-time backfill: add the auto-bind-path `source`
# line to every already-generated module file, so the BIND_CONFIG_FILE
# feature (see BIND_CONFIG_FILE in container-mod's generate_new_modulefile)
# applies retroactively without having to regenerate every module.
#
# Idempotent — safe to re-run; already-patched files are skipped. Follows
# the same append-guard pattern as patch_log_hook.sh, but rewrites the
# existing (empty) bind-path placeholder in place instead of appending at
# EOF, and walks the whole module tree in one pass instead of being called
# once per build.
#
# Usage: patch_bind_hook.sh [--dry-run] [MOD_DIR]
#   --dry-run   Show which files would change (unified diff) without writing.
#   MOD_DIR     Defaults to /usr/local/usrapps/brc/brc_modules/modules

set -uo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

MOD_DIR="${1:-/usr/local/usrapps/brc/brc_modules/modules}"
BIND_CONFIG_FILE="/usr/local/usrapps/brc/env/modules.config"   # shared by all BRC module trees
SOURCE_LINE="source \"${BIND_CONFIG_FILE}\""
MARKER='#-- Optional bind path (set BIND_PATH in your profile to enable)'

if [[ ! -d "$MOD_DIR" ]]; then
    echo "[ERR] module directory not found: $MOD_DIR" >&2
    exit 1
fi

patched=0
skipped_already=0
skipped_no_marker=0

while IFS= read -r -d '' module_file; do
    # Idempotency guard — don't patch twice.
    if grep -qF "$SOURCE_LINE" "$module_file"; then
        skipped_already=$((skipped_already + 1))
        continue
    fi

    if ! grep -qF "$MARKER" "$module_file"; then
        echo "[WARN] no bind-path placeholder found, skipping: $module_file" >&2
        skipped_no_marker=$((skipped_no_marker + 1))
        continue
    fi

    # Replace: marker / blank / blank  ->  marker / source line / blank
    new_content=$(awk -v marker="$MARKER" -v src="$SOURCE_LINE" '
        skip == 1 { skip = 0; next }
        $0 == marker { print; print src; skip = 1; next }
        { print }
    ' "$module_file")

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "--- would patch: $module_file ---"
        diff -u "$module_file" <(printf '%s\n' "$new_content") || true
        patched=$((patched + 1))
        continue
    fi

    # Atomic write via a sibling temp file, same pattern container-mod
    # itself uses, so a killed run can't leave a half-written modulefile.
    tmpfile=$(mktemp "${module_file}.XXXXXX") || {
        echo "[ERR] failed to create temp file next to '$module_file'" >&2
        continue
    }
    if printf '%s\n' "$new_content" > "$tmpfile" && mv "$tmpfile" "$module_file"; then
        chmod 644 "$module_file"
        echo "[OK] patched: $module_file"
        patched=$((patched + 1))
    else
        rm -f "$tmpfile"
        echo "[ERR] failed to write: $module_file" >&2
    fi
done < <(find "$MOD_DIR" -mindepth 2 -maxdepth 2 -type f -print0)

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] would patch: $patched   already patched: $skipped_already   no placeholder: $skipped_no_marker"
else
    echo "patched: $patched   already patched: $skipped_already   no placeholder: $skipped_no_marker"
fi
