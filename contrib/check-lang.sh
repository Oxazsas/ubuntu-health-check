#!/bin/bash
# -----------------------------------------------------------------------------
# contrib/check-lang.sh — consistency check of the language catalogs
# (development tool, read-only; run from the repository root, or from
# anywhere: it moves to the repository root itself).
#
# Fails (exit 1) when:
#   (a) a message key used in the code is missing from lib/lang/en/;
#   (b) a key of another language is not in English, or does not use exactly
#       the same {variables} as the English text;
#   (c) an English key is used nowhere in the code;
#   (d) a key appears twice in the same language, or a catalog line is
#       malformed.
# Reports without failing:
#   (e) English keys missing from another language (English is shown instead).
#
# Keys used in the code are found as literal arguments: the first argument of
# t, impact and caution, and the second argument of action. Avoid building
# keys at run time; when it cannot be avoided, list the possible keys in a
# comment that this script reads:   # lang-keys: KEY1 KEY2 ...
# A call to action whose key cannot be read (for example a command written as
# "$(...)" with inner quotes) is an error: put the command in a variable.
# The top-bar icon (contrib/indicator/uhc-indicator.py) is checked the same
# way: the first argument of tr(...) must be a literal key.
# -----------------------------------------------------------------------------

set -uo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

LANG_DIR=lib/lang
errors=0
warnings=0
err()  { printf 'ERROR: %s\n' "$*"; errors=$((errors + 1)); }
warn() { printf 'warning: %s\n' "$*"; warnings=$((warnings + 1)); }

# Shape of a message key: ui.*, section.*, or <FINDING-ID>.*
KEY_RE='(ui|section|[A-Z][A-Z0-9]*(-[A-Z0-9]+)*)\.[A-Za-z0-9_.-]+'

# vars_of TEXT — the sorted, unique {variables} of a message, on one line.
vars_of() {
    grep -oE '\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"$1" | sort -u | tr '\n' ' '
}

# ---- read the catalogs -------------------------------------------------------
# MSG[lang/key] = text; KEYS_<lang> listed in LANG_KEYS[lang] (space-separated).
declare -A MSG=() WHERE=() LANG_KEYS=()
[[ -d "$LANG_DIR/en" ]] || { err "$LANG_DIR/en is missing"; exit 1; }
for dir in "$LANG_DIR"/*/; do
    lang="$(basename "$dir")"
    [[ "$lang" =~ ^[a-z]{2}$ ]] || { err "$dir: language folders must be two lowercase letters"; continue; }
    for file in "$dir"*.lang; do
        [[ -f "$file" ]] || continue
        n=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            line="${line%$'\r'}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" != *=* ]]; then err "$file:$n: line without '='"; continue; fi
            key="${line%%=*}"
            if ! [[ "$key" =~ ^${KEY_RE}$ ]]; then err "$file:$n: malformed key '$key'"; continue; fi
            if [[ -n "${MSG[$lang/$key]+x}" ]]; then
                err "$file:$n: duplicate key $key (first defined in ${WHERE[$lang/$key]})"   # (d)
                continue
            fi
            MSG[$lang/$key]="${line#*=}"
            WHERE[$lang/$key]="$file:$n"
            LANG_KEYS[$lang]+="$key "
        done <"$file"
    done
done

# ---- keys used in the code ---------------------------------------------------
declare -A USED=()
code_files=(uhc.sh lib/*.sh lib/checks/*.sh)
ARG_RE='("([^"\\]|\\.)*"|'"'[^']*'"'|[^[:space:]"'"'"']+)'
T_RE="(^|[^[:alnum:]_.-])(t|impact|caution)[[:space:]]+[\"']?${KEY_RE}"
A_RE="(^|[^[:alnum:]_.-])action[[:space:]]+${ARG_RE}[[:space:]]+[\"']?${KEY_RE}"
# A call to action in command position (start of line, or after ; & | ( { or
# a keyword such as then/do/else).
A_CALL_RE='(^|[;&|({]|then|do|else)[[:space:]]*action[[:space:]]'

for file in "${code_files[@]}"; do
    [[ -f "$file" ]] || continue
    # Join lines continued with a backslash, keep the line number of the start.
    joined="" start=0 n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ -z "$joined" ]] && start=$n
        if [[ "$line" == *\\ ]]; then joined+="${line%\\} "; continue; fi
        joined+="$line"
        logical="$joined"; joined=""
        trimmed="${logical#"${logical%%[![:space:]]*}"}"
        if [[ "$trimmed" == \#* ]]; then
            if [[ "$trimmed" =~ ^#[[:space:]]*lang-keys:(.*)$ ]]; then
                for key in ${BASH_REMATCH[1]}; do USED[$key]="$file:$start"; done
            fi
            continue
        fi
        # Bash matches first (no process for the many lines without a key),
        # then grep -o lists every key of the line.
        if [[ "$logical" =~ $T_RE || "$logical" =~ $A_RE ]]; then
            while IFS= read -r m; do
                [[ -n "$m" ]] || continue
                key="$(grep -oE "${KEY_RE}\$" <<<"$m")"
                [[ -n "$key" ]] && USED[$key]="$file:$start"
            done < <(grep -oE "$T_RE" <<<"$logical"; grep -oE "$A_RE" <<<"$logical")
        fi
        if [[ "$logical" =~ $A_CALL_RE && ! "$logical" =~ $A_RE ]]; then
            err "$file:$start: cannot read the message key of this action call"
        fi
    done <"$file"
done

# ---- keys used by the top-bar icon (Python) ------------------------------------
# Same rules, Python syntax: the first argument of tr(...) is a literal key,
# or the keys are listed in a "# lang-keys:" comment. A tr( call whose key
# cannot be read is an error (the definition 'def tr(' excepted).
py_files=(contrib/indicator/uhc-indicator.py)
PY_RE="(^|[^[:alnum:]_.])tr\\([[:space:]]*[\"']${KEY_RE}[\"']"
PY_CALL_RE='(^|[^[:alnum:]_.])tr\('
for file in "${py_files[@]}"; do
    [[ -f "$file" ]] || { err "$file is missing"; continue; }
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ "$trimmed" == \#* ]]; then
            if [[ "$trimmed" =~ ^#[[:space:]]*lang-keys:(.*)$ ]]; then
                for key in ${BASH_REMATCH[1]}; do USED[$key]="$file:$n"; done
            fi
            continue
        fi
        [[ "$line" =~ $PY_CALL_RE ]] || continue
        found=0
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            key="$(grep -oE "${KEY_RE}" <<<"$m" | tail -n 1)"
            [[ -n "$key" ]] && { USED[$key]="$file:$n"; found=$((found + 1)); }
        done < <(grep -oE "$PY_RE" <<<"$line")
        calls="$(grep -oE "$PY_CALL_RE" <<<"$line" | wc -l)"
        if (( found < calls )) && [[ "$trimmed" != "def tr("* ]]; then
            err "$file:$n: cannot read the message key of this tr() call"
        fi
    done <"$file"
done

# (a) every key used exists in English.
for key in "${!USED[@]}"; do
    [[ -n "${MSG[en/$key]+x}" ]] || err "${USED[$key]}: key $key is missing from $LANG_DIR/en/"
done

# (c) every English key is used.
for key in ${LANG_KEYS[en]:-}; do
    [[ -n "${USED[$key]+x}" ]] || err "${WHERE[en/$key]}: key $key is not used in the code"
done

# (b) and (e) other languages against English.
for lang in "${!LANG_KEYS[@]}"; do
    [[ "$lang" == en ]] && continue
    for key in ${LANG_KEYS[$lang]}; do
        if [[ -z "${MSG[en/$key]+x}" ]]; then
            err "${WHERE[$lang/$key]}: key $key does not exist in English"
        elif [[ "$(vars_of "${MSG[$lang/$key]}")" != "$(vars_of "${MSG[en/$key]}")" ]]; then
            err "${WHERE[$lang/$key]}: {variables} of $key differ from English ($(vars_of "${MSG[en/$key]}"))"
        fi
    done
    missing=0
    for key in ${LANG_KEYS[en]:-}; do
        [[ -n "${MSG[$lang/$key]+x}" ]] || { warn "$lang: missing $key (English is shown)"; missing=$((missing + 1)); }
    done
    (( missing > 0 )) && printf '%s: %d key(s) not translated yet\n' "$lang" "$missing"
done

printf 'check-lang: %d key(s) used, %d English key(s), %d error(s), %d warning(s)\n' \
    "${#USED[@]}" "$(wc -w <<<"${LANG_KEYS[en]:-}")" "$errors" "$warnings"
(( errors == 0 ))
