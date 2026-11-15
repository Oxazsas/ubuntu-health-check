# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/install.sh — installation helpers (never run during an audit):
#   - root_install_wizard: 'sudo ./uhc.sh' from a user-owned folder installs
#     or updates the root-owned copy used for full audits (from the public
#     repository or from this folder) and offers the aliases (and, to a
#     user with a graphical session, the top-bar icon). It never runs
#     an audit from the user-owned folder, and never runs without a terminal;
#   - install_aliases / remove_aliases: optional shell aliases;
#   - install_timer / remove_timer / timer_status: scheduled audits with a
#     systemd timer (user units, or system units for the root-owned copy);
#   - install_indicator / remove_indicator: optional top-bar icon (desktop
#     only), started at login by an autostart entry.
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
            offer_indicator
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
    offer_indicator
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

# ---- scheduled audits (systemd timers) --------------------------------------------
# --install-timer / --remove-timer / --timer-status. Two scopes:
#   - user: systemd user units uhc.service + uhc.timer in the user's own
#     configuration (no sudo; refused as root), running this folder's uhc.sh
#     unprivileged;
#   - root: system units uhc-root.service + uhc-root.timer in /etc/systemd/system,
#     running the root-owned copy (ROOT_INSTALL_DIR) only; installed and removed
#     only by that copy, run as root, in a terminal (uhc.sh refuses the other
#     cases before its trust check).
# The text of every unit comes from the unit_text_* functions below, and only
# from them: the files in contrib/ are reference copies checked by
# contrib/check-units.sh. Files this tool writes carry TIMER_MARKER; a file
# without it is never replaced without saying so and asking, and never removed.
TIMER_MARKER="# Managed by ubuntu-health-check: change it with --install-timer, remove it with --remove-timer."
TIMER_FORMAT="# ubuntu-health-check timer-format 1"
SYSTEM_UNIT_DIR=/etc/systemd/system

# Quoting for unit files. sd_path: a path inside double quotes (spaces), with %
# (specifiers) doubled: for the executable of an Exec line, where systemd does
# not expand $, and for ReadWritePaths=. sd_word: the same for an argument of an
# Exec line, where $ (variable expansion) is doubled too. systemd refuses quotes
# and backslashes in an executable path, so the callers refuse paths containing
# ", ' or \ or control characters (sd_unsafe) instead of escaping them.
sd_path() { printf '"%s"' "${1//%/%%}"; }
sd_word() { local s="${1//%/%%}"; printf '"%s"' "${s//\$/\$\$}"; }
sd_unsafe() { [[ "$1" == *[[:cntrl:]\"\'\\]* ]]; }

# timer_calendar SCOPE FREQ — OnCalendar value: daytime, user at 10:00, root
# at 11:00 (two scheduled audits of one machine do not start together).
timer_calendar() {
    local h=10
    [[ "$1" == root ]] && h=11
    case "$2" in
        daily)   printf '*-*-* %02d:00:00' "$h" ;;
        weekly)  printf 'Mon *-*-* %02d:00:00' "$h" ;;
        monthly) printf '*-*-01 %02d:00:00' "$h" ;;
    esac
}

has_cntrl() { [[ "$1" == *[[:cntrl:]]* ]]; }

# unit_text_timer SCOPE FREQ — the timer unit (SCOPE and FREQ already validated).
unit_text_timer() {
    local scope="$1" freq="$2" when what missed cal
    cal="$(timer_calendar "$scope" "$freq")"
    case "$freq" in
        daily)   when="Every day" ;;
        weekly)  when="Every Monday" ;;
        monthly) when="1st day of each month" ;;
    esac
    what="Ubuntu Health Check"; missed="next session start"
    [[ "$scope" == root ]] && { what="full Ubuntu Health Check (root)"; missed="next boot"; }
    cat <<UNIT
${TIMER_MARKER}
${TIMER_FORMAT}
# Frequency: ${freq}

[Unit]
Description=${what^}, ${freq}

[Timer]
# ${when} at ${cal: -8:5}, within 15 minutes.
OnCalendar=${cal}
RandomizedDelaySec=15min
# If the machine was off at that time, run at the ${missed}.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

# unit_text_user_service TOOL_DIR DATA_DIR — the user service: TOOL_DIR/uhc.sh,
# unprivileged and quiet; --data-dir only when DATA_DIR is not empty.
unit_text_user_service() {
    local exec
    exec="$(sd_path "$1/uhc.sh") --quiet"
    [[ -n "$2" ]] && exec+=" --data-dir $(sd_word "$2")"
    cat <<UNIT
${TIMER_MARKER}
${TIMER_FORMAT}

[Unit]
Description=Ubuntu Health Check (read-only maintenance audit)

[Service]
Type=oneshot
ExecStart=${exec}
# Exit codes 1 (warnings) and 2 (critical findings) are audit results,
# not failures of the service.
SuccessExitStatus=1 2
# Low priority: never slow down interactive work.
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=yes
UNIT
}

# unit_text_root_service DATA_DIR USER — the system service: the root-owned
# copy, reports in DATA_DIR (written with the privileges of its owner, as in
# any root run), USER (may be empty) as the audited user, like 'sudo' sets it.
# The sandbox only takes away what a read-only audit never needs: the root
# audit still reads the whole system (journal, /sys, /home, disks).
unit_text_root_service() {
    local user_line=""
    [[ -n "$2" ]] && user_line="# Audited user (home-directory checks), as 'sudo' sets it for uhc-root.
Environment=SUDO_USER=${2//%/%%}"
    cat <<UNIT
${TIMER_MARKER}
${TIMER_FORMAT}

[Unit]
Description=Ubuntu Health Check, full audit as root (read-only)

[Service]
Type=oneshot
ExecStart=$(sd_path "${ROOT_INSTALL_DIR}/uhc.sh") --data-dir $(sd_word "$1") --quiet --no-notify
${user_line}
# Exit codes 1 (warnings) and 2 (critical findings) are audit results,
# not failures of the service.
SuccessExitStatus=1 2
Nice=10
IOSchedulingClass=idle

# Sandbox. The whole file system is read-only except: the data directory
# (reports and logs, written as its owner), the private state of the root
# copy, and /run (lock file /run/ubuntu-health-check.lock). /tmp is private.
ProtectSystem=strict
ReadWritePaths=$(sd_path "$1") $(sd_path "${ROOT_INSTALL_DIR}/state") /run
PrivateTmp=yes
UMask=0077
# The audit gains no privilege, changes no kernel setting, loads no module,
# mounts nothing, creates no namespace and makes no network connection
# (local sockets and netlink only).
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectKernelTunables=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=~@cpu-emulation @debug @module @mount @obsolete @raw-io @reboot @swap
SystemCallErrorNumber=EPERM
RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET AF_INET6
IPAddressDeny=any
UNIT
}

# systemd_running — this system was booted with systemd.
systemd_running() { [[ -d /run/systemd/system ]]; }

# user_manager_ok — the caller's systemd user manager answers.
user_manager_ok() { systemctl --user show --property=Version >/dev/null 2>&1; }

# user_unit_dir — where systemd reads the user's own units. As root (only for
# --timer-status), the audited user's default location.
user_unit_dir() {
    local base="${XDG_CONFIG_HOME:-}"
    if [[ "$IS_ROOT" == 1 ]]; then base="${TARGET_HOME}/.config"
    elif [[ "$base" != /* ]]; then base="${HOME}/.config"; fi
    printf '%s/systemd/user' "$base"
}

# read_unit FILE — print FILE; as root, a file in the audited user's home is
# read with that user's privileges.
read_unit() {
    if [[ "$IS_ROOT" == 1 && "$TARGET_USER" != root && "$1" == "$TARGET_HOME"/* ]]; then
        as_target cat -- "$1" 2>/dev/null
    else
        cat -- "$1" 2>/dev/null
    fi
}

# unit_is_ours FILE — FILE is a regular file (not a symlink) written by this tool.
unit_is_ours() { [[ -f "$1" && ! -L "$1" ]] && read_unit "$1" | grep -qxF -- "$TIMER_MARKER"; }

# unit_state SCOPE DIR NAME — none, daily, weekly, monthly, or custom (a timer
# unit is there but is not one this tool wrote, or was edited since).
unit_state() {
    local scope="$1" timer="$2/$3.timer" service="$2/$3.service" text freq
    [[ -e "$timer" || -L "$timer" ]] || { echo none; return; }
    if unit_is_ours "$timer" && unit_is_ours "$service"; then
        text="$(read_unit "$timer")"
        freq="$(sed -n 's/^# Frequency: \(daily\|weekly\|monthly\)$/\1/p' <<<"$text" | head -n1)"
        if [[ -n "$freq" ]] && grep -qxF -- "OnCalendar=$(timer_calendar "$scope" "$freq")" <<<"$text"; then
            echo "$freq"; return
        fi
    fi
    echo custom
}

# timer_status — two lines on stdout, for people and programs:
#   user=<none|daily|weekly|monthly|custom>
#   root=<none|daily|weekly|monthly|custom>
# Reads files only (no systemctl call): works without privileges and without
# a session; without systemd, both are none.
timer_status() {
    local u=none r=none
    if systemd_running; then
        u="$(unit_state user "$(user_unit_dir)" uhc)"
        r="$(unit_state root "$SYSTEM_UNIT_DIR" uhc-root)"
    fi
    printf 'user=%s\nroot=%s\n' "$u" "$r"
    exit 0
}

# no_scheduler REASON — nothing can be scheduled with systemd: say why, point
# to cron, write nothing.
no_scheduler() {
    cat >&2 <<EOF
uhc: $1
Nothing was changed. Without systemd, or outside a user session, cron can
schedule the audit: see contrib/crontab.example (README, "Scheduling").
EOF
    exit 3
}

# confirm_timer QUESTION — go ahead after --yes (user scope only, checked by
# uhc.sh), or after a yes in a terminal. Without either, stop.
confirm_timer() {
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    is_interactive || die "this command asks for confirmation: run it in a terminal${TIMER_YES_HINT:-}"
    ask "$1" n || { echo "Cancelled." >&2; exit 0; }
}

# write_unit_file FILE TEXT — replace FILE atomically (new file in the same
# directory, then renamed over it: a symlink is replaced, never followed).
write_unit_file() {
    local tmp
    tmp="$(mktemp "$(dirname -- "$1")/.uhc-unit.XXXXXX")" || return 1
    if ! { printf '%s\n' "$2" >"$tmp" && chmod 644 "$tmp" && mv -fT -- "$tmp" "$1"; }; then
        rm -f -- "$tmp"; return 1
    fi
}

# timer_scope_setup SCOPE — set the variables of a scope: unit directory and
# name, systemctl command, hint for the confirmation message. Stops when
# systemd (or, for the user scope, the user manager) is not there.
timer_scope_setup() {
    systemd_running || no_scheduler "systemd is not running on this system (no /run/systemd/system)."
    if [[ "$1" == user ]]; then
        [[ "$IS_ROOT" == 0 ]] || die "the user timer belongs to your own account: run this without sudo"
        TU_DIR="$(user_unit_dir)"; TU_NAME=uhc; TU_SCTL=(systemctl --user)
        TIMER_YES_HINT=", or add --yes"
        has_cntrl "$TU_DIR" && die "the unit directory contains control characters: $(printf '%q' "$TU_DIR")"
        user_manager_ok || no_scheduler "your systemd user manager cannot be reached (no user session: started from cron, su, or a service?). Run this command from your desktop or SSH session."
    else
        # Defence in depth: uhc.sh already refused every other case.
        [[ "$IS_ROOT" == 1 && "$UHC_DIR" == "$ROOT_INSTALL_DIR" ]] \
            || die "the root timer is managed by the root-owned copy only: sudo ${ROOT_INSTALL_DIR}/uhc.sh"
        TU_DIR="$SYSTEM_UNIT_DIR"; TU_NAME=uhc-root; TU_SCTL=(systemctl)
        TIMER_YES_HINT=" (--yes is not accepted for the root timer)"
    fi
}

# install_timer SCOPE FREQ — write (or rewrite) the service and timer units of
# SCOPE for FREQ, then enable the timer. Run again to change the frequency.
install_timer() {
    local scope="$1" freq="$2" svc tmr svc_text tmr_text f stamp user="" data=""
    local foreign=() cmds=()
    timer_scope_setup "$scope"
    svc="${TU_DIR}/${TU_NAME}.service"; tmr="${TU_DIR}/${TU_NAME}.timer"
    sd_unsafe "$UHC_DIR" && die "systemd cannot run a program whose path contains quotes, backslashes or control characters: $(printf '%q' "$UHC_DIR"); move the tool first"
    sd_unsafe "$DATA_DIR" && die "the data directory path contains quotes, backslashes or control characters, which this tool does not write into a unit: $(printf '%q' "$DATA_DIR")"

    if [[ "$scope" == user ]]; then
        [[ "$DATA_DIR" != "$UHC_DIR" ]] && data="$DATA_DIR"
        svc_text="$(unit_text_user_service "$UHC_DIR" "$data")"
    else
        [[ "$DATA_DIR" == "$ROOT_INSTALL_DIR" || "$DATA_DIR" == "$ROOT_INSTALL_DIR"/* ]] \
            && die "give the data directory where the reports go (yours): sudo ${ROOT_INSTALL_DIR}/uhc.sh --data-dir DIR --install-timer root ${freq}   (the uhc-root alias adds --data-dir)"
        # SUDO_USER was already reduced to a plain user name by uhc.sh.
        [[ "${SUDO_USER:-}" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$SUDO_USER" != root ]] && user="$SUDO_USER"
        svc_text="$(unit_text_root_service "$DATA_DIR" "$user")"
    fi
    tmr_text="$(unit_text_timer "$scope" "$freq")"

    # Already installed exactly like this and enabled: nothing to do.
    if unit_is_ours "$svc" && unit_is_ours "$tmr" \
        && [[ "$(read_unit "$svc")" == "$svc_text" && "$(read_unit "$tmr")" == "$tmr_text" ]] \
        && "${TU_SCTL[@]}" is-enabled --quiet "${TU_NAME}.timer" 2>/dev/null; then
        echo "The ${scope} timer is already installed and enabled (${freq}); nothing to change." >&2
        exit 0
    fi
    for f in "$svc" "$tmr"; do
        if [[ -e "$f" || -L "$f" ]] && ! unit_is_ours "$f"; then foreign+=("$f"); fi
    done

    [[ "$scope" == root ]] && cmds+=("install -d -o root -g root -m 700 $(printf '%q' "${ROOT_INSTALL_DIR}/state")")
    cmds+=("${TU_SCTL[*]} daemon-reload" "${TU_SCTL[*]} enable --now ${TU_NAME}.timer")
    {
        printf '\nThis will write %s:\n\n%s\n\nand %s:\n\n%s\n\n' "$svc" "$svc_text" "$tmr" "$tmr_text"
        printf 'Then run:\n'
        printf '  %s\n' "${cmds[@]}"
        echo ""
    } >&2
    if (( ${#foreign[@]} > 0 )); then
        stamp="$(date '+%Y%m%d-%H%M%S')"
        {
            echo "These files already exist and were NOT written by ubuntu-health-check"
            echo "(installed by hand?). They would be replaced, after a copy:"
            for f in "${foreign[@]}"; do printf '  %s  ->  copy kept as %s\n' "$f" "${f}.uhc-backup-${stamp}"; done
            echo ""
        } >&2
        [[ "${ASSUME_YES:-0}" == 1 ]] \
            && die "refusing to replace files not written by ubuntu-health-check with --yes; run the command in a terminal, or remove them first"
    fi
    confirm_timer "Install the ${scope} timer (${freq})?"
    if (( ${#foreign[@]} > 0 )); then
        ask "Replace the existing files listed above (copies kept)?" n || { echo "Cancelled." >&2; exit 0; }
        for f in "${foreign[@]}"; do
            cp -P -- "$f" "${f}.uhc-backup-${stamp}" || die "cannot copy $f; nothing replaced"
        done
    fi

    if [[ "$scope" == user ]]; then mkdir -p -- "$TU_DIR" || die "cannot create $TU_DIR"; fi
    write_unit_file "$svc" "$svc_text" || die "cannot write $svc"
    write_unit_file "$tmr" "$tmr_text" || die "cannot write $tmr"
    # ReadWritePaths= needs it to exist; the audit creates it otherwise.
    if [[ "$scope" == root ]]; then
        install -d -o root -g root -m 700 "${ROOT_INSTALL_DIR}/state" || die "cannot create ${ROOT_INSTALL_DIR}/state"
    fi
    "${TU_SCTL[@]}" daemon-reload || die "'${TU_SCTL[*]} daemon-reload' failed; the unit files are written"
    "${TU_SCTL[@]}" enable --now "${TU_NAME}.timer" \
        || die "'${TU_SCTL[*]} enable --now ${TU_NAME}.timer' failed; the unit files are written"

    echo "Done. Next run: ${TU_SCTL[*]} list-timers ${TU_NAME}.timer" >&2
    echo "Run it once now: ${TU_SCTL[*]} start ${TU_NAME}.service   (then: ${TU_SCTL[*]} status ${TU_NAME}.service)" >&2
    [[ "$scope" == user ]] \
        && echo "A user timer runs while your user manager is alive (normally: while you are logged in); to run it without a login session: sudo loginctl enable-linger $(id -un)" >&2
    echo "The next audit will report the new unit as a new startup job (SVC-PERSISTENCE-NEW-*): expected, accept it with --accept-jobs." >&2
    exit 0
}

# remove_timer SCOPE — disable the timer and remove the units of SCOPE, if
# this tool wrote them. A unit without the marker is left in place.
remove_timer() {
    local scope="$1" f ours=() foreign=()
    if ! systemd_running; then
        echo "systemd is not running on this system: no timer to remove." >&2
        exit 0
    fi
    timer_scope_setup "$scope"
    for f in "${TU_DIR}/${TU_NAME}.timer" "${TU_DIR}/${TU_NAME}.service"; do
        if [[ -e "$f" || -L "$f" ]]; then
            if unit_is_ours "$f"; then ours+=("$f"); else foreign+=("$f"); fi
        fi
    done
    if (( ${#ours[@]} + ${#foreign[@]} == 0 )); then
        echo "No ${scope} timer installed by ubuntu-health-check (${TU_DIR})." >&2
        exit 0
    fi
    if (( ${#foreign[@]} > 0 )); then
        {
            echo "uhc: these files were not written by ubuntu-health-check; nothing was removed:"
            printf '  %s\n' "${foreign[@]}"
            echo "If you installed them by hand and want them gone:"
            echo "  ${TU_SCTL[*]} disable --now ${TU_NAME}.timer"
            printf '  rm -i --'; printf ' %q' "${ours[@]}" "${foreign[@]}"; echo ""
            echo "  ${TU_SCTL[*]} daemon-reload"
        } >&2
        exit 3
    fi
    {
        printf '\nThis will run:\n  %s disable --now %s.timer\n' "${TU_SCTL[*]}" "$TU_NAME"
        printf '  rm --'; printf ' %q' "${ours[@]}"; echo ""
        printf '  %s daemon-reload\n\n' "${TU_SCTL[*]}"
    } >&2
    confirm_timer "Remove the ${scope} timer?"
    "${TU_SCTL[@]}" disable --now "${TU_NAME}.timer" \
        || echo "uhc: '${TU_SCTL[*]} disable --now ${TU_NAME}.timer' failed; removing the files anyway" >&2
    rm -f -- "${ours[@]}" || die "cannot remove the unit files"
    "${TU_SCTL[@]}" daemon-reload || echo "uhc: '${TU_SCTL[*]} daemon-reload' failed; run it yourself" >&2
    echo "Removed." >&2
    exit 0
}

# ---- top-bar icon (desktop only) ----------------------------------------------------
# --install-indicator / --remove-indicator: an autostart entry that starts
# contrib/indicator/uhc-indicator.py (Python, GTK 3 and AyatanaAppIndicator3)
# at each login. Optional, never installed by default, refused as root, and
# offered by the installation wizard only when the user has a graphical
# session. The entry carries INDICATOR_MARKER; a file without it is never
# replaced nor removed. The audit itself never needs the icon.
INDICATOR_MARKER="# Managed by ubuntu-health-check: remove it with --remove-indicator."
INDICATOR_FORMAT="# ubuntu-health-check indicator-format 1"
INDICATOR_PYTHON=/usr/bin/python3
INDICATOR_REL="contrib/indicator/uhc-indicator.py"

# indicator_autostart_file — the autostart entry of the user running this.
indicator_autostart_file() {
    local base="${XDG_CONFIG_HOME:-}"
    [[ "$base" == /* ]] || base="${HOME}/.config"
    printf '%s/autostart/uhc-indicator.desktop' "$base"
}

# de_unsafe PATH — PATH cannot be written safely in an Exec= line: control
# characters, the characters that stay special inside a quoted argument
# (" ` $ \), or bytes that are not UTF-8 (a desktop entry is UTF-8 text).
de_unsafe() {
    [[ "$1" == *[[:cntrl:]\"\`\$\\]* ]] && return 0
    ! printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

# de_arg PATH — one argument of an Exec= line (Desktop Entry specification):
# always double-quoted (spaces and reserved characters such as ' & ; ( ) are
# then literal), % doubled (field codes). The four characters that would
# still need escaping inside the quotes are refused by de_unsafe beforehand.
de_arg() { printf '"%s"' "${1//%/%%}"; }

# indicator_desktop_text TOOL_DIR DATA_DIR — the autostart entry; --data-dir
# only when DATA_DIR is not empty. Paths already checked with de_unsafe.
indicator_desktop_text() {
    local exec
    exec="${INDICATOR_PYTHON} -I $(de_arg "$1/${INDICATOR_REL}")"
    [[ -n "$2" ]] && exec+=" --data-dir $(de_arg "$2")"
    cat <<ENTRY
${INDICATOR_MARKER}
${INDICATOR_FORMAT}
[Desktop Entry]
Type=Application
Name=Ubuntu Health Check indicator
Comment=State of the last maintenance audit, in the top bar
Exec=${exec}
TryExec=${INDICATOR_PYTHON}
Icon=$1/contrib/indicator/icons/uhc-indicator-ok.svg
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
ENTRY
}

# indicator_is_ours FILE — FILE is a regular file (not a symlink) written by this tool.
indicator_is_ours() { [[ -f "$1" && ! -L "$1" ]] && grep -qxF -- "$INDICATOR_MARKER" "$1" 2>/dev/null; }

# graphical_session_of USER — USER has a graphical (Wayland or X11) login
# session now, according to systemd-logind (read-only; works without the
# session's environment, e.g. from sudo or SSH).
graphical_session_of() {
    local id type
    have loginctl || return 1
    id="$(timeout 5 loginctl show-user "$1" -p Display --value 2>/dev/null)"
    [[ "$id" =~ ^[A-Za-z0-9]+$ ]] || return 1
    type="$(timeout 5 loginctl show-session "$id" -p Type --value 2>/dev/null)"
    [[ "$type" == wayland || "$type" == x11 ]]
}

# indicator_missing — print one line per missing element (empty: all there).
indicator_missing() {
    local py="$INDICATOR_PYTHON"
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]] && ! graphical_session_of "$(id -un)"; then
        echo "  - a graphical session: log in to the desktop (Ubuntu Desktop or another desktop) first"
    fi
    [[ -f "${UHC_DIR}/${INDICATOR_REL}" && -d "${UHC_DIR}/contrib/indicator/icons" ]] \
        || echo "  - the icon program, ${UHC_DIR}/${INDICATOR_REL} (incomplete copy of the tool?)"
    if [[ ! -x "$py" ]]; then
        echo "  - Python 3 (${py}): package python3"
        return
    fi
    if ! timeout 20 "$py" -I -c 'import gi' >/dev/null 2>&1; then
        echo "  - the Python GObject bindings: package python3-gi"
        return
    fi
    timeout 20 "$py" -I -c 'import gi; gi.require_version("Gtk", "3.0")' >/dev/null 2>&1 \
        || echo "  - GTK 3 for Python: package gir1.2-gtk-3.0"
    timeout 20 "$py" -I -c 'import gi; gi.require_version("AyatanaAppIndicator3", "0.1")' >/dev/null 2>&1 \
        || echo "  - the AyatanaAppIndicator3 library for Python: package gir1.2-ayatanaappindicator3-0.1"
}

# indicator_panel_note — say when nothing in this session shows tray icons
# (no StatusNotifierWatcher on the session bus; under GNOME, that is the
# AppIndicator extension). A note only: the entry still works once it runs.
indicator_panel_note() {
    local bus="${DBUS_SESSION_BUS_ADDRESS:-}" ans="" ext d
    [[ -z "$bus" && -S "/run/user/$(id -u)/bus" ]] && bus="unix:path=/run/user/$(id -u)/bus"
    if [[ -n "$bus" ]] && have gdbus; then
        ans="$(DBUS_SESSION_BUS_ADDRESS="$bus" timeout 5 gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
            org.kde.StatusNotifierWatcher 2>/dev/null)"
    fi
    [[ "$ans" == "(true,)" ]] && return 0
    [[ -x /usr/bin/gnome-shell ]] || {
        [[ "$ans" == "(false,)" ]] && echo "Note: nothing in this session seems to show tray icons (no StatusNotifierWatcher on the session bus): the icon may stay invisible." >&2
        return 0
    }
    ext=""
    for d in /usr/share/gnome-shell/extensions "${HOME}/.local/share/gnome-shell/extensions"; do
        [[ -d "$d/ubuntu-appindicators@ubuntu.com" ]] && { ext=ubuntu-appindicators@ubuntu.com; break; }
        [[ -d "$d/appindicatorsupport@rgcjonas.gmail.com" ]] && { ext=appindicatorsupport@rgcjonas.gmail.com; break; }
    done
    if [[ -z "$ext" ]]; then
        echo "Note: GNOME shows this kind of icon only with the AppIndicator extension, which seems absent (package gnome-shell-extension-appindicator). Without it, the icon stays invisible." >&2
    elif [[ "$ans" == "(false,)" ]]; then
        echo "Note: the GNOME AppIndicator extension (${ext}) seems disabled: the icon stays invisible until it is enabled, in the Extensions app or with: gnome-extensions enable ${ext}" >&2
    fi
}

# indicator_start_cmd DATA — the command that starts the icon (array INDICATOR_CMD).
indicator_start_cmd() {
    INDICATOR_CMD=("$INDICATOR_PYTHON" -I "${UHC_DIR}/${INDICATOR_REL}")
    [[ -n "$1" ]] && INDICATOR_CMD+=(--data-dir "$1")
}

# indicator_offer_start DATA — start the icon now when this terminal is part
# of the graphical session; otherwise say how. The language read by uhc.sh
# (it forces the C locale for itself) is passed on as UHC_LANG.
indicator_offer_start() {
    local shown
    indicator_start_cmd "$1"
    shown="$(printf '%q ' "${INDICATOR_CMD[@]}")"
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
        echo "The icon will start at your next login. To start it now, run this in a terminal of your desktop session:" >&2
        echo "  ${shown% }" >&2
        return 0
    fi
    ask "Start the icon now?" y || return 0
    if [[ -n "${UHC_LOCALE_LANG:-}" ]]; then
        setsid -f /usr/bin/env UHC_LANG="$UHC_LOCALE_LANG" "${INDICATOR_CMD[@]}" </dev/null >/dev/null 2>&1
    else
        setsid -f "${INDICATOR_CMD[@]}" </dev/null >/dev/null 2>&1
    fi
    echo "Started (if it was already running, the running icon stays)." >&2
}

# install_indicator — write the autostart entry, after confirmation.
install_indicator() {
    local file text missing data=""
    [[ "$IS_ROOT" == 0 ]] || die "--install-indicator belongs to your desktop session: run it without sudo"
    is_interactive || die "--install-indicator needs a terminal (it asks for confirmation)"
    missing="$(indicator_missing)"
    if [[ -n "$missing" ]]; then
        printf 'uhc: the top-bar icon needs:\n%s\nNothing was written. (The audit itself does not need the icon.)\n' "$missing" >&2
        exit 3
    fi
    de_unsafe "$UHC_DIR" && die "the tool path cannot be written safely in a desktop entry (quotes, backslashes, \$, \` or control characters, or not UTF-8): $(printf '%q' "$UHC_DIR"); move the tool first"
    de_unsafe "$DATA_DIR" && die "the data directory path cannot be written safely in a desktop entry: $(printf '%q' "$DATA_DIR")"
    file="$(indicator_autostart_file)"
    has_cntrl "$file" && die "the autostart directory contains control characters: $(printf '%q' "$file")"
    [[ "$DATA_DIR" != "$UHC_DIR" ]] && data="$DATA_DIR"
    text="$(indicator_desktop_text "$UHC_DIR" "$data")"

    if [[ -e "$file" || -L "$file" ]]; then
        indicator_is_ours "$file" \
            || die "$file exists and was not written by ubuntu-health-check; nothing was written. Rename or remove it yourself first if you want this icon."
        if [[ "$(cat -- "$file")" == "$text" ]]; then
            echo "The top-bar icon is already installed (${file}); nothing to change." >&2
            indicator_offer_start "$data"
            exit 0
        fi
    fi
    indicator_panel_note
    printf '\nThis will write %s (the icon then starts at each login):\n\n%s\n\n' "$file" "$text" >&2
    ask "Install the top-bar icon?" n || { echo "Cancelled." >&2; exit 0; }
    mkdir -p -- "$(dirname -- "$file")" || die "cannot create $(dirname -- "$file")"
    write_unit_file "$file" "$text" || die "cannot write $file"
    echo "Done. Remove it with: $(printf '%q' "${UHC_DIR}/uhc.sh") --remove-indicator" >&2
    indicator_offer_start "$data"
    exit 0
}

# remove_indicator — remove the autostart entry, if this tool wrote it.
remove_indicator() {
    local file
    [[ "$IS_ROOT" == 0 ]] || die "--remove-indicator belongs to your desktop session: run it without sudo"
    file="$(indicator_autostart_file)"
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        echo "No top-bar icon installed by ubuntu-health-check (${file})." >&2
        exit 0
    fi
    indicator_is_ours "$file" \
        || die "$file was not written by ubuntu-health-check; nothing was removed."
    is_interactive || die "--remove-indicator needs a terminal (it asks for confirmation)"
    ask "Remove the top-bar icon from your login (${file})?" n || { echo "Cancelled." >&2; exit 0; }
    rm -f -- "$file" || die "cannot remove $file"
    echo "Removed: the icon will no longer start at login." >&2
    echo "To close the running icon now: its menu, 'Quit the icon', or: pkill -u $(id -un) -f $(printf '%q' "${UHC_DIR}/${INDICATOR_REL}")" >&2
    exit 0
}

# offer_indicator — installation wizard (root): offer the icon to the invoking
# user, only when that user has a graphical session (nothing at all on a
# server), with that user's own privileges, as offer_aliases does. Reports
# go where the wizard's --data-dir says, as for the first full audit.
offer_indicator() {
    local home a want="" data="" args=()
    [[ -n "${SUDO_USER:-}" ]] || return 0
    graphical_session_of "$SUDO_USER" || return 0
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$home" ]] || return 0
    for a in "${ORIG_ARGS[@]}"; do
        if [[ -n "$want" ]]; then data="$a"; want=""; continue; fi
        [[ "$a" == -d || "$a" == --data-dir ]] && want=1
    done
    [[ -n "$data" ]] && args=(--data-dir "$data")
    # Already installed: checked as the user (the file is in their home).
    runuser -u "$SUDO_USER" -- /usr/bin/env -i /usr/bin/grep -qxF -- "$INDICATOR_MARKER" \
        "${home}/.config/autostart/uhc-indicator.desktop" 2>/dev/null && return 0
    echo "" >&2
    echo "Optional: an icon in the top bar of your desktop, showing the state of the last audit." >&2
    runuser -u "$SUDO_USER" -- /usr/bin/env -i HOME="$home" PATH="$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        TERM="${TERM:-dumb}" /bin/bash -p "${UHC_DIR}/uhc.sh" "${args[@]}" --install-indicator || true
}
