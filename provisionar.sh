#!/usr/bin/env bash
# Provisiona a VM inteira do Aquenda: infra, aplicação e monitoramento, nessa ordem.
#
#   git clone https://github.com/Lynnbrosa/GS-OS-AQUENDA.git && cd GS-OS-AQUENDA
#   sudo ./provisionar.sh
#
# Cada etapa pode rodar sozinha (scripts/01-infra.sh, 02-app.sh, 03-monitor.sh) e de novo sem estragar nada.

set -Eeuo pipefail
cd "$(dirname "$0")"
chmod +x scripts/*.sh

inicio=$SECONDS
for etapa in 01-infra 02-app 03-monitor; do
  printf '\n\033[1;36m######## %s ########\033[0m\n' "$etapa"
  ./scripts/"$etapa".sh
done

source config/aquenda.conf
printf '\n\033[1;32mAquenda no ar em %d min %d s\033[0m\n' $(( (SECONDS - inicio) / 60 )) $(( (SECONDS - inicio) % 60 ))
systemctl --no-pager --plain list-units 'aquenda-*' postgresql.service | sed -n '1,12p'
echo
echo "  API C#:   curl http://localhost:$PORTA_API/api/servicos"
echo "  FastAPI:  curl http://localhost:$PORTA_JOBS/docs"
echo "  monitor:  tail -f $LOGS/monitor.log"
echo "  auditoria: tail $LOGS/audit.log"
echo "  falhas:   sudo ./scripts/04-teste-falha.sh"
