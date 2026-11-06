#!/usr/bin/env bash
# 03-monitor.sh: monitoramento do Aquenda.
#
#   sudo ./scripts/03-monitor.sh            instala: copia os scripts para /opt/aquenda, liga o monitor (serviço
#                                           com Restart=always), o timer de saúde, o auditd e o logrotate
#   03-monitor.sh --servico                 o que o aquenda-monitor.service roda: mede a cada INTERVALO_MONITOR s
#   03-monitor.sh --uma-vez                 uma medição na tela
#   03-monitor.sh --saude                   o que o aquenda-saude.timer roda: confere e religa os serviços
#
# Limites (config/aquenda.conf): CPU 80%, memória 85%, disco 90%. Tudo vai para /var/log/aquenda/monitor.log;
# alertas também vão para o journal (logger -t aquenda-monitor).

source "$(dirname "$0")/lib.sh"

MONITOR_LOG="$LOGS/monitor.log"

registrar() {
  # registrar <nível> <texto>
  printf '%s nivel=%s %s\n' "$(agora)" "$1" "$2" >>"$MONITOR_LOG"
  if [[ "$1" != OK ]]; then logger -t aquenda-monitor -p "user.$([[ $1 == ALERTA ]] && echo warning || echo notice)" "$1 $2" || true; fi
}

uso_cpu() {
  # % de CPU ocupada em 1 s, a partir de /proc/stat (todas as CPUs)
  local a1 a2 a3 a4 a5 a6 a7 a8 b1 b2 b3 b4 b5 b6 b7 b8
  read -r _ a1 a2 a3 a4 a5 a6 a7 a8 _ </proc/stat
  sleep 1
  read -r _ b1 b2 b3 b4 b5 b6 b7 b8 _ </proc/stat
  local ocioso=$(( (b4 + b5) - (a4 + a5) ))
  local total=$(( (b1+b2+b3+b4+b5+b6+b7+b8) - (a1+a2+a3+a4+a5+a6+a7+a8) ))
  (( total > 0 )) && echo $(( 100 * (total - ocioso) / total )) || echo 0
}

uso_memoria() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {d=$2} END {printf "%d", 100 * (t - d) / t}' /proc/meminfo
}

uso_disco() {
  df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}'
}

declare -A EM_ALERTA=()

conferir() {
  # conferir <recurso> <uso> <limite>
  local recurso=$1 uso=$2 limite=$3
  if (( uso >= limite )); then
    registrar ALERTA "recurso=$recurso uso=${uso}% limite=${limite}%"
    EM_ALERTA[$recurso]=1
  elif [[ -n "${EM_ALERTA[$recurso]:-}" ]]; then
    registrar NORMALIZADO "recurso=$recurso uso=${uso}% limite=${limite}%"
    unset "EM_ALERTA[$recurso]"
  fi
}

RESUMO=""
medir() {
  # roda no shell atual (não em $(...)) para guardar quem está em alerta entre uma medição e outra
  local cpu mem disco
  cpu=$(uso_cpu); mem=$(uso_memoria); disco=$(uso_disco)
  conferir cpu "$cpu" "$LIMITE_CPU"
  conferir memoria "$mem" "$LIMITE_MEMORIA"
  conferir disco "$disco" "$LIMITE_DISCO"
  RESUMO="cpu=${cpu}% memoria=${mem}% disco=${disco}% carga=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
}

modo_servico() {
  PASSO_ATUAL="monitor"
  auditar "inicio" "monitor ligado (intervalo ${INTERVALO_MONITOR}s, limites cpu=${LIMITE_CPU}% mem=${LIMITE_MEMORIA}% disco=${LIMITE_DISCO}%)"
  trap 'auditar "fim" "monitor parado (sinal)"; exit 0' TERM INT
  registrar INICIO "monitor ligado pid=$$ limites cpu=${LIMITE_CPU}% memoria=${LIMITE_MEMORIA}% disco=${LIMITE_DISCO}%"
  local ciclo=0
  while true; do
    medir
    # uma linha de "tudo certo" por minuto; alerta sai na hora, a cada medição
    if (( ciclo % (60 / INTERVALO_MONITOR) == 0 )); then registrar OK "$RESUMO"; fi
    ciclo=$((ciclo + 1))
    sleep $(( INTERVALO_MONITOR > 1 ? INTERVALO_MONITOR - 1 : 1 ))
  done
}

modo_saude() {
  PASSO_ATUAL="saude"
  local servico porta codigo
  if ! systemctl is-active --quiet aquenda-monitor; then
    systemctl restart aquenda-monitor
    registrar ALERTA "servico=aquenda-monitor estado=parado acao=religado"
    auditar "religado" "aquenda-monitor estava parado"
  fi
  if ! systemctl is-active --quiet postgresql; then
    registrar ALERTA "servico=postgresql estado=parado acao=religado"
    auditar "religado" "postgresql estava parado"
    systemctl start postgresql
  fi
  for par in "aquenda-api:$PORTA_API" "aquenda-jobs:$PORTA_JOBS"; do
    servico=${par%%:*}; porta=${par##*:}
    if ! systemctl is-active --quiet "$servico"; then
      systemctl restart "$servico"
      registrar ALERTA "servico=$servico estado=parado acao=religado"
      auditar "religado" "$servico estava parado"
      continue
    fi
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$porta/health" || true)
    if [[ "$codigo" != 200 ]]; then
      registrar ALERTA "servico=$servico health=http_$codigo"
    fi
  done
}

modo_instalar() {
  exigir_root

  passo "Scripts e configuração em $BASE"
  install -d "$BASE/scripts" "$BASE/config"
  install -m 755 "$RAIZ_REPO"/scripts/*.sh "$BASE/scripts/"
  install -m 644 "$RAIZ_REPO/config/aquenda.conf" "$BASE/config/aquenda.conf"
  touch "$MONITOR_LOG"; chmod 640 "$MONITOR_LOG"
  ok "$BASE/scripts e $BASE/config"

  passo "Serviço do monitor e timers"
  install -m 644 "$RAIZ_REPO"/systemd/aquenda-*.service "$RAIZ_REPO"/systemd/aquenda-*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable aquenda-monitor >/dev/null 2>&1
  systemctl restart aquenda-monitor   # restart e não start: pega a versão nova do script ao reprovisionar
  systemctl enable --now aquenda-saude.timer aquenda-jobs-sync.timer >/dev/null 2>&1
  sleep 3
  systemctl is-active --quiet aquenda-monitor
  ok "aquenda-monitor ativo (Restart=always), aquenda-saude.timer a cada minuto, sync da FastAPI de hora em hora"

  passo "Rotação de logs"
  cat >/etc/logrotate.d/aquenda <<EOF
$LOGS/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
  ok "logs de $LOGS giram todo dia e ficam 14 dias"

  passo "auditd vigiando $BASE e $SEGREDOS"
  install -m 640 "$RAIZ_REPO/auditd/aquenda.rules" /etc/audit/rules.d/aquenda.rules
  if em_container; then
    aviso "container: o auditd precisa do kernel da VM; regras copiadas para /etc/audit/rules.d/aquenda.rules"
  else
    systemctl enable --now auditd >/dev/null 2>&1
    augenrules --load >/dev/null
    ok "$(auditctl -l | grep -c aquenda) regras ativas (ausearch -k aquenda_app para consultar)"
  fi

  passo "Primeira medição"
  medir
  ok "$RESUMO"
}

case "${1:-}" in
  --servico) modo_servico ;;
  --uma-vez) medir; echo "$RESUMO" ;;
  --saude) modo_saude ;;
  ""|--instalar) modo_instalar ;;
  *) echo "uso: $0 [--instalar | --servico | --uma-vez | --saude]" >&2; exit 2 ;;
esac
