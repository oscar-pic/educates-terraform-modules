# Environment for working on a jump host as a guest. Source it, do not run it:
#
#   . scripts/guest-env.sh <work dir>
#
# scripts/jump-host.sh sources it before every command it runs on the jump host.
#
# Everything stays inside <work dir>: nothing is written to the jump host user's home.
# - HOME=<work dir>/home. kubectl, helm, the OpenTofu providers and the Educates CLI
#   keep their caches and settings under $HOME, and some providers ignore every other
#   setting (the kubectl provider hardcodes $HOME/.kube/http-cache).
# - The host user's own kubeconfig, talosconfig and OpenTofu CLI configuration are not
#   read. If you need a CLI configuration (for example provider mirrors), put it in
#   <work dir>/home/.tofurc, or set TF_CLI_CONFIG_FILE in proxmox.env.
# - <work dir>/bin goes first in PATH, for tools kept there (such as the educates CLI).
# - Secrets from every <work dir>/*.env file, in alphabetical order (proxmox.env, and for
#   example a ceph.env). A later file can map names without copying secrets:
#   TF_VAR_ceph_csi_rbd_user_key="$CEPH_RBD_KEY". KUBECONFIG and TALOSCONFIG from <work dir>/state.

_guest_dir="${1:?usage: . guest-env.sh <work dir>}"

if [ "$HOME" != "$_guest_dir/home" ]; then
  mkdir -p "$_guest_dir/home"
  chmod 700 "$_guest_dir/home"
  export HOME="$_guest_dir/home"
fi
export PATH="$_guest_dir/bin:$PATH"

set -a
for _guest_f in "$_guest_dir"/*.env; do
  # shellcheck disable=SC1090
  [ -f "$_guest_f" ] && . "$_guest_f"
done
set +a

for _guest_f in "$_guest_dir"/state/kubeconfig-*.yaml; do
  [ -f "$_guest_f" ] && export KUBECONFIG="$_guest_f"
done
for _guest_f in "$_guest_dir"/state/talosconfig-*; do
  [ -f "$_guest_f" ] && export TALOSCONFIG="$_guest_f"
done
unset _guest_dir _guest_f
