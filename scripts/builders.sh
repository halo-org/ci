# Functions for the remote builders in $BUILDERS, a list in the Nix machines
# format. Source this file.

# Lets SSH reach the builders with the private key in $BUILDER_SSH_KEY. The
# last field of a builder's line is its host key, base64 encoded.
set_up_builders() {
  if [[ -z ${BUILDERS:-} ]]; then
    return
  fi
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  install -m 600 /dev/stdin ~/.ssh/builder <<< "$BUILDER_SSH_KEY"
  printf 'IdentityFile ~/.ssh/builder\nIdentitiesOnly yes\nServerAliveInterval 30\n' > ~/.ssh/config

  local uri key host
  while read -r uri _ _ _ _ _ _ key; do
    host=${uri#*://}
    host=${host%%\?*}
    host=${host#*@}
    if [[ $host == *:* ]]; then
      host="[${host%:*}]:${host##*:}"
    fi
    if [[ -n $key && $key != - ]]; then
      echo "$host $(base64 -d <<< "$key")" >> ~/.ssh/known_hosts
    fi
  done < <(sed 's/#.*//' <<< "$BUILDERS")
}

# Prints the store URI of the first builder for a system, or nothing.
builder_for() {
  local uri systems
  while read -r uri systems _; do
    if [[ ,$systems, == *,$1,* ]]; then
      echo "$uri"
      return
    fi
  done < <(sed 's/#.*//' <<< "${BUILDERS:-}")
}
