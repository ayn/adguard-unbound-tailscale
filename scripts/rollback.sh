#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

sudo docker compose down
printf "\nStopped and removed the AdGuard Home test container and macvlan network.\n"
printf "Persistent files remain in %s for inspection. Remove them with:\n" "$(pwd)"
printf "  sudo rm -rf %s\n" "$(pwd)"
