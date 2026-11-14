#!/usr/bin/env bash
# Deploy from a jump host, driven over SSH from your workstation.
#
# Use it when your workstation cannot reach the node network directly (see docs/requirements.md).
# Everything runs on the jump host; nothing site-specific is stored in the repository.
#
# Configuration: environment variables, or a git-ignored file `jump-host.env` next to this
# root module (copy jump-host.env.example):
#
#   JUMP_HOST   SSH destination: host, user@host or an alias from ~/.ssh/config (required)
#   JUMP_DIR    working directory on the jump host (default: ~/educates)
#   REPO_URL    repository to clone (default: this clone's 'origin' URL)
#   REPO_REF    commit, tag or branch to deploy (default: this clone's HEAD commit, which must be pushed)
#   JUMP_VARS_FILE  name of your tfvars file in JUMP_DIR (default: site.tfvars)
#
# Layout on the jump host (created by `setup`; you add site.tfvars and proxmox.env):
#
#   $JUMP_DIR/repo/          clone, pinned to REPO_REF, push disabled
#   $JUMP_DIR/site.tfvars    your values (name set by JUMP_VARS_FILE)
#   $JUMP_DIR/proxmox.env    secrets (TF_VAR_...), mode 0600
#   $JUMP_DIR/state/         state, plans, kubeconfig, talosconfig, mode 0700
#                            (the script always passes client_configs_dir=$JUMP_DIR/state)
#   $JUMP_DIR/home/          HOME for every command run here (caches of kubectl, helm, providers):
#                            nothing is written to the jump host user's home (scripts/guest-env.sh)
#   $JUMP_DIR/bin/           optional tools (for example the educates CLI), first in PATH
#
# Commands:
#   setup                 create the layout, clone the repository, keep the state in state/
#                         (an existing clone or backend_override.tf is kept)
#   sync [ref]            check out ref (default REPO_REF) and run `tofu init`
#   preflight [--after]   run scripts/preflight.sh on the jump host
#   plan                  tofu plan, saved to state/plan.out
#   apply                 apply state/plan.out inside tmux (re-attaches if the session exists)
#   shell                 tmux session in the root module: secrets, KUBECONFIG, TALOSCONFIG,
#                         and $JUMP_DIR/bin in PATH (for tools you keep there, such as the educates CLI)
#   ssh                   plain SSH session (your own; guest-env.sh is not loaded)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$MODULE_DIR" rev-parse --show-toplevel)"
MODULE_PATH="${MODULE_DIR#"$REPO_ROOT"/}"

if [ -f "$MODULE_DIR/jump-host.env" ]; then
  # shellcheck disable=SC1091
  . "$MODULE_DIR/jump-host.env"
fi

: "${JUMP_HOST:?Set JUMP_HOST (in jump-host.env or the environment)}"
JUMP_DIR="${JUMP_DIR:-~/educates}"
# An unquoted ~ in jump-host.env expands to the LOCAL home: map it back to the remote one.
JUMP_DIR="${JUMP_DIR/#"$HOME"/\~}"
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin)}"
REPO_REF="${REPO_REF:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
VARS_FILE="${JUMP_VARS_FILE:-site.tfvars}"
SESSION="educates"

# The remote shell expands $HOME (a leading ~ would not survive the quoting), once, at the
# start of every command: guest-env.sh changes HOME afterwards.
JD_INIT="JD=\"${JUMP_DIR/#\~/\$HOME}\""
D='$JD'
MOD="$D/repo/$MODULE_PATH"
# Every command on the jump host runs with scripts/guest-env.sh: HOME inside the work
# directory, so nothing is written to the jump host user's home.
LOAD_ENV=". \"$MOD/scripts/guest-env.sh\" \"$D\""
TF="\$(command -v tofu || command -v terraform)"
VARS="-var-file=\"$D/$VARS_FILE\" -var=\"client_configs_dir=$D/state\""

remote() { ssh "$JUMP_HOST" "bash -lc '$JD_INIT; $1'"; }
remote_tty() { ssh -t "$JUMP_HOST" "bash -lc '$JD_INIT; $1'"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  setup)
    remote "
      set -e
      mkdir -p \"$D/state\" && chmod 700 \"$D/state\"
      if [ ! -d \"$D/repo/.git\" ]; then git clone --quiet \"$REPO_URL\" \"$D/repo\"; fi
      git -C \"$D/repo\" remote set-url --push origin no-push
      [ -f \"$MOD/backend_override.tf\" ] || cat > \"$MOD/backend_override.tf\" <<EOF
terraform {
  backend \"local\" {
    path = \"$D/state/terraform.tfstate\"
  }
}
EOF
      [ -f \"$D/proxmox.env\" ] && chmod 600 \"$D/proxmox.env\" || echo \"Create $D/proxmox.env (mode 0600) with TF_VAR_proxmox_api_token and TF_VAR_proxmox_csi_token_secret\"
      [ -f \"$D/$VARS_FILE\" ] || echo \"Create $D/$VARS_FILE (start from $MOD/examples/)\"
      echo \"Layout ready in $D\"
    "
    "$0" sync "$REPO_REF"
    ;;
  sync)
    ref="${1:-$REPO_REF}"
    remote "
      set -e
      cd \"$D/repo\"
      git fetch --quiet --tags origin
      git checkout --quiet --detach \"$ref\" 2>/dev/null || git checkout --quiet --detach \"origin/$ref\"
      echo \"Checked out \$(git rev-parse --short HEAD) (\$(git log -1 --format=%s))\"
      cd \"$MOD\" && $LOAD_ENV && $TF init -input=false >/dev/null && echo \"init done\"
    "
    ;;
  preflight)
    remote_tty "cd \"$MOD\" && $LOAD_ENV && scripts/preflight.sh --var-file \"$D/$VARS_FILE\" --client-configs-dir \"$D/state\" $*"
    ;;
  plan)
    remote_tty "cd \"$MOD\" && $LOAD_ENV && $TF plan -input=false $VARS -out=\"$D/state/plan.out\""
    ;;
  apply)
    remote_tty "tmux new -A -s $SESSION \"cd $MOD && $LOAD_ENV && $TF apply $D/state/plan.out; rm -f $D/state/plan.out; exec bash\""
    ;;
  shell)
    remote_tty "tmux new -A -s $SESSION-shell \"cd $MOD && $LOAD_ENV && exec bash\""
    ;;
  ssh)
    exec ssh -t "$JUMP_HOST"
    ;;
  *)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
