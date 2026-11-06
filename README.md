# Aquenda · Operating Systems

Global Solution 2026.2 · FIAP · CitizenTech

Uma VM Linux que se provisiona sozinha por Shell Script. Ela sobe a **API C#** (catálogo, salas, vagas das casas) e a **FastAPI** (vagas de emprego, CNES, IBGE) como serviços systemd, monitora CPU, memória e disco e se recupera de falha. É o servidor de que o app Aquenda precisa para funcionar fora do notebook de alguém do grupo.

| Integrante | RM |
|---|---|
| Giovanne Charelli Zaniboni Silva | 556223 |
| Gustavo Oliveira de Moura | 555827 |
| Lynn Bueno Rosa | 551102 |

**Vídeo (até 7 min):** _link a adicionar_

Aplicações hospedadas: [GS-c--AQUENDA](https://github.com/Lynnbrosa/GS-c--AQUENDA) (API C#, porta 5000) e [GS-SOA-AQUENDA](https://github.com/Lynnbrosa/GS-SOA-AQUENDA) (FastAPI, porta 8000).

## Como provisionar

VM: **Ubuntu Server 24.04**, 2 vCPU, 4 GB de RAM, 20 GB de disco e duas placas de rede. No VirtualBox, a primeira placa fica em NAT (saída para a internet) e a segunda em host-only (`192.168.56.0/24`), que recebe o IP fixo.

```bash
git clone https://github.com/Lynnbrosa/GS-OS-AQUENDA.git
```

```bash
cd GS-OS-AQUENDA && sudo ./provisionar.sh
```

O `provisionar.sh` roda as três etapas em ordem. Cada uma também roda sozinha, e rodar de novo não estraga nada: cada passo confere o estado antes de mudar.

Se o grupo tiver as chaves da Adzuna, crie antes o arquivo `/etc/aquenda/segredos.env` (permissão 600) com `ADZUNA_APP_ID=` e `ADZUNA_APP_KEY=`. Sem ele, a FastAPI sobe com o cache e marca a Adzuna como "não configurada".

## O que cada script faz

| Critério | Pontos | Onde |
|---|---|---|
| Provisionamento de infra (rede, DNS, IP) | 2 | `scripts/01-infra.sh` |
| Provisionamento da aplicação | 2 | `scripts/02-app.sh` e `systemd/aquenda-api.service`, `aquenda-jobs.service` |
| Monitoramento com alertas de CPU, disco e memória | 2 | `scripts/03-monitor.sh` |
| Monitoramento como serviço tolerante a falhas | 1 | `systemd/aquenda-monitor.service` (`Restart=always`) e `aquenda-saude.timer` |
| Logs de auditoria e execução | 1 | `scripts/lib.sh` (todo passo vai para `/var/log/aquenda/audit.log`) e `auditd/aquenda.rules` |
| Funcionamento completo | 2 | fim do `02-app.sh`, `scripts/04-teste-falha.sh` e as evidências |

### 01-infra.sh

- **Hostname** `aquenda-srv`, com `hostnamectl`.
- **IP fixo** `192.168.56.10/24` na placa host-only, por netplan (`/etc/netplan/60-aquenda.yaml`). A placa NAT continua no DHCP.
- **/etc/hosts** com `aquenda-srv`, `api.aquenda.local` e `jobs.aquenda.local`, num bloco marcado que é trocado a cada execução, sem duplicar.
- **DNS** 1.1.1.1 e 8.8.8.8 pelo systemd-resolved, e a confirmação de que `github.com` resolve.
- **Fuso** America/Sao_Paulo e NTP ligado.
- **Firewall** ufw: nega toda entrada, menos 22 (SSH), 5000 (API C#) e 8000 (FastAPI).
- **Usuário de serviço** `aquenda`, sem shell de login. Pastas: `/opt/aquenda` (código), `/var/lib/aquenda` (dados), `/etc/aquenda` (segredos, 750) e `/var/log/aquenda` (logs).
- Os pacotes de base, incluindo `auditd`, `stress` e `sysstat`.

Tudo o que é da rede fica em `config/aquenda.conf`: hostname, interface, IP, DNS e portas.

### 02-app.sh

1. Instala o **.NET 8 SDK**, o **Python 3** e o **PostgreSQL**.
2. Cria o usuário e o banco `aquenda_soa` no PostgreSQL, que só aceita conexão local. A senha é gerada na primeira vez e reaproveitada nas seguintes.
3. **Clona os repositórios** em `/opt/aquenda/src`. Nas próximas execuções faz `fetch` e `reset` para a branch configurada.
4. **Cria os `.env`** em `/etc/aquenda/api.env` e `jobs.env`, com permissão `root:aquenda 640`. Vão neles a connection string, a `DATABASE_URL` do PostgreSQL, a chave de operador e a chave de cifra do chat. Os segredos são gerados ali e nunca entram no Git.
5. **Publica a API C#** com `dotnet publish -c Release` em `/opt/aquenda/api`. A versão anterior fica em `api.antigo` para voltar, se precisar.
6. Copia a FastAPI, cria o **venv**, instala as dependências e o driver `psycopg`, e **migra** com `alembic upgrade head`. A API C# migra o SQLite dela na subida, e o script confere a tabela `__EFMigrationsHistory`.
7. Instala as unidades systemd, liga as duas APIs e espera o `/health` de cada uma.
8. **Funcionamento completo:** `curl localhost:5000/api/servicos` e `curl localhost:8000/docs` precisam responder.

### 03-monitor.sh

| Modo | Quem chama | O que faz |
|---|---|---|
| sem argumento | quem provisiona | copia os scripts para `/opt/aquenda/scripts`, liga o monitor e os timers, configura o logrotate e o auditd |
| `--servico` | `aquenda-monitor.service` | a cada 15 s mede CPU (`/proc/stat`), memória (`/proc/meminfo`, MemAvailable) e disco (`df /`) |
| `--saude` | `aquenda-saude.timer`, a cada minuto | se o monitor, o PostgreSQL ou alguma API caiu, religa e registra; se a API não responde `/health`, alerta |
| `--uma-vez` | quem quiser olhar | uma medição na tela |

Limites: **80% de CPU, 85% de memória e 90% de disco**. Passou do limite, sai na hora uma linha `nivel=ALERTA` em `/var/log/aquenda/monitor.log` e no journal (`journalctl -t aquenda-monitor`). Quando o uso volta ao normal, sai `nivel=NORMALIZADO`. Com tudo bem, uma linha `nivel=OK` por minuto. O logrotate gira os logs todo dia e guarda 14.

```
2026-11-06T15:42:10-03:00 nivel=ALERTA recurso=cpu uso=100% limite=80%
2026-11-06T15:43:12-03:00 nivel=NORMALIZADO recurso=cpu uso=3% limite=80%
```

### Serviços systemd

| Unidade | O que é |
|---|---|
| `aquenda-api.service` | `dotnet /opt/aquenda/api/Aquenda.Api.dll` na porta 5000, `Restart=always`, `RestartSec=5` |
| `aquenda-jobs.service` | `uvicorn app.main:app` na porta 8000, depois do PostgreSQL, `Restart=always`, `RestartSec=5` |
| `aquenda-monitor.service` | o monitor, `Restart=always`, `RestartSec=5`, sem limite de tentativas |
| `aquenda-saude.timer` → `aquenda-saude.service` | a cada minuto, confere e religa o que caiu |
| `aquenda-jobs-sync.timer` → `aquenda-jobs-sync.service` | de hora em hora, sincroniza Adzuna, Gupy, IBGE e CNES |

As APIs rodam como o usuário `aquenda`, com `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome` e `PrivateTmp`. Elas só escrevem em `/var/lib/aquenda` e `/var/log/aquenda`.

### Auditoria

- **audit.log:** todo script grava em `/var/log/aquenda/audit.log` uma linha por passo, com data, usuário (o de verdade, mesmo com sudo), script, passo e resultado. Se um comando falha, o `trap ERR` registra a linha, o código de saída e o comando antes de parar.

  ```
  2026-11-06T15:30:02-03:00 usuario=lynn script=02-app.sh passo="Publicar a API C# (.NET 8)" resultado=ok publicada em /opt/aquenda/api (98M)
  ```

- **auditd:** vigia `/opt/aquenda` (escrita e mudança de permissão), `/etc/aquenda` (até leitura dos segredos), as unidades systemd e o banco. Para consultar, `sudo ausearch -k aquenda_segredos -i`.

## Teste de falha

```bash
sudo ./scripts/04-teste-falha.sh
```

| Teste | O que acontece |
|---|---|
| `kill -9` na API C# | o systemd sobe um processo novo em cerca de 5 s (`RestartSec=5`) e a API volta a responder |
| `stress --cpu` por 60 s | o monitor grava `nivel=ALERTA recurso=cpu` e, quando acaba, `NORMALIZADO` |
| `systemctl stop postgresql` | a FastAPI responde `503 {"title":"Banco indisponível"}` no `/health`, um erro claro, e a API C# segue no ar. Em até um minuto, o `aquenda-saude.timer` religa o PostgreSQL e o `/health` volta a 200 |

Os três também rodam separados: `04-teste-falha.sh kill`, `cpu` ou `banco`.

## Variáveis que vêm do grupo

| Variável | Para | Onde fica |
|---|---|---|
| `ConnectionStrings__Default` | API C# | `/etc/aquenda/api.env`, gerada: `Data Source=/var/lib/aquenda/aquenda.db` |
| `DATABASE_URL` | FastAPI | `/etc/aquenda/jobs.env`, gerada: PostgreSQL local com senha aleatória |
| `ADZUNA_APP_ID`, `ADZUNA_APP_KEY` | FastAPI | `/etc/aquenda/segredos.env`, que o grupo cria (opcional) |
| Links dos repositórios e branches | `02-app.sh` | `config/aquenda.conf` |

## Testar sem VM

Os scripts foram testados num container Ubuntu 24.04 com systemd como PID 1, que faz o papel da VM: serviços, timers e journal funcionam igual. Rede, hostname e auditd são do Docker, e os scripts avisam e pulam essas partes.

```bash
./teste/rodar-no-docker.sh
```

```bash
./teste/rodar-no-docker.sh --apagar
```

### Resultado (06/11/2026, Ubuntu 24.04 no container de teste)

| O quê | Resultado |
|---|---|
| `provisionar.sh` do zero | **1 min 37 s**, as 3 etapas sem erro. Rodando de novo, nada se duplica (`/etc/hosts`, banco, `.env`, clone) |
| Funcionamento | `curl localhost:5000/api/servicos` devolve os 10 serviços do catálogo; `curl localhost:8000/docs` dá HTTP 200 |
| `kill -9` na API C# | processo novo em **5,1 s**; API respondendo em **7,2 s** |
| `kill -9` no próprio monitor | o systemd sobe outro em 5 s (`NRestarts=1`) |
| `stress` de CPU | primeiro `ALERTA recurso=cpu uso=99%` em **5 s**, um alerta a cada 15 s enquanto durou e `NORMALIZADO` no fim |
| PostgreSQL parado | `/health` da FastAPI: `503 {"title":"Banco indisponível"}`. A API C# seguiu respondendo 200. O timer religou o banco em **34 s** |
| Auditoria | 67 linhas no `audit.log`, uma por passo de cada script, mais o religamento do banco feito pelo timer |

O container não tem kernel nem placa de rede próprios. Por isso o IP fixo (netplan), o `hostnamectl` e o auditd só rodam de verdade na VM. Neste teste, os scripts avisaram e seguiram, e as regras do auditd foram copiadas. Na gravação do vídeo, na VM, essas três partes aparecem funcionando.

## Evidências

Em `docs/evidencias/`:

| Arquivo | O que mostra |
|---|---|
| `01-provisionamento.txt` | o `provisionar.sh` do começo ao fim, com cada passo e as duas APIs respondendo |
| `02-teste-falha.txt` | os três testes de falha com os tempos |
| `03-audit.log` | o log de auditoria gerado |
| `04-monitor.log` | o log do monitor com o alerta de CPU |
| `05-servicos.txt` | `systemctl status` dos serviços e timers |

## Roteiro do vídeo (até 7 min)

1. **0:00** O que é: a VM que hospeda o Aquenda. O app depende das duas APIs no ar.
2. **0:30** `config/aquenda.conf` e os scripts. Rodar `sudo ./provisionar.sh` numa VM limpa e acelerar a gravação nos downloads.
3. **2:30** O resultado: `hostnamectl`, `ip -brief addr`, `sudo ufw status`, `systemctl list-units 'aquenda-*'`, `curl localhost:5000/api/servicos` e `curl localhost:8000/docs`.
4. **3:30** Teste 1: `sudo kill -9 $(pgrep -f Aquenda.Api)` e `watch systemctl status aquenda-api`, mostrando o PID novo em 5 s.
5. **4:30** Teste 2: `stress --cpu 4 --timeout 60` com `tail -f /var/log/aquenda/monitor.log` ao lado, mostrando o ALERTA e depois o NORMALIZADO.
6. **5:30** Teste 3: `sudo systemctl stop postgresql`, `curl localhost:8000/health` dando 503 com mensagem clara, e o timer religando o banco.
7. **6:30** A auditoria: `tail /var/log/aquenda/audit.log` e `sudo ausearch -k aquenda_segredos -i`.

## Estrutura

```
provisionar.sh          roda 01, 02 e 03 em ordem
config/aquenda.conf     hostname, IP, DNS, portas, repositórios e limites
scripts/
  lib.sh                configuração, log de auditoria, passos e trap de erro
  01-infra.sh           rede, DNS, IP, firewall, usuário e pastas
  02-app.sh             .NET, Python, PostgreSQL, clone, .env, publicação e migração
  03-monitor.sh         monitor, saúde, logrotate e auditd
  04-teste-falha.sh     os três testes de falha
systemd/                as unidades e os timers
auditd/aquenda.rules    o que o auditd vigia
teste/                  container Ubuntu com systemd para testar sem VM
docs/evidencias/        saídas do provisionamento e dos testes
```
