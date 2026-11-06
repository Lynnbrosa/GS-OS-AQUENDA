#!/usr/bin/env bash
# Sobe um "servidor" Ubuntu 24.04 com systemd no Docker, provisiona com os scripts do repositório
# e roda os testes de falha. As evidências saem em docs/evidencias/.
#
#   ./teste/rodar-no-docker.sh            provisiona e testa
#   ./teste/rodar-no-docker.sh --apagar   remove o container e a imagem

set -euo pipefail
cd "$(dirname "$0")/.."
NOME=aquenda-srv
IMAGEM=aquenda-vm-teste

if [[ "${1:-}" == "--apagar" ]]; then
  docker rm -f "$NOME" >/dev/null 2>&1 || true
  docker rmi -f "$IMAGEM" >/dev/null 2>&1 || true
  echo "container e imagem removidos"
  exit 0
fi

docker build -q -t "$IMAGEM" teste/ >/dev/null
docker rm -f "$NOME" >/dev/null 2>&1 || true
docker run -d --name "$NOME" --hostname "$NOME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -p 15000:5000 -p 18000:8000 "$IMAGEM" >/dev/null
until docker exec "$NOME" systemctl is-system-running --wait >/dev/null 2>&1 || \
      [[ "$(docker exec "$NOME" systemctl is-system-running 2>/dev/null)" == degraded ]]; do sleep 1; done

# copia o repositório como se fosse o git clone na VM
docker exec "$NOME" mkdir -p /root/GS-OS-AQUENDA
tar --exclude=.git --exclude=docs -cf - . | docker exec -i "$NOME" tar -xf - -C /root/GS-OS-AQUENDA

mkdir -p docs/evidencias
docker exec "$NOME" bash -c 'cd /root/GS-OS-AQUENDA && ./provisionar.sh' 2>&1 | tee docs/evidencias/01-provisionamento.txt
docker exec "$NOME" bash -c 'cd /root/GS-OS-AQUENDA && ./scripts/04-teste-falha.sh' 2>&1 | tee docs/evidencias/02-teste-falha.txt

# o que ficou no servidor depois dos testes
docker exec "$NOME" cat /var/log/aquenda/audit.log >docs/evidencias/03-audit.log
docker exec "$NOME" cat /var/log/aquenda/monitor.log >docs/evidencias/04-monitor.log
docker exec "$NOME" bash -c '
echo "\$ systemctl list-units \"aquenda-*\" postgresql.service"; systemctl --no-pager list-units "aquenda-*" postgresql.service | head -8
echo; echo "\$ systemctl list-timers \"aquenda-*\""; systemctl --no-pager list-timers "aquenda-*" | head -4
echo; echo "\$ systemctl show aquenda-api -p Restart -p RestartUSec -p NRestarts -p User"; systemctl show aquenda-api -p Restart -p RestartUSec -p NRestarts -p User
echo; echo "# tolerância a falha do próprio monitor"; P=$(systemctl show -p MainPID --value aquenda-monitor); echo "\$ kill -9 $P   # pid do aquenda-monitor"; kill -9 "$P"; sleep 7
echo "pid agora: $(systemctl show -p MainPID --value aquenda-monitor), estado: $(systemctl is-active aquenda-monitor), reinícios: $(systemctl show -p NRestarts --value aquenda-monitor)"
echo; echo "\$ ufw status verbose"; ufw status verbose
echo; echo "\$ ls -l /etc/aquenda"; ls -l /etc/aquenda
echo; echo "\$ sed -n \"/>>> aquenda/,/<<< aquenda/p\" /etc/hosts"; sed -n "/>>> aquenda/,/<<< aquenda/p" /etc/hosts
echo; echo "\$ journalctl -t aquenda-monitor"; journalctl -t aquenda-monitor --no-pager | tail -10
echo; echo "\$ curl -s localhost:5000/api/servicos | jq \".total, .itens[0].nome\""; curl -s localhost:5000/api/servicos | jq ".total, .itens[0].nome"
echo; echo "\$ curl -s -o /dev/null -w \"%{http_code}\" localhost:8000/docs"; curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/docs
' >docs/evidencias/05-servicos.txt 2>&1
# tira as cores do terminal dos .txt
sed -i 's/\x1b\[[0-9;]*m//g' docs/evidencias/*.txt
echo "evidências em docs/evidencias/"
