# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/install.sh — installation helpers (never run during an audit):
#   - root_install_wizard: 'sudo ./uhc.sh' from a user-owned folder installs
#     or updates the root-owned copy used for full audits (from the public
#     repository or from this folder) and offers the aliases. It never runs
#     an audit from the user-owned folder, and never runs without a terminal;
#   - install_aliases / remove_aliases: optional shell aliases.
#
# Security model of the root copy, stated honestly:
#   Running as root requires code that no other account can modify, hence the
#   root-owned copy in ROOT_INSTALL_DIR. What it protects: once installed, and
#   as long as full audits are started from that copy (the uhc-root alias does
#   it), root runs no longer depend on this user-writable folder, so a later
#   modification of it cannot reach root. That is why 'sudo ./uhc.sh' is only an
#   installer: making it the usual entry point would run this folder as root
#   every time. What it cannot protect: the copy
#   itself. If this folder was already altered when you install, the altered
#   code is installed (and the wizard you are running is that code). Installing
#   from the public repository avoids this intermediate folder altogether.
#   The wizard never runs without a terminal: nothing is installed as root by
#   cron, a timer or a script.
# -----------------------------------------------------------------------------

# is_interactive — a human is at the terminal (stdin and stderr are TTYs).
is_interactive() { [[ -t 0 && -t 2 ]]; }

# ask QUESTION DEFAULT — prompt on the terminal; DEFAULT is y or n. True if yes.
ask() {
    local question="$1" default="$2" answer hint="[y/N]"
    [[ "$default" == y ]] && hint="[Y/n]"
    read -r -p "$question $hint " answer </dev/tty || answer=""
    answer="${answer,,}"
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" == y || "$answer" == yes || "$answer" == o || "$answer" == oui ]]
}

# install_root_copy SOURCE_DIR — copy uhc.sh and lib/ from SOURCE_DIR into
# ROOT_INSTALL_DIR, owned by root and writable by root only. Files are staged
# first; symlinks are copied as symlinks, so the trust check refuses them.
install_root_copy() {
    local src="$1" stage
    [[ -f "$src/uhc.sh" && -d "$src/lib" ]] || { echo "uhc: $src does not contain the tool" >&2; return 1; }
    install -d -o root -g root -m 755 "$ROOT_INSTALL_DIR" || return 1
    stage="$(mktemp -d "${ROOT_INSTALL_DIR}/.stage.XXXXXX")" || return 1
    if ! { cp -R --no-preserve=all -- "$src/uhc.sh" "$src/lib" "$stage/" \
            && chown -R root:root "$stage" \
            && chmod -R u=rwX,go=rX "$stage" \
            && chmod 755 "$stage/uhc.sh" \
            && rm -rf -- "${ROOT_INSTALL_DIR:?}/lib" "${ROOT_INSTALL_DIR:?}/uhc.sh" \
            && mv -- "$stage/uhc.sh" "$stage/lib" "$ROOT_INSTALL_DIR/" \
            && rmdir -- "$stage"; }; then
        rm -rf -- "$stage"; echo "uhc: installation failed" >&2; return 1
    fi
    if [[ -n "$(untrusted_paths "${ROOT_INSTALL_DIR}/uhc.sh" "${ROOT_INSTALL_DIR}/lib")" ]]; then
        echo "uhc: the installed copy is not trusted (symlinks or permissions); aborting" >&2
        return 1
    fi
}

# install_from_repo — clone the release tag of this version (v$UHC_VERSION)
# from UHC_REPO_URL into a private temporary directory, then install from it.
# The code goes from the repository to a root-owned location without passing
# through a user-writable folder. A tag, not the default branch: the default
# branch may contain unreleased, unreviewed changes.
install_from_repo() {
    local tmp rc tag="v${UHC_VERSION}"
    have git || { echo "uhc: git is not installed" >&2; return 1; }
    # Ask the repository first: git ls-remote --exit-code returns 0 when the
    # tag exists, 2 when the repository answered but has no such tag, and
    # another code when it could not be reached (network, address, access).
    echo "Checking ${UHC_REPO_URL} for tag ${tag} ..." >&2
    git ls-remote --exit-code --tags -- "$UHC_REPO_URL" "refs/tags/${tag}" >/dev/null; rc=$?
    case "$rc" in
        0)  ;;
        2)  echo "uhc: the repository has no tag ${tag} (not published yet?)." >&2
            ask "Clone the default branch instead (may contain unreleased changes)?" n || return 1
            tag="" ;;
        *)  echo "uhc: cannot reach ${UHC_REPO_URL} (git error above). Check the network, or install from this folder." >&2
            return 1 ;;
    esac
    tmp="$(mktemp -d -t uhc-clone.XXXXXXXX)" || return 1
    echo "Cloning ${UHC_REPO_URL}${tag:+ (tag ${tag})} ..." >&2
    # git's own error messages stay visible.
    if git clone --quiet --depth 1 ${tag:+--branch "$tag"} -- "$UHC_REPO_URL" "$tmp/repo"; then
        install_root_copy "$tmp/repo"; rc=$?
    else
        echo "uhc: git clone failed (error above)." >&2; rc=1
    fi
    rm -rf -- "$tmp"
    return "$rc"
}

# run_root_copy — replace this process by the root-owned copy, with the same
# options; reports go to this folder unless --data-dir was given.
run_root_copy() {
    local args=("${ORIG_ARGS[@]}") a
    for a in "${args[@]}"; do
        [[ "$a" == -d || "$a" == --data-dir ]] && exec /bin/bash -p "${ROOT_INSTALL_DIR}/uhc.sh" "${args[@]}"
    done
    exec /bin/bash -p "${ROOT_INSTALL_DIR}/uhc.sh" "${args[@]}" --data-dir "$UHC_DIR"
}

# root_full_audit_cmd — the command to use for full audits.
root_full_audit_cmd() { printf 'sudo %s/uhc.sh --data-dir %s' "$ROOT_INSTALL_DIR" "$UHC_DIR"; }

# aliases_current HOME — true if HOME/.bash_aliases already holds the current
# aliases of this tool for this folder.
aliases_current() {
    B="$ALIAS_BEGIN" E="$ALIAS_END" awk '$0 == ENVIRON["B"] {on = 1} on {print} $0 == ENVIRON["E"] {on = 0}' \
        "$1/.bash_aliases" 2>/dev/null | grep -qF "aliases-format 3 for ${UHC_DIR}"
}

# offer_aliases — run the alias installer with the invoking user's own
# privileges (it edits a file in their home; root must not write there).
offer_aliases() {
    local home
    [[ -n "${SUDO_USER:-}" ]] || return 0
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$home" ]] || return 0
    aliases_current "$home" && return 0
    echo "" >&2
    echo "Optional: shell aliases for your account (uhc, uhc-root, uhc-last)." >&2
    runuser -u "$SUDO_USER" -- /usr/bin/env -i HOME="$home" PATH="$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        TERM="${TERM:-dumb}" /bin/bash -p "${UHC_DIR}/uhc.sh" --install-aliases || true
}

# root_install_wizard — 'sudo ./uhc.sh' from a folder that is not root-owned.
# Installs or updates the root-owned copy, offers the aliases, and offers to
# run the first audit from the new copy. It never runs an audit from this
# folder: with an up-to-date copy, it only says which command to use.
root_install_wizard() {
    local src_fp dest_fp="" choice
    if ! is_interactive; then
        cat >&2 <<EOF
uhc: refusing to run as root from ${UHC_DIR}: this code can be modified by a
non-root account. 'sudo ./uhc.sh' only installs or updates the root-owned copy,
in a terminal. Full audits: $(root_full_audit_cmd)
EOF
        exit 3
    fi
    src_fp="$(fingerprint_of "$UHC_DIR")"
    if [[ -f "${ROOT_INSTALL_DIR}/uhc.sh" && -z "$(untrusted_paths "${ROOT_INSTALL_DIR}/uhc.sh" "${ROOT_INSTALL_DIR}/lib")" ]]; then
        dest_fp="$(fingerprint_of "$ROOT_INSTALL_DIR")"
        if [[ "$dest_fp" == "$src_fp" ]]; then
            cat >&2 <<EOF
The root-owned copy in ${ROOT_INSTALL_DIR} is up to date (fingerprint ${dest_fp}).
'sudo ./uhc.sh' only installs or updates it; it does not run audits.

  Full audit:     $(root_full_audit_cmd)    (alias: uhc-root)
  Routine audit:  ${UHC_DIR}/uhc.sh    (no sudo; alias: uhc)
EOF
            offer_aliases
            exit 0
        fi
    fi

    cat >&2 <<EOF

A full audit runs as root, and root must only run code that no other account
can modify. This folder (${UHC_DIR}) belongs to your account, so full audits
use a root-owned copy in ${ROOT_INSTALL_DIR}, started directly from there.
'sudo ./uhc.sh' installs or updates that copy; it never runs an audit.

  This folder:     fingerprint ${src_fp}
  Root copy:       $([[ -n "$dest_fp" ]] && echo "installed, fingerprint ${dest_fp} (different)" || echo "not installed")

Installing trusts the code as it is now. If you are unsure whether this folder
was modified, install from the public repository instead (when available).
EOF
    if [[ -n "$UHC_REPO_URL" ]]; then
        echo "" >&2
        echo "Sources: (r) public repository ${UHC_REPO_URL}, tag v${UHC_VERSION} [recommended], (l) this folder, (c) cancel" >&2
        read -r -p "Install from? [r/l/C] " choice </dev/tty || choice=c
        case "${choice,,}" in
            r) install_from_repo || exit 3 ;;
            l) install_root_copy "$UHC_DIR" || exit 3 ;;
            *) echo "Cancelled." >&2; exit 3 ;;
        esac
    else
        echo "" >&2
        ask "$([[ -n "$dest_fp" ]] && echo Update || echo Install) the root-owned copy from this folder?" n \
            || { echo "Cancelled. Routine audits still work without sudo." >&2; exit 3; }
        install_root_copy "$UHC_DIR" || exit 3
    fi
    cat >&2 <<EOF
Installed in ${ROOT_INSTALL_DIR} (fingerprint $(fingerprint_of "$ROOT_INSTALL_DIR")).

From now on:
  Full audit:     $(root_full_audit_cmd)    (alias: uhc-root)
  Routine audit:  ${UHC_DIR}/uhc.sh    (no sudo; alias: uhc)
  After updating this folder, run 'sudo ./uhc.sh' again to update the copy.
EOF
    offer_aliases
    echo "" >&2
    ask "Run a first full audit from the root-owned copy now?" y && run_root_copy
    exit 0
}

# ---- aliases ---------------------------------------------------------------------
ALIAS_BEGIN="# >>> ubuntu-health-check >>>"
ALIAS_END="# <<< ubuntu-health-check <<<"

# squote TEXT — single-quote TEXT for the shell (falls back to %q if it
# contains a single quote).
squote() {
    if [[ "$1" != *"'"* ]]; then printf "'%s'" "$1"; else printf '%q' "$1"; fi
}

# dq_inner TEXT — TEXT escaped for use *inside* an existing double-quoted
# string: the four characters still active there (\ " $ `) get a backslash, so
# the text is displayed as is and nothing in it is ever executed.
dq_inner() { printf '%s' "$1" | sed 's/[\\"$`]/\\&/g'; }

# dquote TEXT — double-quote TEXT when that is safe (no " $ ` \ inside),
# otherwise fall back to %q. Used inside a single-quoted alias value.
dquote() {
    if [[ "$1" =~ ^[^\"\$\`\\]*$ ]]; then printf '"%s"' "$1"; else printf '%q' "$1"; fi
}

# strip_alias_block FILE — print FILE without the block managed by this tool.
strip_alias_block() {
    [[ -f "$1" ]] || return 0
    B="$ALIAS_BEGIN" E="$ALIAS_END" awk '$0 == ENVIRON["B"] {skip = 1} !skip {print} $0 == ENVIRON["E"] {skip = 0}' "$1"
}

# write_aliases_file CONTENT — replace ~/.bash_aliases atomically, keeping its mode.
write_aliases_file() {
    local file="${HOME}/.bash_aliases" tmp mode=644
    [[ -f "$file" ]] && mode="$(stat -c '%a' "$file")"
    tmp="$(mktemp "${HOME}/.bash_aliases.XXXXXX")" || return 1
    if ! { printf '%s' "$1" >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$file"; }; then
        rm -f -- "$tmp"; return 1
    fi
}

# install_aliases NAME — add NAME, NAME-root and NAME-last to ~/.bash_aliases.
install_aliases() {
    local name="$1" n conflicts="" block content
    [[ "$IS_ROOT" == 0 ]] || die "--install-aliases edits your own ~/.bash_aliases: run it without sudo"
    [[ "$name" =~ ^[a-z][a-z0-9_-]{0,19}$ ]] || die "invalid alias name: $name"
    is_interactive || die "--install-aliases needs a terminal (it asks for confirmation)"

    # Names already used by a command, or defined in the user's shell files
    # (outside the block this tool manages).
    # Directories searched: the caller's PATH (kept aside by uhc.sh, only used
    # here to test file names, never to run anything), the system PATH, and
    # common per-user tool directories (Cargo, Go, Volta, npm, Deno, Bun...).
    local d dirs=()
    IFS=: read -r -a dirs <<<"${UHC_ORIG_PATH:-}:${PATH}"
    dirs+=("${HOME}/.local/bin" "${HOME}/bin" "${HOME}/.cargo/bin" "${HOME}/go/bin" "${HOME}/.volta/bin"
           "${HOME}/.npm-global/bin" "${HOME}/.deno/bin" "${HOME}/.bun/bin" "${HOME}/.local/share/pnpm")
    for n in "$name" "${name}-root" "${name}-last"; do
        for d in "${dirs[@]}"; do
            [[ -n "$d" && -e "$d/$n" ]] && { conflicts+="  $n: existing command ($d/$n)"$'\n'; break; }
        done
        for f in "${HOME}/.bashrc" "${HOME}/.profile" "${HOME}/.bash_aliases"; do
            if strip_alias_block "$f" | grep -Eq "^[[:space:]]*(alias[[:space:]]+${n}=|${n}[[:space:]]*\(\)|function[[:space:]]+${n}([[:space:]]|\())"; then
                conflicts+="  $n: already defined in ${f/#$HOME/\~}"$'\n'
            fi
        done
    done
    if [[ -n "$conflicts" ]]; then
        printf 'uhc: these names are already in use:\n%s\nChoose another prefix, e.g.: %s --install-aliases ubhc\n' "$conflicts" "$0" >&2
        exit 3
    fi

    # All three are shell functions, not aliases: an alias is parsed again
    # each time it is used, so a path containing spaces or $(...) would break
    # it or even run code; a function body is parsed once, at definition.
    # uhc-root always uses the root-owned copy, never this folder: if the copy
    # is missing, it says how to install it instead of running anything.
    block="${ALIAS_BEGIN}
# ubuntu-health-check aliases-format 3 for ${UHC_DIR}
# Added on $(date '+%Y-%m-%d'). Remove with: ${name} --remove-aliases
${name}() { $(dquote "${UHC_DIR}/uhc.sh") \"\$@\"; }
${name}-root() { if [ -x ${ROOT_INSTALL_DIR}/uhc.sh ]; then sudo ${ROOT_INSTALL_DIR}/uhc.sh --data-dir $(dquote "$UHC_DIR") \"\$@\"; else echo \"${name}-root: root-owned copy not installed; install it once with: sudo $(dq_inner "${UHC_DIR}/uhc.sh")\" >&2; return 1; fi; }
${name}-last() { local f; f=\$(ls -t $(squote "$REPORT_DIR")/uhc-*.md 2>/dev/null | head -n1); [ -n \"\$f\" ] && less \"\$f\"; }
${ALIAS_END}"

    printf '\nThese lines will be added to ~/.bash_aliases:\n\n%s\n\n' "$block" >&2
    ask "Add them?" n || { echo "Cancelled." >&2; exit 0; }
    content="$(strip_alias_block "${HOME}/.bash_aliases")"
    [[ -n "$content" ]] && content+=$'\n'
    write_aliases_file "${content}${block}"$'\n' || die "cannot write ~/.bash_aliases"
    echo "Done. Open a new terminal, or run: source ~/.bashrc" >&2
    grep -q 'bash_aliases' "${HOME}/.bashrc" 2>/dev/null \
        || echo "Note: your ~/.bashrc does not load ~/.bash_aliases; add: [ -f ~/.bash_aliases ] && . ~/.bash_aliases" >&2
    echo "The next audit will report these new lines (SVC-PERSISTENCE-NEW-SHELL): expected, accept them with --accept-jobs." >&2
    [[ -f "${ROOT_INSTALL_DIR}/uhc.sh" ]] \
        || echo "${name}-root needs the root-owned copy: install it once with 'sudo ${UHC_DIR}/uhc.sh'." >&2
    exit 0
}

# remove_aliases — remove the block managed by this tool from ~/.bash_aliases.
remove_aliases() {
    [[ "$IS_ROOT" == 0 ]] || die "--remove-aliases edits your own ~/.bash_aliases: run it without sudo"
    if ! grep -qxF "$ALIAS_BEGIN" "${HOME}/.bash_aliases" 2>/dev/null; then
        echo "No aliases installed by ubuntu-health-check in ~/.bash_aliases." >&2
        exit 0
    fi
    if is_interactive; then
        ask "Remove the ubuntu-health-check aliases from ~/.bash_aliases?" n || { echo "Cancelled." >&2; exit 0; }
    fi
    write_aliases_file "$(strip_alias_block "${HOME}/.bash_aliases")"$'\n' || die "cannot write ~/.bash_aliases"
    echo "Removed. Open a new terminal for the change to take effect." >&2
    exit 0
}
