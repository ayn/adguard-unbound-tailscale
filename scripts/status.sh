#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

if [ -f ./.env ]; then
  set -a
  . ./.env
  set +a
fi

sudo docker compose ps
printf "\nWeb UI headers:\n"
curl -I --max-time 5 "http://${AGH_IPV4}/"
printf "\nDNS lookup through AdGuard Home:\n"
dig @"${AGH_IPV4}" google.com
