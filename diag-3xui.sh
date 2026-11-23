#!/usr/bin/env bash
# Read-only diagnostic for pro-config <-> 3x-ui API problems.
# Changes nothing. The token is never printed. Paste the output back.
#   bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/diag-3xui.sh)
set -u
strip() { sed -r 's/\x1b\[[0-9;]*m//g'; }
echo "== x-ui =="; command -v x-ui >/dev/null && echo "x-ui found" || echo "x-ui NOT found"
x-ui status 2>&1 | strip | head -5
echo "== settings =="; x-ui settings 2>&1 | strip | grep -Ei 'port|webBasePath|Access URL|SSL|version' | head -10
echo "== install-result.env (secrets hidden) =="
[ -f /etc/x-ui/install-result.env ] && sed -E 's/(TOKEN|PASS[A-Z]*)=.*/\1=<hidden>/' /etc/x-ui/install-result.env || echo "missing"
PORT=$(x-ui settings 2>/dev/null | strip | sed -n 's/.*port:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
BASE=$(x-ui settings 2>/dev/null | strip | sed -n 's/.*webBasePath:[[:space:]]*\(\S*\).*/\1/p' | head -1)
BASE="/${BASE#/}"; BASE="${BASE%/}"
[ -z "$PORT" ] && read -rp "Panel port: " PORT
echo "== listening on :$PORT =="; ss -ltnp 2>/dev/null | grep ":$PORT " || echo "nothing listening"
echo "== panel version/xray =="; ls /usr/local/x-ui/bin/ 2>/dev/null | head -3
read -rsp "Paste API token (hidden, Enter to skip): " TOKEN; echo
for S in https http; do
  U="$S://127.0.0.1:$PORT$BASE"
  echo "== $U =="
  echo -n "no auth, GET /: "; curl -sk -m8 -o /dev/null -w '%{http_code}\n' "$U/" || echo fail
  if [ -n "$TOKEN" ]; then
    for M in GET POST; do
      for P in /panel/api/inbounds/list /panel/api/clients/list /panel/api/hosts/list /panel/api/server/status; do
        printf '%-5s %-30s ' "$M" "$P"
        curl -sk -m10 -X "$M" -H "Authorization: Bearer $TOKEN" -w ' [HTTP %{http_code}]\n' "$U$P" \
          | cut -c1-110 | sed "s/$TOKEN/<token>/g"
      done
    done
  fi
done
echo "== done =="
