#!/usr/bin/env bash
# Deploy from a jump host, driven over SSH from your workstation.
#
# Use it when your workstation cannot reach the node network directly (see docs/requirements.md).
# Everything runs on the jump host; nothing site-specific is stored in the repository.
#
# Configuration: environment variables, or a git-ignored file `jump-host.env` next to this
# root module (copy jump-host.env.example). With several clusters, keep one file per cluster
# (jump-host.<name>.env, also git-ignored) and select it with JUMP_ENV=jump-host.<name>.env.
#
#   JUMP_HOST   SSH destination: host, user@host or an alias from ~/.ssh/config (required)
#   JUMP_DIR    working directory on the jump host (default: ~/educates)
#   REPO_URL    repository to clone (default: this clone's 'origin' URL)
#   REPO_REF    commit, tag or branch to deploy (default: this clone's HEAD commit, which must be pushed)
#   JUMP_VARS_FILE  name of your tfvars file in JUMP_DIR (default: my-cluster.tfvars)
#
# Layout on the jump host (created by `setup`; you add my-cluster.tfvars and proxmox.env):
#
#   $JUMP_DIR/repo/          clone, pinned to REPO_REF, push disabled
#   $JUMP_DIR/my-cluster.tfvars    your values (name set by JUMP_VARS_FILE)
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
#   plan [args]           tofu plan, saved to state/plan.out; extra args go to tofu
#                         (plan -destroy prepares a destroy, applied with `apply`)
#   apply                 apply state/plan.out inside a tmux session (refused while that session exists)
#   attach                re-attach to the apply session, for example after losing the connection
#   e2e [options]         run scripts/e2e-test.sh on the jump host (see its --help)
#   shell                 tmux session in the root module: secrets, KUBECONFIG, TALOSCONFIG,
#                         and $JUMP_DIR/bin in PATH (for tools you keep there, such as the educates CLI)
#   ssh                   plain SSH session (your own; guest-env.sh is not loaded)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$MODULE_DIR" rev-parse --show-toplevel)"
MODULE_PATH="${MODULE_DIR#"$REPO_ROOT"/}"

JUMP_ENV="${JUMP_ENV:-jump-host.env}"
case "$JUMP_ENV" in /*) ;; *) JUMP_ENV="$MODULE_DIR/$JUMP_ENV" ;; esac
if [ -f "$JUMP_ENV" ]; then
  # shellcheck disable=SC1090
  . "$JUMP_ENV"
fi

: "${JUMP_HOST:?Set JUMP_HOST (in jump-host.env or the environment)}"
JUMP_DIR="${JUMP_DIR:-~/educates}"
# An unquoted ~ in jump-host.env expands to the LOCAL home: map it back to the remote one.
JUMP_DIR="${JUMP_DIR/#"$HOME"/\~}"
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin)}"
REPO_REF="${REPO_REF:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
VARS_FILE="${JUMP_VARS_FILE:-my-cluster.tfvars}"
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
PLAN="$D/state/plan.out"

# sq: single-quote a string for a shell. dq: double-quote it, leaving $ live (for $JD).
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
dq() { printf '"%s"' "${1//\"/\\\"}"; }
# Extra arguments, each quoted, to append to a remote command.
args() { local a; for a in "$@"; do printf ' %s' "$(sq "$a")"; done; }

remote() { ssh "$JUMP_HOST" "bash -lc $(sq "$JD_INIT; $1")"; }
remote_tty() { ssh -t "$JUMP_HOST" "bash -lc $(sq "$JD_INIT; $1")"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  setup)
    remote "
      set -e
      mkdir -p \"$D/state\" && chmod 700 \"$D/state\"
      if [ ! -d \"$D/repo/.git\" ]; then git clone --quiet \"$REPO_URL\" \"$D/repo\"; fi
      git -C \"$D/repo\" remote set-url --push origin no-push
      # Check out REPO_REF before writing into the module: it may not exist on the default branch.
      git -C \"$D/repo\" fetch --quiet --tags origin
      git -C \"$D/repo\" checkout --quiet --detach \"origin/$REPO_REF\" 2>/dev/null || git -C \"$D/repo\" checkout --quiet --detach \"$REPO_REF\"
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
      # origin/<branch> first: a local branch of the same name may be stale.
      git checkout --quiet --detach \"origin/$ref\" 2>/dev/null || git checkout --quiet --detach \"$ref\"
      echo \"Checked out \$(git rev-parse --short HEAD) (\$(git log -1 --format=%s))\"
      cd \"$MOD\" && $LOAD_ENV && $TF init -input=false >/dev/null && echo \"init done\"
    "
    ;;
  preflight)
    remote_tty "cd \"$MOD\" && $LOAD_ENV && scripts/preflight.sh --var-file \"$D/$VARS_FILE\" --client-configs-dir \"$D/state\"$(args "$@")"
    ;;
  plan)
    remote_tty "cd \"$MOD\" && $LOAD_ENV && $TF plan -input=false $VARS$(args "$@") -out=\"$PLAN\""
    ;;
  apply)
    # Runs inside tmux, so a lost connection does not interrupt it. tofu is looked up there,
    # after guest-env.sh (it may live in $JUMP_DIR/bin). The plan is removed once applied.
    run="cd \"$MOD\" && $LOAD_ENV && \\$TF apply \"$PLAN\" && rm -f \"$PLAN\"; exec bash"
    remote_tty "
      if tmux has-session -t $SESSION 2>/dev/null; then
        echo \"tmux session '$SESSION' exists: '$0 attach' to see it; exit its shell to close it.\"; exit 1
      fi
      [ -f \"$PLAN\" ] || { echo \"No saved plan: run '$0 plan' first.\"; exit 1; }
      tmux new -s $SESSION $(dq "$run")
    "
    ;;
  attach)
    remote_tty "tmux attach -t $SESSION"
    ;;
  e2e)
    remote_tty "cd \"$MOD\" && $LOAD_ENV && scripts/e2e-test.sh$(args "$@")"
    ;;
  shell)
    remote_tty "tmux new -A -s $SESSION-shell $(dq "cd \"$MOD\" && $LOAD_ENV && exec bash")"
    ;;
  ssh)
    exec ssh -t "$JUMP_HOST"
    ;;
  *)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
