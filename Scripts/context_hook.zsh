# DynamicTerminal Context Engine & Prompt Styler
# Source this in your .zshrc: source /path/to/context_hook.zsh

DTCTX_DIR="$HOME/.dynamicterminal"
DTCTX_LOG="$DTCTX_DIR/context.jsonl"
DTCTX_MAX=100
DTCTX_LAST_CMD=""
DTCTX_LAST_OUTPUT_FILE="$DTCTX_DIR/.last_output"
export DT_AI_ENABLED=0

mkdir -p "$DTCTX_DIR"

# Start Ollama if it isn't running. Only called once AI is enabled.
dt_start_ollama() {
    if ! pgrep -q ollama; then
        ollama serve &>/dev/null &!
    fi
}

# Escape a string as a JSON literal into $REPLY, without forking.
dt_json() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    REPLY="\"$s\""
}

# Called BEFORE each command runs
dt_preexec() {
    DTCTX_LAST_CMD="$1"
    # Capture output via script command (tee to a temp file)
    # We use PROMPT_COMMAND approach instead for simplicity
}

# Called AFTER each command completes, BEFORE the next prompt
dt_precmd() {
    local exit_code=$?
    
    # Skip if no command was run
    [[ -z "$DTCTX_LAST_CMD" ]] && return
    
    # Honor the toggle switch
    if [[ "$DT_AI_ENABLED" == "0" ]]; then
        DTCTX_LAST_CMD=""
        return
    fi
    
    # Skip our own ai/search commands to avoid recursion
    [[ "$DTCTX_LAST_CMD" == ai\ * ]] && { DTCTX_LAST_CMD=""; return; }
    
    local timestamp=$(date +%s)
    local cwd="$PWD"
    local git_branch=""
    
    # Get git branch if in a repo
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        git_branch=$(git branch --show-current 2>/dev/null)
    fi
    
    # Escape JSON strings
    local cmd_escaped cwd_escaped branch_escaped
    dt_json "$DTCTX_LAST_CMD"; cmd_escaped=$REPLY
    dt_json "$cwd"; cwd_escaped=$REPLY
    dt_json "$git_branch"; branch_escaped=$REPLY
    
    # Write context entry
    echo "{\"ts\":$timestamp,\"cmd\":$cmd_escaped,\"exit\":$exit_code,\"cwd\":$cwd_escaped,\"branch\":$branch_escaped}" >> "$DTCTX_LOG"
    
    # Roll log at max entries
    if [[ $(wc -l < "$DTCTX_LOG") -gt $DTCTX_MAX ]]; then
        tail -n "$DTCTX_MAX" "$DTCTX_LOG" > "$DTCTX_LOG.tmp" && mv "$DTCTX_LOG.tmp" "$DTCTX_LOG"
    fi
    
    # Update directory map on cd
    if [[ "$DTCTX_LAST_CMD" == cd\ * ]] || [[ "$DTCTX_LAST_CMD" == "cd" ]]; then
        dt_update_dirmap &>/dev/null &!
    fi
    
    # Background amortized context ingestion
    command ai -ingest &>/dev/null &!
    
    # Update Terminal Window Title (OSC 0)
    local title_str="${cwd##*/}"
    if [[ -n "$git_branch" ]]; then
        title_str="$title_str — $git_branch"
    fi
    printf "\033]0;%s\007" "$title_str"
    
    DTCTX_LAST_CMD=""
}

# Build directory map of current project
dt_update_dirmap() {
    python3 - "$PWD" "$DTCTX_DIR/dirmap.json" << 'PYEOF'
import os, sys, json

def scan_dir(path, depth=0, max_depth=3):
    if depth > max_depth:
        return None
    result = {"name": os.path.basename(path), "type": "dir", "children": []}
    try:
        entries = sorted(os.listdir(path))
    except PermissionError:
        return result
    for entry in entries:
        if entry.startswith('.') or entry in ('node_modules', '__pycache__', '.build', 'venv'):
            continue
        full = os.path.join(path, entry)
        if os.path.isdir(full):
            child = scan_dir(full, depth + 1, max_depth)
            if child:
                result["children"].append(child)
        else:
            ext = os.path.splitext(entry)[1]
            result["children"].append({"name": entry, "type": "file", "ext": ext})
    return result

root = sys.argv[1]
out = sys.argv[2]
tree = scan_dir(root)
tree["path"] = root
with open(out, 'w') as f:
    json.dump(tree, f, indent=2)
PYEOF
}

# Register hooks
autoload -Uz add-zsh-hook
add-zsh-hook preexec dt_preexec
add-zsh-hook precmd dt_precmd

# Shell wrapper for ai: evals -cmd output in current shell (so cd etc. work)
ai() {
    if [[ "$1" == "-off" ]]; then
        export DT_AI_ENABLED=0
        print -P "%F{red}AI context tracking disabled.%f"
        return
    elif [[ "$1" == "-on" ]]; then
        export DT_AI_ENABLED=1
        print -P "%F{green}AI context tracking enabled.%f"
        dt_start_ollama
        dt_update_dirmap &>/dev/null &!
        # Kick off an immediate context warm-up
        command ai -ingest &>/dev/null &!
        return
    fi

    command ai "$@"
    local cmd_file="$DTCTX_DIR/.ai_cmd"
    if [[ -f "$cmd_file" ]]; then
        local cmd=$(cat "$cmd_file")
        rm -f "$cmd_file"
        eval "$cmd"
    fi
}

