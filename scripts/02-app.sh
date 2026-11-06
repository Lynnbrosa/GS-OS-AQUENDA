#!/usr/bin/env bash
# 02-app.sh: instala e sobe o Aquenda na VM.
# .NET 8, Python 3 e PostgreSQL; clona a API C# e a FastAPI; cria os .env (segredos com permissão 600);
# publica a API C#, cria o venv da FastAPI, migra os bancos e liga os serviços systemd.
# Pode rodar de novo: atualiza o código (git pull), publica e reinicia.
#
#   sudo ./scripts/02-app.sh

source "$(dirname "$0")/lib.sh"
exigir_root

FONTES="$BASE/src"
DIR_API="$BASE/api"
DIR_JOBS="$BASE/jobs"
ENV_API="$SEGREDOS/api.env"
ENV_JOBS="$SEGREDOS/jobs.env"
SEGREDOS_GRUPO="$SEGREDOS/segredos.env"   # opcional, vem do grupo (Adzuna, chave de operador)

segredo() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
segredo_hex() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
como_app() { runuser -u "$USUARIO_APP" -- "$@"; }

passo "Pacotes da aplicação (.NET 8, Python 3, PostgreSQL)"
apt-get update -qq
instalar_pacotes dotnet-sdk-8.0 python3 python3-venv python3-pip postgresql postgresql-contrib
ok "$(dotnet --version | head -1) · $(python3 --version) · $(psql --version | awk '{print $1, $3}')"

passo "PostgreSQL"
systemctl enable --now postgresql >/dev/null
until runuser -u postgres -- pg_isready -q; do sleep 1; done
if [[ -f "$ENV_JOBS" ]] && grep -q '^DATABASE_URL=' "$ENV_JOBS"; then
  SENHA_BANCO="$(sed -n 's#^DATABASE_URL=postgresql+psycopg://[^:]*:\([^@]*\)@.*#\1#p' "$ENV_JOBS")"
  ok "senha do banco reaproveitada de $ENV_JOBS"
else
  SENHA_BANCO="$(segredo_hex)"
fi
runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$USUARIO_APP') THEN
    CREATE ROLE $USUARIO_APP LOGIN PASSWORD '$SENHA_BANCO';
  ELSE
    ALTER ROLE $USUARIO_APP PASSWORD '$SENHA_BANCO';
  END IF;
END \$\$;
SQL
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$BANCO_JOBS'" | grep -q 1; then
  runuser -u postgres -- createdb -O "$USUARIO_APP" "$BANCO_JOBS"
fi
ok "banco $BANCO_JOBS com dono $USUARIO_APP (só aceita conexão local)"

passo "Código-fonte"
install -d -o "$USUARIO_APP" -g "$USUARIO_APP" "$FONTES"
clonar() {
  local repo=$1 branch=$2 destino=$3
  if [[ -d "$destino/.git" ]]; then
    como_app git -C "$destino" fetch -q origin "$branch"
    como_app git -C "$destino" checkout -q "$branch"
    como_app git -C "$destino" reset -q --hard "origin/$branch"
  else
    como_app git clone -q --branch "$branch" --depth 1 "$repo" "$destino"
  fi
  echo "$(basename "$destino")@$(como_app git -C "$destino" rev-parse --short HEAD) ($branch)"
}
# a variável primeiro: falha dentro de $(...) passado direto como argumento não para o script
VERSAO_API="$(clonar "$REPO_API" "$BRANCH_API" "$FONTES/api")"; ok "$VERSAO_API"
VERSAO_JOBS="$(clonar "$REPO_JOBS" "$BRANCH_JOBS" "$FONTES/jobs")"; ok "$VERSAO_JOBS"

passo "Arquivos .env (segredos fora do repositório)"
[[ -f "$SEGREDOS_GRUPO" ]] && source "$SEGREDOS_GRUPO" && ok "segredos do grupo lidos de $SEGREDOS_GRUPO"
CHAVE_OPERADOR="${CHAVE_OPERADOR:-}"
if [[ -z "$CHAVE_OPERADOR" && -f "$ENV_API" ]]; then CHAVE_OPERADOR="$(sed -n 's/^Seguranca__ChaveOperador=//p' "$ENV_API")"; fi
CHAVE_OPERADOR="${CHAVE_OPERADOR:-$(segredo_hex)}"
CHAVE_CIFRA="$( [[ -f "$ENV_API" ]] && sed -n 's/^Chat__ChaveCifra=//p' "$ENV_API" || true)"
CHAVE_CIFRA="${CHAVE_CIFRA:-$(segredo)}"

umask 077
cat >"$ENV_API" <<EOF
# API C# do Aquenda. Gerado por 02-app.sh em $(agora). Não versionar.
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://0.0.0.0:$PORTA_API
ConnectionStrings__Default=Data Source=$DADOS/aquenda.db
Seguranca__ChaveOperador=$CHAVE_OPERADOR
Chat__ChaveCifra=$CHAVE_CIFRA
Swagger__Habilitado=true
EOF
cat >"$ENV_JOBS" <<EOF
# FastAPI do Aquenda. Gerado por 02-app.sh em $(agora). Não versionar.
DATABASE_URL=postgresql+psycopg://$USUARIO_APP:$SENHA_BANCO@localhost:5432/$BANCO_JOBS
AMBIENTE=producao
MIGRAR_AO_INICIAR=false
ADZUNA_APP_ID=${ADZUNA_APP_ID:-}
ADZUNA_APP_KEY=${ADZUNA_APP_KEY:-}
CHAVE_OPERADOR=$CHAVE_OPERADOR
EOF
umask 022
chown root:"$USUARIO_APP" "$ENV_API" "$ENV_JOBS"
chmod 640 "$ENV_API" "$ENV_JOBS"
[[ -n "${ADZUNA_APP_ID:-}" ]] || aviso "sem ADZUNA_APP_ID: a FastAPI sobe com o cache e marca a Adzuna como não configurada"
ok "$ENV_API e $ENV_JOBS (root:$USUARIO_APP, 640)"

passo "Publicar a API C# (.NET 8)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_HOME=/tmp/dotnet-home
dotnet publish "$FONTES/api/src/Aquenda.Api" -c Release -o "$DIR_API.novo" --nologo -v quiet -nodeReuse:false -p:UseSharedCompilation=false
# o build deixa servidores do MSBuild e do compilador vivos, com uns 300 MB de RAM: num servidor, desliga
dotnet build-server shutdown >/dev/null 2>&1 || true
rm -rf "$DIR_API.antigo"; [[ -d "$DIR_API" ]] && mv "$DIR_API" "$DIR_API.antigo"
mv "$DIR_API.novo" "$DIR_API"
chown -R "$USUARIO_APP":"$USUARIO_APP" "$DIR_API"
ok "publicada em $DIR_API ($(du -sh "$DIR_API" | cut -f1))"

passo "FastAPI: código, venv e dependências"
rsync -a --delete --exclude '.git' --exclude '.venv' --exclude '*.db*' --exclude '.env' "$FONTES/jobs/" "$DIR_JOBS/"
chown -R "$USUARIO_APP":"$USUARIO_APP" "$DIR_JOBS"
[[ -x "$DIR_JOBS/.venv/bin/python" ]] || como_app python3 -m venv "$DIR_JOBS/.venv"
como_app "$DIR_JOBS/.venv/bin/pip" install -q --upgrade pip
como_app "$DIR_JOBS/.venv/bin/pip" install -q -r "$DIR_JOBS/requirements.txt" "psycopg[binary]>=3.2"
ok "venv em $DIR_JOBS/.venv com o driver do PostgreSQL (psycopg)"

passo "Migrar o banco da FastAPI (alembic upgrade head)"
(cd "$DIR_JOBS" && set -a && source "$ENV_JOBS" && set +a && como_app env DATABASE_URL="$DATABASE_URL" "$DIR_JOBS/.venv/bin/alembic" upgrade head 2>&1 | tail -3)
ok "versão do schema: $(runuser -u postgres -- psql -d "$BANCO_JOBS" -tAc 'SELECT version_num FROM alembic_version')"

passo "Serviços systemd"
install -m 644 "$RAIZ_REPO"/systemd/aquenda-*.service "$RAIZ_REPO"/systemd/aquenda-*.timer /etc/systemd/system/
sed -i "s#/opt/aquenda/scripts#$BASE/scripts#g" /etc/systemd/system/aquenda-monitor*.service
systemctl daemon-reload
systemctl enable aquenda-api aquenda-jobs >/dev/null 2>&1
systemctl restart aquenda-api aquenda-jobs
ok "aquenda-api e aquenda-jobs ligados (Restart=always, sobem no boot)"

passo "A API C# migra o SQLite na subida; esperando as duas responderem"
esperar_url "http://localhost:$PORTA_API/health" 120 || { journalctl -u aquenda-api -n 30 --no-pager; false; }
ok "API C#: $(curl -fsS "http://localhost:$PORTA_API/health")"
esperar_url "http://localhost:$PORTA_JOBS/health" 60 || { journalctl -u aquenda-jobs -n 30 --no-pager; false; }
ok "FastAPI: $(curl -fsS "http://localhost:$PORTA_JOBS/health")"
ok "migrações da API C#: $(sqlite3 "$DADOS/aquenda.db" 'SELECT COUNT(*) FROM __EFMigrationsHistory') aplicadas"

passo "Funcionamento completo"
N_SERVICOS="$(curl -fsS "http://localhost:$PORTA_API/api/servicos" | jq '.total // (.itens | length)')"
ok "curl localhost:$PORTA_API/api/servicos -> $N_SERVICOS serviços no catálogo"
CODIGO_DOCS="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORTA_JOBS/docs")"
[[ "$CODIGO_DOCS" == 200 ]]
ok "curl localhost:$PORTA_JOBS/docs -> HTTP $CODIGO_DOCS (Swagger da FastAPI)"
