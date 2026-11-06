#!/usr/bin/env bash
# 01-infra.sh: prepara a VM para receber o Aquenda.
# Hostname, IP fixo, /etc/hosts, DNS, fuso e NTP, firewall (ufw), usuário de serviço e pastas.
# Pode rodar de novo: cada passo confere o estado antes de mudar.
#
#   sudo ./scripts/01-infra.sh

source "$(dirname "$0")/lib.sh"
exigir_root

IP_SEM_MASCARA="${IP_FIXO%/*}"

passo "Pacotes de base"
apt-get update -qq
instalar_pacotes ca-certificates curl git jq ufw auditd stress sysstat sqlite3 rsync iproute2 tzdata logrotate
ok "curl, git, jq, ufw, auditd, stress, sysstat, sqlite3, rsync"

passo "Hostname"
if [[ "$(hostname)" != "$HOSTNAME_VM" ]]; then
  if em_container; then
    echo "$HOSTNAME_VM" >/etc/hostname
    aviso "container: /etc/hostname gravado; o hostname de verdade é o do docker run --hostname"
  else
    hostnamectl set-hostname "$HOSTNAME_VM"
    ok "hostname agora é $HOSTNAME_VM"
  fi
else
  ok "já era $HOSTNAME_VM"
fi

passo "IP fixo ($IP_FIXO em $INTERFACE_FIXA)"
if em_container; then
  aviso "container: a rede é do Docker, IP fixo fica para a VM"
elif ! ip link show "$INTERFACE_FIXA" >/dev/null 2>&1; then
  aviso "interface $INTERFACE_FIXA não existe nesta VM; ajuste INTERFACE_FIXA em config/aquenda.conf"
elif ! command -v netplan >/dev/null; then
  aviso "sem netplan; configure o IP fixo manualmente"
else
  cat >/etc/netplan/60-aquenda.yaml <<EOF
# Gerado por 01-infra.sh (Aquenda). A placa NAT segue no DHCP para a saída à internet.
network:
  version: 2
  ethernets:
    $INTERFACE_FIXA:
      dhcp4: false
      addresses: [$IP_FIXO]
      nameservers:
        addresses: [$(echo "$DNS_SERVIDORES" | sed 's/ /, /g')]
EOF
  chmod 600 /etc/netplan/60-aquenda.yaml
  netplan apply
  ok "$(ip -4 -brief addr show "$INTERFACE_FIXA")"
fi

passo "/etc/hosts"
BLOCO_INI="# >>> aquenda"
BLOCO_FIM="# <<< aquenda"
# reescreve no lugar (cat >), sem trocar o arquivo: funciona também quando o /etc/hosts é montado (Docker)
NOVO_HOSTS="$(mktemp)"
sed "/$BLOCO_INI/,/$BLOCO_FIM/d" /etc/hosts >"$NOVO_HOSTS"
{
  echo "$BLOCO_INI"
  echo "$IP_SEM_MASCARA $HOSTNAME_VM $HOSTNAME_VM.$DOMINIO api.$DOMINIO jobs.$DOMINIO"
  echo "127.0.1.1 $HOSTNAME_VM"
  echo "$BLOCO_FIM"
} >>"$NOVO_HOSTS"
cat "$NOVO_HOSTS" >/etc/hosts
rm -f "$NOVO_HOSTS"
[[ "$(grep -c "$BLOCO_INI" /etc/hosts)" == 1 ]]
ok "$HOSTNAME_VM, api.$DOMINIO e jobs.$DOMINIO apontam para $IP_SEM_MASCARA"

passo "DNS ($DNS_SERVIDORES)"
if [[ -d /etc/systemd ]] && systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 && systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=%s\nFallbackDNS=9.9.9.9\n' "$DNS_SERVIDORES" >/etc/systemd/resolved.conf.d/aquenda.conf
  systemctl restart systemd-resolved
  ok "systemd-resolved com $DNS_SERVIDORES"
else
  aviso "sem systemd-resolved; resolv.conf atual: $(grep -m1 nameserver /etc/resolv.conf || echo nenhum)"
fi
getent hosts github.com >/dev/null && ok "resolve github.com" || aviso "não resolveu github.com"

passo "Fuso e hora"
ln -sf "/usr/share/zoneinfo/$FUSO" /etc/localtime
echo "$FUSO" >/etc/timezone
if ! em_container && command -v timedatectl >/dev/null; then timedatectl set-ntp true || true; fi
ok "$(date '+%Z %z')"

passo "Firewall (ufw)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for porta in $PORTAS_ABERTAS; do ufw allow "$porta/tcp" >/dev/null; done
if ufw --force enable >/dev/null 2>&1; then
  ok "ativo, entrada liberada só em: $PORTAS_ABERTAS"
else
  aviso "regras gravadas, mas o ufw não ativou aqui (container sem iptables próprio)"
fi

passo "Usuário de serviço e pastas"
if ! id "$USUARIO_APP" >/dev/null 2>&1; then
  useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin "$USUARIO_APP"
  ok "usuário $USUARIO_APP criado (sem login)"
else
  ok "usuário $USUARIO_APP já existia"
fi
install -d -m 755 -o "$USUARIO_APP" -g "$USUARIO_APP" "$BASE" "$DADOS"
install -d -m 750 -o root -g "$USUARIO_APP" "$SEGREDOS"
install -d -m 755 -o "$USUARIO_APP" -g "$USUARIO_APP" "$LOGS"
chown root:"$USUARIO_APP" "$AUDIT_LOG"
ok "$BASE, $DADOS, $SEGREDOS (750) e $LOGS"

passo "Fim da infra"
ok "infra pronta: $(hostname) · $(ip -4 -brief addr | awk '{print $1"="$3}' | tr '\n' ' ')"
