#!/usr/bin/env bash
# Preflight checks for educates-on-proxmox.
#
# Run it on the machine you deploy from (workstation or jump host), from any directory:
#
#   set -a; . proxmox.env; set +a                  # TF_VAR_proxmox_api_token, TF_VAR_proxmox_csi_token_secret
#   scripts/preflight.sh --var-file my-cluster.tfvars    # before the first apply
#   scripts/preflight.sh --var-file my-cluster.tfvars --after   # after the apply: can this machine operate the cluster?
#
# It reads the values from your tfvars file through `tofu console` (run `tofu init` first), and
# checks what can be checked from this machine. It changes nothing: Proxmox API calls are GETs.
# Things only the cluster or the Proxmox hosts can check are listed at the end, to confirm by hand.
#
# Exit code: 0 if no check failed, 1 otherwise. Warnings do not fail.

set -u

usage() {
  echo "Usage: $0 --var-file <file.tfvars> [--after] [--client-configs-dir <dir>]" >&2
  exit 2
}

VAR_FILE=""
MODE="before"
CLIENT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --var-file) VAR_FILE="${2:-}"; shift 2 ;;
    --var-file=*) VAR_FILE="${1#*=}"; shift ;;
    --after) MODE="after"; shift ;;
    --client-configs-dir) CLIENT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$VAR_FILE" ] || usage
case "$VAR_FILE" in /*) ;; *) VAR_FILE="$PWD/$VAR_FILE" ;; esac
[ -f "$VAR_FILE" ] || { echo "No such file: $VAR_FILE" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_VARS="$ROOT_DIR/../../infrastructure/proxmox-for-educates/variables.tf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
WARNS=0
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
pass() { echo "  ${G}PASS${N} $*"; }
warn() { echo "  ${Y}WARN${N} $*"; WARNS=$((WARNS + 1)); }
fail() { echo "  ${R}FAIL${N} $*"; FAILS=$((FAILS + 1)); }
info() { echo "  ${B}INFO${N} $*"; }
section() { echo; echo "${B}== $*${N}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# version_ge 1.10.2 1.6  -> true
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

OS="$(uname -s)"

###############################################################################
section "Tools on this machine"
###############################################################################

for t in curl jq; do
  if have "$t"; then pass "$t"; else fail "$t is required by this script"; fi
done
[ "$FAILS" -eq 0 ] || { echo; echo "Install the missing tools and run again."; exit 1; }

TF=""
if have tofu; then TF=tofu; elif have terraform; then TF=terraform; fi
if [ -z "$TF" ]; then
  fail "OpenTofu (tofu) or Terraform not found"
  exit 1
fi
tf_version="$($TF version -json 2>/dev/null | jq -r '.terraform_version // empty')"
if [ -n "$tf_version" ] && version_ge "$tf_version" "1.6.0"; then
  pass "$TF $tf_version"
else
  fail "$TF ${tf_version:-unknown version}: 1.6 or later is needed"
fi

###############################################################################
# Read the configuration through `tofu console`.
###############################################################################

EXPR='jsonencode({
  endpoint = var.proxmox_endpoint, insecure = var.proxmox_insecure, cluster_name = var.cluster_name,
  proxmox = var.proxmox, talos = var.talos, network = var.network, storage_network = var.storage_network,
  nodes = var.nodes, load_balancer = var.load_balancer, storage = var.storage, gateway_api = var.gateway_api,
  client_configs_dir = var.client_configs_dir
})'
if ! (cd "$ROOT_DIR" && printf '%s\n' "$EXPR" | TF_VAR_proxmox_api_token="${TF_VAR_proxmox_api_token:-unset}" \
  $TF console -var-file="$VAR_FILE" >"$TMP/console.out" 2>"$TMP/console.err"); then
  section "Configuration"
  fail "could not read $VAR_FILE with '$TF console'. Did you run '$TF init' in $ROOT_DIR?"
  sed 's/^/       /' "$TMP/console.err" | head -n 20
  exit 1
fi
CFG="$(jq -r '.' <"$TMP/console.out")"
cfg() { printf '%s' "$CFG" | jq -r "$@"; }

ENDPOINT="$(cfg '.endpoint | sub("/+$"; "")')"
INSECURE="$(cfg '.insecure // false')"
CK=""; [ "$INSECURE" = "true" ] && CK="-k"

TALOS_DEFAULT="$(sed -n 's/.*version *= *optional(string, "\(v[0-9.]*\)").*/\1/p' "$MODULE_VARS" 2>/dev/null | head -n1)"
K8S_DEFAULT="$(sed -n 's/.*kubernetes_version *= *optional(string, "\([0-9.]*\)").*/\1/p' "$MODULE_VARS" 2>/dev/null | head -n1)"
TALOS_VERSION="$(cfg --arg d "$TALOS_DEFAULT" '.talos.version // $d')"
K8S_VERSION="$(cfg --arg d "$K8S_DEFAULT" '.talos.kubernetes_version // $d')"
minor() { echo "$1" | sed 's/^v//' | cut -d. -f2; }

###############################################################################
# Tools that operate the cluster (not needed by OpenTofu itself).
###############################################################################

if have talosctl; then
  tc="$(talosctl version --client 2>/dev/null | sed -n 's/.*Tag: *\(v[0-9.]*\).*/\1/p' | head -n1)"
  if [ -n "$TALOS_VERSION" ] && [ "$(minor "$tc")" = "$(minor "$TALOS_VERSION")" ]; then
    pass "talosctl $tc (Talos $TALOS_VERSION)"
  else
    warn "talosctl ${tc:-unknown}: use the same minor version as Talos ($TALOS_VERSION)"
  fi
else
  warn "talosctl not found: needed for health checks, Talos upgrades and diagnostics"
fi

if have kubectl; then
  kc="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.minor // empty' | tr -dc '0-9')"
  km="$(minor "$K8S_VERSION")"
  if [ -n "$kc" ] && [ -n "$km" ] && [ $((kc - km)) -le 1 ] && [ $((km - kc)) -le 1 ]; then
    pass "kubectl 1.$kc (Kubernetes $K8S_VERSION)"
  else
    warn "kubectl 1.${kc:-?}: use a version within one minor of Kubernetes $K8S_VERSION"
  fi
else
  warn "kubectl not found: needed to use the cluster and to install Educates"
fi

if have educates; then pass "educates CLI"; else info "educates CLI not found: needed later to install Educates (or use helm + kubectl)"; fi
if have helm; then pass "helm"; else info "helm not found: only needed for the Helm-based Educates installation"; fi
if have tmux || have screen; then pass "tmux/screen (keeps the apply running if the SSH session drops)"; else info "tmux or screen not found: recommended on a jump host"; fi

###############################################################################
# Network helpers.
###############################################################################

route_info() {
  # Prints "<interface> <gateway>" used to reach $1.
  if [ "$OS" = "Darwin" ]; then
    route -n get "$1" 2>/dev/null | awk '/interface:/{i=$2} /gateway:/{g=$2} END{print i, (g?g:"on-link")}'
  else
    ip route get "$1" 2>/dev/null | awk '{for(n=1;n<=NF;n++){if($n=="dev")i=$(n+1); if($n=="via")g=$(n+1)}} END{print i, (g?g:"on-link")}'
  fi
}

pings() {
  if [ "$OS" = "Darwin" ]; then ping -c1 -t2 "$1" >/dev/null 2>&1; else ping -c1 -W2 "$1" >/dev/null 2>&1; fi
}

tcp_open() {
  # tcp_open <host> <port>
  if have nc; then
    nc -z -w 4 "$1" "$2" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1 &
    local pid=$!; sleep 4; if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; return 1; fi
    wait "$pid"
  fi
}

https_code() {
  curl -sS -o /dev/null -w "%{http_code}" --max-time 10 ${2:-} "$1" 2>/dev/null
}

NODE_KEYS="$(cfg '.nodes | keys[]')"
node_ip() { cfg --arg k "$1" '.nodes[$k].ip'; }
API_VIP="$(cfg '.network.api_vip // empty')"
# The first control-plane key in alphabetical order: the node the module bootstraps (and its API endpoint without a VIP).
FIRST_CP="$(cfg '[.nodes | to_entries[] | select(.value.role == "controlplane")] | sort_by(.key) | first | .value.ip // empty')"
API_HOST="${API_VIP:-$FIRST_CP}"

###############################################################################
if [ "$MODE" = "after" ]; then
###############################################################################

  section "Reaching the cluster from this machine (after the apply)"
  set -- $(route_info "$API_HOST"); info "node network reached through interface ${1:-?} (gateway ${2:-?})"

  for k in $NODE_KEYS; do
    ip="$(node_ip "$k")"
    if tcp_open "$ip" 50000; then pass "$k ($ip): Talos API, TCP 50000"; else fail "$k ($ip): Talos API, TCP 50000 not reachable"; fi
  done

  code="$(https_code "https://$API_HOST:6443/version" -k)"
  case "$code" in
    200|401|403) pass "Kubernetes API https://$API_HOST:6443 (HTTP $code)" ;;
    *) fail "Kubernetes API https://$API_HOST:6443 not reachable (HTTP ${code:-none})" ;;
  esac

  DIR="${CLIENT_DIR:-$(cfg '.client_configs_dir // empty')}"; DIR="${DIR:-$ROOT_DIR}"
  CN="$(cfg '.cluster_name')"
  if have talosctl && [ -f "$DIR/talosconfig-$CN" ]; then
    if TALOSCONFIG="$DIR/talosconfig-$CN" talosctl -n "$FIRST_CP" health --wait-timeout 2m >"$TMP/health" 2>&1; then
      pass "talosctl health"
    else
      fail "talosctl health (last lines below)"; tail -n 5 "$TMP/health" | sed 's/^/       /'
    fi
  else
    info "talosconfig-$CN not found in $DIR (or no talosctl): skipped talosctl health"
  fi
  if have kubectl && [ -f "$DIR/kubeconfig-$CN.yaml" ]; then
    if KUBECONFIG="$DIR/kubeconfig-$CN.yaml" kubectl get nodes >"$TMP/nodes" 2>&1; then
      pass "kubectl get nodes"; sed 's/^/       /' "$TMP/nodes"
    else
      fail "kubectl get nodes"; tail -n 3 "$TMP/nodes" | sed 's/^/       /'
    fi
  fi

  echo
  echo "Failures: $FAILS, warnings: $WARNS."
  [ "$FAILS" -eq 0 ] && echo "This machine can operate the cluster." || echo "This machine cannot operate the cluster directly: use a jump host, or fix the routes/firewall above."
  [ "$FAILS" -eq 0 ]; exit $?
fi

###############################################################################
section "Proxmox API ($ENDPOINT)"
###############################################################################

TOKEN="${TF_VAR_proxmox_api_token:-}"
if [ -z "$TOKEN" ]; then
  fail "TF_VAR_proxmox_api_token is not set (load your secrets file first)"
fi

# api <token> <path> -> body in $TMP/api.json, returns 0 on HTTP 200
api() {
  local code
  code="$(curl -sS $CK --max-time 15 -o "$TMP/api.json" -w '%{http_code}' \
    -H "Authorization: PVEAPIToken=$1" "$ENDPOINT/api2/json$2" 2>"$TMP/api.err")"
  API_CODE="$code"
  [ "$code" = "200" ]
}

PVE_OK=false
if [ -n "$TOKEN" ]; then
  if api "$TOKEN" /version; then
    PVE_OK=true
    v="$(jq -r '.data.version' "$TMP/api.json")"
    if version_ge "$v" "8.4"; then pass "reachable, authenticated, Proxmox VE $v"; else fail "Proxmox VE $v: 8.4 or later is needed"; fi
  elif [ "$API_CODE" = "401" ]; then
    fail "reachable, but the token was rejected (HTTP 401): check TF_VAR_proxmox_api_token"
  elif [ "$API_CODE" = "000" ]; then
    fail "not reachable: $(head -n1 "$TMP/api.err")"
    [ "$INSECURE" = "true" ] || info "if the certificate is self-signed, set proxmox_insecure = true"
  else
    fail "unexpected answer (HTTP $API_CODE)"
  fi
fi

# has_privs <token> <path> <priv>... : checks the token's effective privileges on <path>.
MISSING=""
has_privs() {
  local tok="$1" path="$2"; shift 2
  local q; q="$(jq -rn --arg p "$path" '$p|@uri')"
  MISSING=""
  api "$tok" "/access/permissions?path=$q" || { MISSING="(could not read permissions, HTTP $API_CODE)"; return 1; }
  local p
  for p in "$@"; do
    [ "$(jq -r --arg path "$path" --arg p "$p" '.data[$path][$p] // 0' "$TMP/api.json")" = "1" ] || MISSING="$MISSING $p"
  done
  [ -z "$MISSING" ]
}

check_privs() {
  # check_privs <token> <label> <path> <priv>...
  local tok="$1" label="$2" path="$3"; shift 3
  if has_privs "$tok" "$path" "$@"; then pass "$label: $path"; else fail "$label: $path, missing:$MISSING"; fi
}

# pool_get <pool>: 0 if the pool exists (its entry in $TMP/pool.json); sets API_CODE.
# Uses GET /pools?poolid=: the older GET /pools/{poolid} does not support nested pools.
pool_get() {
  local q; q="$(jq -rn --arg p "$1" '$p|@uri')"
  api "$TOKEN" "/pools?poolid=$q" || return 1
  if ! jq -e '.data | length > 0' "$TMP/api.json" >/dev/null; then
    # The list hides pools the token cannot audit: only "missing" if it could have seen it.
    if has_privs "$TOKEN" "/pool/$1" Pool.Audit; then API_CODE=404; else API_CODE=403; fi
    return 1
  fi
  jq '.data[0]' "$TMP/api.json" > "$TMP/pool.json"
}

# check_vm_privs <token> <label> <priv>...: Proxmox accepts VM privileges on the pool
# (/pool/<pool>, when proxmox.pool is set) or on each VM (/vms/<id>).
check_vm_privs() {
  local tok="$1" label="$2"; shift 2
  local pool; pool="$(cfg '.proxmox.pool // empty')"
  if [ -n "$pool" ] && has_privs "$tok" "/pool/$pool" "$@"; then
    pass "$label: /pool/$pool"
    return
  fi
  local k id
  for k in $NODE_KEYS; do
    id="$(cfg --arg k "$k" '.nodes[$k].vm_id // empty')"
    if [ -z "$id" ]; then
      fail "$label $k: no vm_id, so privileges are needed on /pool/<pool> or /vms"
      continue
    fi
    check_privs "$tok" "$label $k" "/vms/$id" "$@"
  done
}

if $PVE_OK; then
  section "Proxmox placement"

  api "$TOKEN" /nodes && jq -r '.data[].node' "$TMP/api.json" | sort >"$TMP/pve-nodes"
  PVE_NODES="$(cfg '[.nodes[].proxmox_node] | unique | .[]')"
  for n in $PVE_NODES; do
    if grep -qx "$n" "$TMP/pve-nodes" 2>/dev/null; then pass "Proxmox node $n exists"; else fail "Proxmox node $n not found (or not visible to the token)"; fi
  done

  VM_DS="$(cfg '.proxmox.vm_datastore // "local-lvm"')"
  IMG_DS="$(cfg '.proxmox.image_datastore // "local"')"
  IMG_SHARED="$(cfg '.proxmox.image_datastore_shared // false')"
  for n in $PVE_NODES; do
    if api "$TOKEN" "/nodes/$n/storage/$VM_DS/status"; then
      jq -r '.data.content' "$TMP/api.json" | tr ',' '\n' | grep -qx images \
        && pass "$n: VM datastore $VM_DS allows disk images" || fail "$n: VM datastore $VM_DS does not allow the 'images' content type"
    else
      fail "$n: VM datastore $VM_DS not found or not visible (HTTP $API_CODE)"
    fi
    if api "$TOKEN" "/nodes/$n/storage/$IMG_DS/status"; then
      jq -r '.data.content' "$TMP/api.json" | tr ',' '\n' | grep -qx import \
        && pass "$n: image datastore $IMG_DS allows 'import'" || fail "$n: image datastore $IMG_DS does not allow the 'import' content type"
    else
      fail "$n: image datastore $IMG_DS not found or not visible (HTTP $API_CODE)"
    fi
  done

  for k in $NODE_KEYS; do
    id="$(cfg --arg k "$k" '.nodes[$k].vm_id // empty')"
    [ -n "$id" ] || { info "$k: no vm_id, Proxmox will pick one"; continue; }
    if api "$TOKEN" "/cluster/nextid?vmid=$id"; then pass "$k: VM ID $id is free"; else warn "$k: VM ID $id is in use (expected only if this cluster already exists)"; fi
  done

  POOL="$(cfg '.proxmox.pool // empty')"
  CREATE_POOL="$(cfg '.proxmox.create_pool // false')"
  if [ -n "$POOL" ] && [ "$CREATE_POOL" != "true" ]; then
    # Existing pool, kept by whoever runs Proxmox: it must exist; its parents are not our business.
    if pool_get "$POOL"; then
      pass "pool $POOL exists: the VMs go into it (never created or deleted by the module)"
    elif [ "$API_CODE" = "403" ]; then
      fail "pool $POOL: no Pool.Audit on it, so it cannot be checked or used"
    else
      fail "pool $POOL does not exist: ask for it, or set create_pool = true to let the module create it"
    fi
  elif [ -n "$POOL" ]; then
    # create_pool: the module owns the last level. It must not exist yet, unless this cluster
    # created it (the module's comment names the cluster). Every level above must exist.
    CN="$(cfg '.cluster_name')"
    if pool_get "$POOL"; then
      if jq -e --arg c "Talos Kubernetes cluster '$CN'" '.comment // "" | contains($c)' "$TMP/pool.json" >/dev/null; then
        pass "pool $POOL exists and belongs to this cluster"
      else
        fail "pool $POOL already exists and is not this cluster's: use it without create_pool, or choose another name"
      fi
    elif [ "$API_CODE" = "403" ]; then
      warn "cannot tell whether pool $POOL exists (no Pool.Audit on it)"
    else
      pass "pool $POOL does not exist yet: the module creates it (create_pool)"
    fi
    PARENT=""
    REST="$POOL"
    while [ "${REST#*/}" != "$REST" ]; do
      PARENT="${PARENT:+$PARENT/}${REST%%/*}"
      REST="${REST#*/}"
      if pool_get "$PARENT"; then
        pass "parent pool $PARENT exists"
      elif [ "$API_CODE" = "403" ]; then
        warn "cannot tell whether parent pool $PARENT exists (no Pool.Audit on it)"
      else
        fail "parent pool $PARENT does not exist: create it first (the module only creates the last level)"
      fi
    done
  fi

  # ceph-csi 3.18 and later need x86-64-v3 (AVX2) CPUs.
  if [ "$(cfg '.storage.ceph_csi.enabled // false')" = "true" ]; then
    CEPH_DEFAULT="$(sed -n '/variable "ceph_csi"/,/^}/s/.*version *= *optional(string, "\([0-9.]*\)").*/\1/p' "$MODULE_VARS" 2>/dev/null | head -n1)"
    CEPH_V="$(cfg --arg d "${CEPH_DEFAULT:-3.17.2}" '.storage.ceph_csi.version // $d')"
    CPU_T="$(cfg '.proxmox.cpu_type // "x86-64-v2-AES"')"
    if version_ge "$CEPH_V" "3.18.0"; then
      case "$CPU_T" in
        x86-64-v3*|x86-64-v4*) pass "ceph-csi $CEPH_V with cpu_type $CPU_T (x86-64-v3 needed)" ;;
        host|max)
          NO_AVX2=""
          for n in $PVE_NODES; do
            if api "$TOKEN" "/nodes/$n/status"; then
              jq -r '.data.cpuinfo.flags // ""' "$TMP/api.json" | tr ' ' '\n' | grep -qx avx2 || NO_AVX2="$NO_AVX2 $n"
            fi
          done
          [ -z "$NO_AVX2" ] && pass "ceph-csi $CEPH_V with cpu_type $CPU_T" \
            || fail "ceph-csi $CEPH_V needs x86-64-v3 (AVX2), missing on:$NO_AVX2. Use ceph_csi.version 3.17.x" ;;
        *) fail "ceph-csi $CEPH_V needs x86-64-v3 CPUs (AVX2), but cpu_type is $CPU_T: set ceph_csi.version = \"3.17.2\" (or a v3 cpu_type if the hosts support it)" ;;
      esac
    else
      pass "ceph-csi $CEPH_V (runs on x86-64-v2)"
    fi
  fi

  section "Token permissions (OpenTofu)"

  VM_PRIVS="VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt"
  if [ -n "$POOL" ]; then
    # Pool.Allocate creates the pool and adds VMs to it; Pool.Audit reads it (also on refresh).
    check_privs "$TOKEN" "pool" "/pool/$POOL" Pool.Allocate Pool.Audit
  fi
  check_vm_privs "$TOKEN" "VMs" $VM_PRIVS
  # Proxmox checks tags on VM creation against /vms/<id> only, not against the pool.
  # (jq: "false // true" is true, so test default_tags explicitly)
  if [ "$(cfg '(.proxmox.default_tags != false) or ((.proxmox.tags // []) | length > 0)')" = "true" ]; then
    for k in $NODE_KEYS; do
      id="$(cfg --arg k "$k" '.nodes[$k].vm_id // empty')"
      [ -n "$id" ] || continue
      has_privs "$TOKEN" "/vms/$id" VM.Config.Options \
        || fail "VM $k: tags need VM.Config.Options on /vms/$id (Proxmox ignores the pool for tags): set proxmox.default_tags = false and proxmox.tags = [], or grant it"
    done
  fi
  check_privs "$TOKEN" "VM datastore" "/storage/$VM_DS" Datastore.AllocateSpace Datastore.Audit
  check_privs "$TOKEN" "image datastore" "/storage/$IMG_DS" Datastore.AllocateTemplate Datastore.AllocateSpace Datastore.Audit
  # Deleting the image (Talos upgrade, destroy) needs Datastore.Allocate; creating it does not.
  if has_privs "$TOKEN" "/storage/$IMG_DS" Datastore.Allocate; then
    pass "image datastore: can delete the image on upgrade or destroy"
  else
    warn "image datastore /storage/$IMG_DS: no Datastore.Allocate, so Talos upgrades and destroy cannot delete the old image (see requirements.md)"
  fi

  if [ "$IMG_SHARED" = "true" ]; then
    DL_NODES="$(cfg '.proxmox.image_download_node // empty')"
    [ -n "$DL_NODES" ] || DL_NODES="$(echo "$PVE_NODES" | head -n1)"
  else
    DL_NODES="$PVE_NODES"
  fi
  for n in $DL_NODES; do
    if has_privs "$TOKEN" "/nodes/$n" Sys.AccessNetwork || has_privs "$TOKEN" "/" Sys.Audit Sys.Modify; then
      pass "image download: /nodes/$n"
    else
      fail "image download: /nodes/$n, missing: Sys.AccessNetwork"
    fi
  done

  # SDN.Use on every bridge: plain bridges live in the 'localnetwork' zone.
  check_bridge() {
    local bridge="$1" vlan="$2" zone="localnetwork" path
    if api "$TOKEN" "/cluster/sdn/vnets/$bridge"; then
      zone="$(jq -r '.data.zone // "localnetwork"' "$TMP/api.json")"
    fi
    path="/sdn/zones/$zone/$bridge"; [ -n "$vlan" ] && path="$path/$vlan"
    check_privs "$TOKEN" "bridge $bridge" "$path" SDN.Use
    if [ "$zone" != "localnetwork" ] && [ -z "$3" ]; then
      warn "bridge $bridge is an SDN VNet (zone $zone): VXLAN and EVPN zones can have an MTU below 1500 (1450 by default); set mtu = 1 so the VMs inherit the VNet MTU, whatever it is"
    fi
  }
  check_bridge "$(cfg '.network.bridge // "vmbr0"')" "$(cfg '.network.vlan_id // empty')" "$(cfg '.network.mtu // empty')"
  SN_BRIDGE="$(cfg '.storage_network.bridge // empty')"
  [ -n "$SN_BRIDGE" ] && check_bridge "$SN_BRIDGE" "$(cfg '.storage_network.vlan_id // empty')" "$(cfg '.storage_network.mtu // 9000')"

  if [ "$(cfg '.proxmox.ha_enabled // false')" = "true" ]; then
    check_privs "$TOKEN" "Proxmox HA" "/" Sys.Audit Sys.Console
  fi

  if [ "$(cfg '.storage.proxmox_csi.enabled // false')" = "true" ]; then
    section "Token permissions (Proxmox CSI)"
    CSI_ID="$(cfg '.storage.proxmox_csi.token_id // empty')"
    CSI_SECRET="${TF_VAR_proxmox_csi_token_secret:-}"
    if [ -z "$CSI_ID" ] || [ -z "$CSI_SECRET" ]; then
      fail "storage.proxmox_csi.token_id or TF_VAR_proxmox_csi_token_secret is not set"
    elif ! api "$CSI_ID=$CSI_SECRET" /version; then
      fail "the CSI token was rejected (HTTP $API_CODE)"
    else
      pass "CSI token authenticates"
      check_vm_privs "$CSI_ID=$CSI_SECRET" "CSI, VMs" VM.Audit VM.Config.Disk
      for ds in $(cfg '[.storage.proxmox_csi.storage_classes[]?.datastore] | unique | .[]'); do
        check_privs "$CSI_ID=$CSI_SECRET" "CSI, volume datastore" "/storage/$ds" Datastore.Allocate Datastore.AllocateSpace Datastore.Audit
      done
    fi
  fi
fi

###############################################################################
section "Network from this machine"
###############################################################################

set -- $(route_info "$API_HOST")
IFACE="${1:-?}"
info "node network ($API_HOST) reached through interface $IFACE (gateway ${2:-?})"
case "$IFACE" in
  utun*|tun*|tap*|wg*|ppp*) warn "the node network is reached through a VPN ($IFACE): it must route the whole node subnet and allow TCP 50000 and 6443; if in doubt, deploy from a jump host" ;;
esac

for k in $NODE_KEYS; do
  ip="$(node_ip "$k")"
  if pings "$ip"; then warn "$k: $ip answers ping. Fine if this cluster already exists; otherwise the IP is in use"; else pass "$k: $ip does not answer (free, or ping is filtered)"; fi
done
if [ -n "$API_VIP" ]; then
  if pings "$API_VIP"; then warn "API VIP $API_VIP answers ping. Fine if this cluster already exists; otherwise the IP is in use"; else pass "API VIP $API_VIP does not answer (free, or ping is filtered)"; fi
fi

section "Internet (or mirrors) from this machine"

check_url() {
  local code; code="$(https_code "$1")"
  if [ -n "$code" ] && [ "$code" != "000" ]; then pass "$1 (HTTP $code)"; else fail "$1 not reachable: $2"; fi
}
if [ "$TF" = "tofu" ]; then check_url https://registry.opentofu.org/.well-known/terraform.json "providers (tofu init)";
else check_url https://registry.terraform.io/.well-known/terraform.json "providers (terraform init)"; fi
check_url https://github.com "provider and tool downloads"
check_url https://factory.talos.dev "Talos Image Factory (schematic)"
check_url https://helm.cilium.io/index.yaml "Cilium chart"
[ "$(cfg '.storage.proxmox_csi.enabled // false')" = "true" ] && check_url https://ghcr.io/v2/ "Proxmox CSI chart"
[ "$(cfg '.storage.ceph_csi.enabled // false')" = "true" ] && check_url https://ceph.github.io/csi-charts/index.yaml "Ceph CSI charts"
[ "$(cfg '.storage.nfs_csi.enabled // false')" = "true" ] && check_url https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts/index.yaml "NFS CSI chart"

###############################################################################
section "Confirm by hand (cannot be checked from here)"
###############################################################################

echo "  - The Proxmox hosts reach https://factory.talos.dev (they download the Talos image themselves)."
echo "  - The node network reaches DNS, NTP and the container registries (ghcr.io, registry.k8s.io, quay.io, docker.io, factory.talos.dev)."
[ "$(cfg '.gateway_api.enabled // false')" = "true" ] && echo "  - The node network reaches https://github.com (Gateway API CRDs at bootstrap)."
[ "$(cfg '.storage.proxmox_csi.enabled // false')" = "true" ] && echo "  - The node network reaches the Proxmox API on TCP 8006, and the replies are routed back (Proxmox CSI)."
echo "  - The LoadBalancer range and the API VIP are free and in the same layer-2 network as the nodes."
echo "  - After the apply, run '$0 --var-file <file> --after' to check that this machine reaches the Talos and Kubernetes APIs."

echo
echo "Failures: $FAILS, warnings: $WARNS."
[ "$FAILS" -eq 0 ]
