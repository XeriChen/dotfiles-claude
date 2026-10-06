claude() {
    local _session
    _session="$(basename "$PWD")-$(openssl rand -hex 8 2>/dev/null || printf '%05x%05x' $RANDOM $RANDOM)"
    SHELL="$(command -v bash)" \
    PYTHONUNBUFFERED=1 \
    AGENT_BROWSER_SESSION="$_session" \
    command claude --thinking-display summarized --allow-dangerously-skip-permissions "$@"
}

ultraclaude() {
    claude --model 'opus[1m]' --effort max --settings '{"disableWorkflows": false, "effort": "ultracode"}'
}

fable() {
    claude --model 'claude-fable-5-1[1m]' $argv
}

opus() {
    claude --model opus "$@"
}

opusplan() {
    claude --model opusplan --permission-mode plan "$@"
}

sonnet() {
    claude --model sonnet "$@"
}

haiku() {
    claude --model haiku "$@"
}

fuck() {
    claude "$(fc -ln -1 | sed 's/^[[:space:]]*//')" "$@"
}
