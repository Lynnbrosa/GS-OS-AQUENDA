#!/usr/bin/env bash
# Funções comuns dos scripts do Aquenda: configuração, log de auditoria e passos.
# Todo script grava em /var/log/aquenda/audit.log uma linha por passo, com data, usuário, script e resultado.

set -Eeuo pipefail

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${AQUENDA_CONF:-$RAIZ_REPO/config/aquenda.conf}"
# shellcheck source=../config/aquenda.conf
source "$CONF"

AUDIT_LOG="$LOGS/audit.log"
SCRIPT_ATUAL="$(basename "${0}")"
USUARIO_REAL="${SUDO_USER:-$(id -un)}"
PASSO_ATUAL="inicio"

mkdir -p "$LOGS"
touch "$AUDIT_LOG"
chmod 640 "$AUDIT_LOG"

agora() { date --iso-8601=seconds; }

auditar() {
  # auditar <resultado> <mensagem>
  printf '%s usuario=%s script=%s passo="%s" resultado=%s %s\n' \
    "$(agora)" "$USUARIO_REAL" "$SCRIPT_ATUAL" "$PASSO_ATUAL" "$1" "$2" >>"$AUDIT_LOG"
}

passo() {
  PASSO_ATUAL="$1"
  printf '\n\033[1;33m==> %s\033[0m\n' "$1"
  auditar "inicio" ""
}

ok() {
  printf '    \033[32mok\033[0m %s\n' "$1"
  auditar "ok" "$1"
}

aviso() {
  printf '    \033[33maviso\033[0m %s\n' "$1"
  auditar "aviso" "$1"
}

falhou() {
  local codigo=$? linha=${BASH_LINENO[0]}
  printf '\n\033[31mFALHOU\033[0m no passo "%s" (linha %s, código %s)\n' "$PASSO_ATUAL" "$linha" "$codigo" >&2
  auditar "erro" "linha=$linha codigo=$codigo comando=\"${BASH_COMMAND//\"/\'}\""
  exit "$codigo"
}
trap falhou ERR

exigir_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Rode como root: sudo $0" >&2
    exit 1
  fi
}

# Container (teste no Docker) não tem kernel próprio: rede, hostname e auditd ficam com o host.
em_container() {
  systemd-detect-virt --container --quiet 2>/dev/null || [[ -f /.dockerenv ]]
}

instalar_pacotes() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

esperar_url() {
  # esperar_url <url> <segundos>: espera responder 2xx
  local url=$1 limite=${2:-60} inicio=$SECONDS
  until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
    if (( SECONDS - inicio >= limite )); then return 1; fi
    sleep 2
  done
}
