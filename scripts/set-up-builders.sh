#!/usr/bin/env bash
# Lets SSH reach the builders in $BUILDERS, a list in the Nix machines format,
# with the private key in $BUILDER_SSH_KEY. A builder's host key is the last
# field of its line, base64 encoded as Nix defines it.

set -euo pipefail

mkdir -p ~/.ssh
chmod 700 ~/.ssh
install -m 600 /dev/stdin ~/.ssh/builder <<< "$BUILDER_SSH_KEY"
printf 'IdentityFile ~/.ssh/builder\nIdentitiesOnly yes\nServerAliveInterval 30\n' > ~/.ssh/config

sed 's/#.*//' <<< "$BUILDERS" | while read -r uri _ _ _ _ _ _ key; do
  host=${uri#*://}
  host=${host%%\?*}
  host=${host#*@}
  if [[ $host == *:* ]]; then
    host="[${host%:*}]:${host##*:}"
  fi
  if [[ -n $key && $key != - ]]; then
    echo "$host $(base64 -d <<< "$key")" >> ~/.ssh/known_hosts
  fi
done
