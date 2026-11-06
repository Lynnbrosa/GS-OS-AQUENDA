#!/usr/bin/env bash
# 04-teste-falha.sh: os três testes de falha da entrega, com o tempo de cada recuperação.
#
#   sudo ./scripts/04-teste-falha.sh            os três
#   sudo ./scripts/04-teste-falha.sh kill       só o kill -9 da API C#
#   sudo ./scripts/04-teste-falha.sh cpu        só o stress de CPU
#   sudo ./scripts/04-teste-falha.sh banco      só o PostgreSQL parado
#
# O resultado vai para a tela e para /var/log/aquenda/teste-falha.log.

source "$(dirname "$0")/lib.sh"
exigir_root

RELATORIO="$LOGS/teste-falha.log"
MONITOR_LOG="$LOGS/monitor.log"
registrar() { echo "$1" | tee -a "$RELATORIO"; }

teste_kill() {
  passo "Teste 1: kill -9 na API C#, o systemd sobe de novo"
  local antes depois inicio
  antes=$(systemctl show -p MainPID --value aquenda-api)
  [[ "$antes" != 0 ]]
  registrar "$(agora) teste=kill servico=aquenda-api pid_antes=$antes"
  kill -9 "$antes"
  inicio=$(date +%s.%N)
  until depois=$(systemctl show -p MainPID --value aquenda-api) && [[ "$depois" != 0 && "$depois" != "$antes" ]]; do sleep 0.2; done
  local subiu
  subiu=$(echo "$(date +%s.%N) - $inicio" | bc)
  esperar_url "http://localhost:$PORTA_API/health" 90
  local respondeu
  respondeu=$(echo "$(date +%s.%N) - $inicio" | bc)
  registrar "$(agora) teste=kill pid_depois=$depois processo_novo_em=$(printf '%.1f' "$subiu")s respondendo_em=$(printf '%.1f' "$respondeu")s reinicios=$(systemctl show -p NRestarts --value aquenda-api)"
  ok "pid $antes morto; systemd subiu o pid $depois em $(printf '%.1f' "$subiu") s (RestartSec=5) e a API respondeu em $(printf '%.1f' "$respondeu") s"
}

teste_cpu() {
  passo "Teste 2: stress --cpu 4 --timeout 60, o monitor alerta"
  local marca linhas
  marca=$(wc -l <"$MONITOR_LOG")
  registrar "$(agora) teste=cpu comando=\"stress --cpu 4 --timeout 60\" limite=${LIMITE_CPU}%"
  stress --cpu "$(nproc)" --timeout 60 >/dev/null 2>&1 &
  local pid=$!
  local inicio=$SECONDS achou=""
  while (( SECONDS - inicio < 70 )); do
    if tail -n +"$((marca + 1))" "$MONITOR_LOG" | grep -q 'nivel=ALERTA recurso=cpu'; then achou=$((SECONDS - inicio)); break; fi
    sleep 1
  done
  wait "$pid" || true
  [[ -n "$achou" ]] || { aviso "nenhum alerta de CPU em 70 s"; return 1; }
  sleep $((INTERVALO_MONITOR + 2))
  linhas=$(tail -n +"$((marca + 1))" "$MONITOR_LOG" | grep -E 'recurso=cpu' | sed -n '1p;$p')
  registrar "$(agora) teste=cpu primeiro_alerta_em=${achou}s"
  registrar "$linhas"
  ok "alerta de CPU em ${achou} s; quando o stress acaba, o monitor registra NORMALIZADO"
}

teste_banco() {
  passo "Teste 3: PostgreSQL parado, a FastAPI responde um erro claro"
  registrar "$(agora) teste=banco acao=\"systemctl stop postgresql\""
  systemctl stop postgresql
  sleep 2
  local codigo corpo
  corpo=$(curl -s -w '\n%{http_code}' "http://localhost:$PORTA_JOBS/health")
  codigo=$(tail -1 <<<"$corpo"); corpo=$(head -1 <<<"$corpo")
  registrar "$(agora) teste=banco health_http=$codigo corpo=$corpo"
  [[ "$codigo" == 503 ]]
  ok "GET /health -> HTTP $codigo: $corpo"
  local api
  api=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORTA_API/health")
  ok "a API C# (SQLite) segue no ar: HTTP $api"
  echo "    esperando o aquenda-saude.timer religar o PostgreSQL (até 75 s)..."
  local inicio=$SECONDS
  until systemctl is-active --quiet postgresql; do
    (( SECONDS - inicio > 75 )) && { aviso "o timer não religou; religando na mão"; systemctl start postgresql; break; }
    sleep 1
  done
  esperar_url "http://localhost:$PORTA_JOBS/health" 30
  registrar "$(agora) teste=banco religado_em=$((SECONDS - inicio))s health_http=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORTA_JOBS/health")"
  ok "PostgreSQL de volta em $((SECONDS - inicio)) s pelo timer de saúde; /health voltou a 200"
}

command -v bc >/dev/null || instalar_pacotes bc
echo "== $(agora) $(hostname) ==" >>"$RELATORIO"
case "${1:-todos}" in
  kill) teste_kill ;;
  cpu) teste_cpu ;;
  banco) teste_banco ;;
  todos) teste_kill; teste_cpu; teste_banco ;;
  *) echo "uso: $0 [kill|cpu|banco]" >&2; exit 2 ;;
esac
passo "Fim dos testes de falha"
ok "relatório em $RELATORIO"
