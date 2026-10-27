# Load .env without overriding what the shell already set (the shell wins over .env), and the
# helper that writes a setting back. Sourced by the scripts after `cd "$ROOT"`.
load_env() {
  [ -f .env ] || return 0
  local line key
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    [ -z "${!key+x}" ] || continue   # already set in the environment: keep it
    # shellcheck disable=SC2163
    eval "export $line"
  done < .env
}
set_env() {  # set_env KEY VALUE: persist a setting in .env (created if needed)
  touch .env
  [ ! -s .env ] || [ -z "$(tail -c1 .env)" ] || echo >> .env   # end the last line first
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
load_env
