#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

if [ -f ./.env ]; then
  set -a
  . ./.env
  set +a
fi

UNBOUND_IMAGE="${UNBOUND_IMAGE:-klutchell/unbound:latest}"

mkdir -p ./unbound/var

curl -fsSL https://www.internic.net/domain/named.root -o ./unbound/var/root.hints
docker run --rm \
  -v "$(pwd)/unbound/var:/var/unbound" \
  --entrypoint unbound-anchor \
  "${UNBOUND_IMAGE}" \
  -a /var/unbound/root.key

printf "Initialized Unbound state in %s/unbound/var\n" "$(pwd)"
