#!/usr/bin/env bash
set -euo pipefail

# The reviewed runner profile supplies these exact bootstrap tool pins.
: "${ATLAS_DOCKER_CLI_SHA256:?Reviewed Docker CLI SHA256 required}"
: "${ATLAS_DOCKER_SERVER_VERSION:?Reviewed Docker daemon version required}"
: "${ATLAS_SHA256SUM_SHA256:?Reviewed sha256sum tool SHA256 required}"
: "${ATLAS_TIMEOUT_SHA256:?Reviewed timeout tool SHA256 required}"
: "${ATLAS_SOURCE_PINS_SHA256:?Reviewed executable source-manifest SHA256 required}"
: "${ATLAS_TERMINAL_READER_SHA256:?Reviewed terminal reader SHA256 required}"
: "${GITHUB_RUN_ID:?Exact CI run identity required}"
: "${GITHUB_RUN_ATTEMPT:?Exact CI attempt required}"

[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]]
source_root="$(cd -- "$(dirname -- "$0")" && pwd -P)"
docker_cli="$(command -v docker)"
[[ "$docker_cli" = /* && -f "$docker_cli" ]]
printf '%s  %s\n' "$ATLAS_SHA256SUM_SHA256" /usr/bin/sha256sum | /usr/bin/sha256sum --check --strict
printf '%s  %s\n' "$ATLAS_TIMEOUT_SHA256" /usr/bin/timeout | /usr/bin/sha256sum --check --strict
printf '%s  %s\n' "$ATLAS_DOCKER_CLI_SHA256" "$docker_cli" | /usr/bin/sha256sum --check --strict
printf '%s  %s\n' "$ATLAS_SOURCE_PINS_SHA256" "$source_root/SOURCE_PINS.json" | /usr/bin/sha256sum --check --strict
printf '%s  %s\n' "$ATLAS_TERMINAL_READER_SHA256" "$source_root/verify_terminal.py" | /usr/bin/sha256sum --check --strict
[[ "$("$docker_cli" version --format '{{.Server.Version}}')" == "$ATLAS_DOCKER_SERVER_VERSION" ]]
# The pinned x86_64 Linux profile uses4096-byte pages; inner readers verify it.

image='python:3.12.10-slim@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db'
evidence="$source_root/ci-evidence-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -- "$evidence"
chmod 0777 -- "$evidence"
"$docker_cli" version > "$evidence/docker-version.txt"
"$docker_cli" pull "$image"
"$docker_cli" image inspect "$image" > "$evidence/image-inspect.json"
containers=()
cleanup() {
  local status=$?
  for identity in "${containers[@]}"; do
    "$docker_cli" inspect "$identity" > "$evidence/${identity}.cleanup-before.json" || status=1
    "$docker_cli" rm --force "$identity" > "$evidence/${identity}.cleanup.txt" || status=1
    "$docker_cli" ps --all --no-trunc --filter "id=$identity" --format '{{.ID}}' \
      > "$evidence/${identity}.cleanup-after.txt" || status=1
    [[ ! -s "$evidence/${identity}.cleanup-after.txt" ]] || status=1
  done
  exit "$status"
}
trap cleanup EXIT

for selected in ordinary optimized oom uncapped; do
  profile=(--memory 536866816 --memory-swap 536866816)
  mode=controls
  strict=536870912
  optimization=()
  [[ "$selected" != optimized ]] || optimization=(-O)
  if [[ "$selected" == oom ]]; then
    profile=(--memory 67104768 --memory-swap 67104768)
    mode=oom-probe
    strict=67108864
  elif [[ "$selected" == uncapped ]]; then
    profile=()
    mode=uncapped-probe
  fi
  identity="$("$docker_cli" create --name "atlas-install-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${selected}" \
    --network none --cpus 1 --pids-limit 64 --cgroupns private --read-only \
    --cap-drop ALL --security-opt no-new-privileges --user 501:501 \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=384m,mode=1777 \
    --mount "type=bind,src=$source_root,dst=/source,readonly" \
    --mount "type=bind,src=$evidence,dst=/evidence" \
    "${profile[@]}" "$image" python3 -I -S -B "${optimization[@]}" /source/run_controls.py \
    --pins-sha256 "$ATLAS_SOURCE_PINS_SHA256" --mode "$mode" \
    --strict-memory-bytes "$strict" --output "/evidence/${selected}.json")"
  [[ "$identity" =~ ^[0-9a-f]{64}$ ]]
  containers+=("$identity")
  status=0
  /usr/bin/timeout --foreground --kill-after=10s 90s "$docker_cli" start --attach "$identity" \
    > "$evidence/${selected}.stdout.txt" 2> "$evidence/${selected}.stderr.txt" || status=$?
  printf '%s\n' "$status" > "$evidence/${selected}.client-exit.txt"
  "$docker_cli" inspect "$identity" > "$evidence/${selected}.inspect.json"
  expected=0
  [[ "$selected" != oom ]] || expected=137
  [[ "$selected" != uncapped ]] || expected=2
  [[ "$status" == "$expected" ]]
  [[ "$("$docker_cli" inspect --format '{{.State.Status}}' "$identity")" == exited ]]
  # Actual kernel and inner results determine acceptance below.
done

identity="$("$docker_cli" create --name "atlas-install-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-terminal-reader" \
  --network none --cpus 1 --memory 67104768 --memory-swap 67104768 \
  --pids-limit 64 --read-only --cap-drop ALL --security-opt no-new-privileges --user 501:501 \
  --mount "type=bind,src=$source_root,dst=/source,readonly" \
  --mount "type=bind,src=$evidence,dst=/evidence" \
  "$image" python3 -I -S -B /source/verify_terminal.py \
  --evidence /evidence --pins-sha256 "$ATLAS_SOURCE_PINS_SHA256")"
[[ "$identity" =~ ^[0-9a-f]{64}$ ]]
containers+=("$identity")
status=0
/usr/bin/timeout --foreground --kill-after=10s 30s "$docker_cli" start --attach "$identity" \
  > "$evidence/terminal-reader.stdout.txt" 2> "$evidence/terminal-reader.stderr.txt" || status=$?
"$docker_cli" inspect "$identity" > "$evidence/terminal-reader.inspect.json"
[[ "$status" == 0 ]]
[[ "$("$docker_cli" inspect --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$identity")" == 'exited 0 false' ]]
