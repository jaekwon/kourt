#!/bin/sh
# Deploy r/guilds to a live chain.
#
# THE SOURCE IN THIS REPO IS NOT THE SOURCE THAT SHIPS, and that is the whole
# reason this file exists rather than a line in a README. r/guilds imports the
# court realm at gno.land/r/kourt/kourtv2, which is where it lives HERE; on
# gno.land it lives under the deployer's address namespace at
# gno.land/r/g1ecsuj.../kourt, because mainnet has no registered `kourt`
# namespace and a package deploys exactly once. So the import has to be rewritten
# for the target chain, and a rewrite done by hand at a prompt is a rewrite
# nobody can review or repeat.
#
# THE PACKAGE NAME DIFFERS TOO, and it is the trap. Locally the court realm is
# `package kourtv2` at .../kourtv2; on mainnet it is `package kourt` at
# .../kourt. gno rejects an import whose identifier does not match the package
# name unless one is given, so the rewrite keeps the `kourt` alias the source
# already carries and both chains are satisfied by the same line.
#
# DRY RUN IS THE DEFAULT. Without --broadcast this prints the rewritten source
# and the command, and signs nothing. A realm deploys ONCE and cannot be edited
# or removed afterwards.
#
#   scripts/deploy-guilds.sh --key hotkey                 # print, change nothing
#   scripts/deploy-guilds.sh --key hotkey --simulate      # ask the node the cost
#   scripts/deploy-guilds.sh --key hotkey --broadcast     # for real, once
#
# --namespace defaults to the court realm's, so the two sit together. Any address
# namespace works: nothing about the binding's trust comes from WHERE this realm
# lives. It comes from which court realm it imports and from kourtv2.IsCourtMod,
# and the site is told the path by --guild-realm.
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/r/guilds"

REMOTE="https://rpc.gno.land"
CHAINID="gnoland-1"
NAMESPACE="g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6"
COURT_PATH=""          # default: the same namespace, named `kourt`
KEY=""
MODE="print"
GAS_WANTED="50000000"
GAS_FEE="1000000ugnot"
DEPOSIT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)     REMOTE="$2"; shift 2 ;;
    --chainid)    CHAINID="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --court-path) COURT_PATH="$2"; shift 2 ;;
    --key)        KEY="$2"; shift 2 ;;
    --gas-wanted) GAS_WANTED="$2"; shift 2 ;;
    --gas-fee)    GAS_FEE="$2"; shift 2 ;;
    --deposit)    DEPOSIT="$2"; shift 2 ;;
    --simulate)   MODE="simulate"; shift ;;
    --broadcast)  MODE="broadcast"; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "deploy-guilds: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$COURT_PATH" ] || COURT_PATH="gno.land/r/$NAMESPACE/kourt"
PKGPATH="gno.land/r/$NAMESPACE/guilds"

# THE NODE IS ASKED WHETHER THE COURT REALM IS REALLY THERE, and whether it
# answers the one question this realm rests on. A deploy against a path that does
# not exist fails at AddPackage with a resolution error; a deploy against a realm
# that exists and has no IsCourtMod builds and then panics on the first Set,
# which is the expensive way to find out.
probe() {
  data=$(printf '%s' "$1" | base64 | tr -d '\n')
  curl -sf -X POST "$REMOTE" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"abci_query\",\"params\":{\"path\":\"vm/qeval\",\"data\":\"$data\"}}" \
    | python3 -c 'import sys,json,base64
j=json.load(sys.stdin); r=j.get("result",{}).get("response",{})
d=r.get("ResponseBase",{}).get("Data")
print(base64.b64decode(d).decode() if d else "")'
}
say=$(probe "$COURT_PATH.IsCourtMod(\"meta\",\"g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6\")" || true)
case "$say" in
  "(true bool)"|"(false bool)") : ;;
  *) echo "deploy-guilds: $COURT_PATH did not answer IsCourtMod on $REMOTE." >&2
     echo "  it said: ${say:-nothing}" >&2
     echo "  this realm is useless without it; check --court-path and --remote." >&2
     exit 1 ;;
esac

# The staged copy. Only the two paths move; nothing else about the source is
# allowed to differ from what the test suite ran against.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/guilds"
sed -e "s|kourt \"gno.land/r/kourt/kourtv2\"|kourt \"$COURT_PATH\"|" \
    "$SRC/guilds.gno" > "$STAGE/guilds/guilds.gno"
printf 'module = "%s"\ngno = "0.9"\n' "$PKGPATH" > "$STAGE/guilds/gnomod.toml"

if ! grep -q "$COURT_PATH" "$STAGE/guilds/guilds.gno"; then
  echo "deploy-guilds: the import rewrite matched nothing — the source moved." >&2
  exit 1
fi
if grep -q "gno.land/r/kourt/kourtv2" "$STAGE/guilds/guilds.gno"; then
  echo "deploy-guilds: the staged source still names this repo's court realm." >&2
  exit 1
fi

echo "path:   $PKGPATH"
echo "court:  $COURT_PATH  (answered IsCourtMod)"
echo "chain:  $CHAINID at $REMOTE"
echo

set -- gnokey maketx addpkg \
  --pkgdir "$STAGE/guilds" \
  --pkgpath "$PKGPATH" \
  --gas-fee "$GAS_FEE" \
  --gas-wanted "$GAS_WANTED"
[ -z "$DEPOSIT" ] || set -- "$@" --send "$DEPOSIT"
set -- "$@" --chainid "$CHAINID" --remote "$REMOTE"

case "$MODE" in
  print)
    echo "--- the source that would ship ---"
    cat "$STAGE/guilds/guilds.gno"
    echo "--- the command ---"
    echo "$@ ${KEY:-YOURKEY}"
    echo
    echo "Nothing was signed. --simulate asks the node what it costs;"
    echo "--broadcast deploys it, once and permanently."
    ;;
  simulate|broadcast)
    [ -n "$KEY" ] || { echo "deploy-guilds: --key is required to $MODE" >&2; exit 2; }
    if [ "$MODE" = simulate ]; then
      set -- "$@" --simulate only
    else
      set -- "$@" --broadcast
    fi
    "$@" "$KEY"
    ;;
esac
