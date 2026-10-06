function claude
    set -lx SHELL (command -v bash)
    set -lx PYTHONUNBUFFERED 1
    set -lx AGENT_BROWSER_SESSION (basename $PWD)-(command -sq openssl; and openssl rand -hex 8; or random)
    command claude --thinking-display summarized --allow-dangerously-skip-permissions $argv
end

function ultraclaude
    claude --model 'opus[1m]' --effort max --settings '{"disableWorkflows": false, "effort": "ultracode"}'
end

function fable
    claude --model 'claude-fable-5-1[1m]' $argv
end

function opus
    claude --model opus $argv
end

function opusplan
    claude --model opusplan --permission-mode plan $argv
end

function sonnet
    claude --model sonnet $argv
end

function haiku
    claude --model haiku $argv
end

function fuck
    claude $history[1] $argv
end
