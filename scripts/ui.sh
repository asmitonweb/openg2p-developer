# Terminal output helpers, sourced by the other scripts. Colour and in-place updates only when
# stdout is a terminal (plain lines in CI and logs). OAN_PLAIN=1 forces plain output.
if [ -t 1 ] && [ -z "${OAN_PLAIN:-}" ] && [ "${TERM:-}" != dumb ]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_BLUE=$'\e[34m' C_GREEN=$'\e[32m' C_RED=$'\e[31m' C_YELLOW=$'\e[33m' C_OFF=$'\e[0m'
  UI_TTY=1
else
  C_BOLD='' C_DIM='' C_BLUE='' C_GREEN='' C_RED='' C_YELLOW='' C_OFF=''
  UI_TTY=''
fi
# Wall-clock start of the whole command, shared with child scripts (SECONDS restarts per process).
UI_T0=${UI_T0:-$EPOCHSECONDS}
export UI_T0

elapsed() {  # elapsed [start-epoch]  -> "1m23s"
  local s=$((EPOCHSECONDS - ${1:-$UI_T0}))
  if [ $s -ge 3600 ]; then printf '%dh%02dm' $((s/3600)) $((s%3600/60))
  elif [ $s -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%ds' $s; fi
}
step() {  # step "title"   a section banner with the running time of the whole command
  printf '\n%s==>%s %s%s%s %s(%s)%s\n' "$C_BLUE" "$C_OFF" "$C_BOLD" "$1" "$C_OFF" "$C_DIM" "$(elapsed)" "$C_OFF"
}
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
note() { printf '  %s·%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
fail() { printf '  %s✘%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
# progress "label" <elapsed>: one line rewritten in place on a terminal, printed once otherwise
progress() {
  if [ -n "$UI_TTY" ]; then printf '\r\e[K  %s…%s %s %s(%s)%s' "$C_YELLOW" "$C_OFF" "$1" "$C_DIM" "$2" "$C_OFF"
  elif [ "${3:-}" = first ]; then printf '  … %s\n' "$1"; fi
}
progress_end() { [ -n "$UI_TTY" ] && printf '\r\e[K'; return 0; }
