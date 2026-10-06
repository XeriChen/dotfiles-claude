#!/usr/bin/env bash
# Custom Claude Code statusLine renderer.
#
# Reads stdin JSON (session_id, cwd, model.id, context_window, workspace),
# renders a single line with model + ctx% + cwd + git + audit + idle + drift segments
# scoped to the current session.
#
# Audit segment priority:
#   1. <sid>.json.auditing-<pid>-<ts>  → "auditing… Ns" (cyan) while alive
#   2. <sid>.json.audit-result         → "audit ✓/⚠/✗" (within TTL)
#   3. nothing
#
# Wired in settings.json.statusLine with refreshInterval: 5, so every fork here
# is paid 12x a minute for the life of the session: one jq, one git, one stat,
# nothing else. The audit and drift hooks cost ~100ms on top and are skipped once
# the session goes idle — ~110ms per refresh while working, ~10ms when idle
# (~26ms in a 5k-file repo, where git status dominates what is left).

set -o pipefail

# Read fd 0 directly rather than reopening /dev/stdin: claude hands the status
# line a socketpair, and a socket cannot be reopened through /proc/self/fd.
IFS= read -r -d '' input

# One jq call for every field; `// ""` keeps the line count fixed so the reads
# below stay aligned even when a field is absent.
fields=$(jq -r '
  .session_id // "",
  .cwd // "",
  .workspace.project_dir // "",
  .model.id // .model.display_name // "",
  .context_window.used_percentage // ""
' 2>/dev/null <<<"$input")

{
  IFS= read -r session_id
  IFS= read -r cwd
  IFS= read -r project_dir
  IFS= read -r model_id
  IFS= read -r ctx_pct
} <<<"$fields"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

file_mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null ||
    stat -f '%m' "$1" 2>/dev/null ||
    true
}

# --- model_short -------------------------------------------------------------
# claude-opus-4-7[1m] -> opus-4.7-1m  ;  display_name passes through.
model_segment=""
if [[ -n "$model_id" ]]; then
  if [[ "$model_id" == claude-* ]]; then
    rest="${model_id#claude-}"
    m=""
    while [[ "$rest" =~ ([0-9])-([0-9]) ]]; do
      m+="${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    m+="$rest"
    [[ "$m" == *\[*\]* ]] && m="${m/\[/-}" && m="${m/]/}"
  else
    m="$model_id"
  fi
  model_segment="${BOLD}${MAGENTA}${m}${RESET}"
fi

# --- ctx% --------------------------------------------------------------------
ctx_segment=""
if [[ "$ctx_pct" =~ ^[0-9]+$ ]] && (( ctx_pct > 0 )); then
  if   (( ctx_pct < 70 )); then color=$GREEN
  elif (( ctx_pct < 85 )); then color=$YELLOW
  else                          color=$RED
  fi
  ctx_segment=" ${color}[${ctx_pct}%]${RESET}"
fi

# --- cwd_short ---------------------------------------------------------------
cwd_segment=""
if [[ -n "$cwd" ]]; then
  if [[ -n "$project_dir" && "$cwd" == "$project_dir"* ]]; then
    rel="${cwd#$project_dir}"
    rel="${rel#/}"
    cwd_short="${rel:-${project_dir##*/}}"
  elif [[ "$cwd" == "$HOME" ]]; then
    cwd_short="~"
  elif [[ "$cwd" == "$HOME/"* ]]; then
    cwd_short="~/${cwd#$HOME/}"
  else
    cwd_short="${cwd##*/}"
  fi
  cwd_segment="${BLUE}${cwd_short}${RESET}"
fi

# --- git ---------------------------------------------------------------------
# --branch makes one status call answer all three questions: is this a repo,
# which branch, any dirt. Header line is "## main...origin/main" (or "## HEAD
# (no branch)" when detached, "## No commits yet on main" on a fresh repo).
git_segment=""
if [[ -n "$cwd" ]]; then
  # --no-optional-locks: several sessions poll the same repo 12x a minute, and a
  # plain status refreshes (writes) the index and can fight index.lock.
  git_status=$(git --no-optional-locks -C "$cwd" status --porcelain --branch 2>/dev/null)
  if [[ -n "$git_status" ]]; then
    branch=""
    dirty=""
    while IFS= read -r line; do
      if [[ "$line" == '## '* ]]; then
        branch="${line#\#\# }"
        branch="${branch#No commits yet on }"
        branch="${branch%%...*}"
      else
        dirty=1
      fi
    done <<<"$git_status"
    if [[ -n "$branch" && "$branch" != HEAD* ]]; then
      if [[ -n "$dirty" ]]; then
        git_segment="  ${YELLOW}${branch}*${RESET}"
      else
        git_segment="  ${GREEN}${branch}${RESET}"
      fi
    fi
  fi
fi

# --- idle time ----------------------------------------------------------------
# Seconds since last transcript activity; empty when unknown.
elapsed=""
if [[ -n "$session_id" ]]; then
  shopt -s nullglob
  transcripts=("$HOME"/.claude/projects/*/"${session_id}".jsonl)
  shopt -u nullglob
  transcript="${transcripts[0]:-}"
  if [[ -f "$transcript" ]]; then
    last_epoch=$(file_mtime_epoch "$transcript")
    [[ -n "$last_epoch" ]] && elapsed=$(( ${EPOCHSECONDS:-$(date +%s)} - last_epoch ))
  fi
fi

# Warm sessions run the python hooks; cold ones skip them. Unknown counts as warm.
warm=1
[[ -n "$elapsed" ]] && (( elapsed >= 300 )) && warm=0

# --- idle segment -------------------------------------------------------------
# Hidden <2min, blue 2–5min, gray ≥5min (cache TTL).
idle_segment=""
if [[ -n "$elapsed" ]]; then
  h=$((elapsed / 3600)); m=$(((elapsed % 3600) / 60)); s=$((elapsed % 60))
  if   (( h > 0 ));         then fmt="${h}h ${m}m ${s}s"
  elif (( elapsed >= 60 )); then fmt="${m}m ${s}s"
  else                           fmt="${s}s"
  fi
  if   (( elapsed >= 300 )); then color=$GRAY; idle_segment="  ${color}[${fmt}]${RESET}"
  elif (( elapsed >= 120 )); then color=$BLUE; idle_segment="  ${color}[${fmt}]${RESET}"
  fi
fi

# --- drift segment -----------------------------------------------------------
# Windowed B-ratio (tokens per grounding event). Empty until 5+ turns.
drift_segment=""
if [[ -n "$session_id" ]] && (( warm )); then
  drift_segment=$(~/.claude/hooks/drift-detect.py statusline "$session_id" 2>/dev/null || true)
fi

# --- last-file segment -------------------------------------------------------
# URL of the most recent SendUserFile delivery in this session. Written by
# hooks/track-sent-file.sh; kitty's ctrl+shift+e hints can select it.
file_segment=""
if [[ -n "$session_id" ]]; then
  file_state="/tmp/claude-${UID}-state/last-file-url/${session_id}"
  if [[ -f "$file_state" ]]; then
    url=""
    IFS= read -r url < "$file_state"
    [[ -n "$url" ]] && file_segment="  ${CYAN}${url}${RESET}"
  fi
fi

# --- compose -----------------------------------------------------------------
left="${model_segment}${ctx_segment}"
[[ -n "$left" && -n "$cwd_segment" ]] && left+="  "
printf '%s%s%s%s%s%s\n' "$left" "$cwd_segment" "$git_segment" "$idle_segment" "$drift_segment" "$file_segment"
