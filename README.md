# Aquenda · Operating Systems

Global Solution 2026.2 · FIAP · CitizenTech

Uma VM Linux que se provisiona sozinha por Shell Script. Ela sobe a **API C#** (catálogo, salas, vagas das casas) e a **FastAPI** (vagas de emprego, CNES, IBGE) como serviços systemd, monitora CPU, memória e disco e se recupera de falha. É o servidor de que o app Aquenda precisa para funcionar fora do notebook de alguém do grupo.

| Integrante | RM |
|---|---|
| Giovanne Charelli Zaniboni Silva | 556223 |
| Gustavo Oliveira de Moura | 555827 |
| Lynn Bueno Rosa | 551102 |

**Vídeo (até 7 min):** https://youtu.be/vnnUgTd3iUU

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

- **auditd:** vigia `/opt/aquenda` (escrita e mudança de permissão), `/etc/aquenda` (até leitura dos segredos), as unidades systemd e o banco. Para consultar, `sudo ausearch -k aquenda_segredos --format text` e `sudo aureport -k --summary`. Num script ou por SSH sem terminal, acrescente `--input-logs`: sem ele, o `ausearch` lê a entrada padrão em vez do log.

## Teste de falha

```bash
sudo ./scripts/04-teste-falha.sh
```

| Teste | O que acontece |
|---|---|
| `kill -9` na API C# | o systemd sobe um processo novo em cerca de 5 s (`RestartSec=5`) e a API volta a responder |
| `stress` em todas as CPUs por 90 s | o monitor grava `nivel=ALERTA recurso=cpu` e, quando acaba, `NORMALIZADO` |
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

### Resultado na VM (06/11/2026, VirtualBox, Ubuntu Server 24.04.5)

VM limpa, criada da imagem oficial do Ubuntu (`noble-server-cloudimg-amd64.ova`, SHA-256 conferido): 2 vCPU, 4 GB, placa 1 em NAT e placa 2 em host-only. O repositório foi clonado do GitHub dentro dela, e o `sudo ./provisionar.sh` rodou como o grupo vai rodar.

| O quê | Resultado |
|---|---|
| `provisionar.sh` do zero | **4 min 4 s**, as 3 etapas sem erro |
| Hostname | `ubuntu-limpa` → **`aquenda-srv`** (`hostnamectl`) |
| IP fixo | **`192.168.56.10/24` em `enp0s8`** pelo netplan; `enp0s3` segue no DHCP (10.0.2.15) |
| DNS | systemd-resolved com 1.1.1.1 e 8.8.8.8; `github.com` resolve |
| Firewall | ufw ativo, entrada só em 22, 5000 e 8000 |
| Acesso de fora | **do Windows**, `curl http://192.168.56.10:5000/api/servicos` devolve os 10 serviços e `http://192.168.56.10:8000/docs` dá 200; a porta 5432 não passa |
| `kill -9` na API C# | processo novo em **5,1 s**; API respondendo em **7,3 s** |
| `stress` de CPU | `ALERTA recurso=cpu uso=100%` em **33 s** e `NORMALIZADO` no fim |
| PostgreSQL parado | `/health`: `503 {"title":"Banco indisponível"}`; a API C# seguiu no ar; o timer religou o banco em **12 s** |
| auditd | 6 regras ativas. `aureport -k` registrou 57 eventos em `aquenda_app`, 39 em `aquenda_servicos`, 9 em `aquenda_segredos` e 8 em `aquenda_dados`. Exemplo: *"lynn, acting as root, successfully opened-file /etc/aquenda/api.env using /usr/bin/cat"* |

Dois ajustes saíram deste teste:
- **Prioridade do monitor.** Com `Nice=5` e só 2 vCPUs, o `stress` deixou o monitor 1,5 min sem medir. Agora ele roda com `Nice=-10` e `CPUWeight=1000`, porque o monitor precisa medir justamente quando a CPU está cheia.
- **Servidores de build do .NET.** O `dotnet publish` deixava os servidores de build vivos, com uns 300 MB de RAM. Agora o script os desliga depois de publicar.

A VM rodou no VirtualBox sobre o Hyper-V do Windows (modo NEM), que é mais lento sob carga: com a CPU cheia, um `sleep 2` chegou a levar 8,8 s dentro da VM. Por isso o alerta levou 33 s na VM e 5 s no container, e o teste de CPU tem margem de 150 s.

### Resultado no container de teste (Ubuntu 24.04 com systemd)

| O quê | Resultado |
|---|---|
| `provisionar.sh` do zero | **1 min 37 s**, as 3 etapas sem erro. Rodando de novo, nada se duplica (`/etc/hosts`, banco, `.env`, clone) |
| Funcionamento | `curl localhost:5000/api/servicos` devolve os 10 serviços do catálogo; `curl localhost:8000/docs` dá HTTP 200 |
| `kill -9` na API C# | processo novo em **5,1 s**; API respondendo em **7,2 s** |
| `kill -9` no próprio monitor | o systemd sobe outro em 5 s (`NRestarts=1`) |
| `stress` de CPU | primeiro `ALERTA recurso=cpu uso=99%` em **5 s**, um alerta a cada 15 s enquanto durou e `NORMALIZADO` no fim |
| PostgreSQL parado | `/health` da FastAPI: `503 {"title":"Banco indisponível"}`. A API C# seguiu respondendo 200. O timer religou o banco em **34 s** |
| Auditoria | 67 linhas no `audit.log`, uma por passo de cada script, mais o religamento do banco feito pelo timer |

O container não tem kernel nem placa de rede próprios. Por isso o IP fixo (netplan), o `hostnamectl` e o auditd ficaram para a VM, onde funcionaram (veja acima). No container, os scripts avisaram e seguiram.

## Evidências

Em `docs/evidencias/`:

| Arquivo | O que mostra |
|---|---|
| `vm/01-provisionamento-vm.txt` | **na VM:** o clone do GitHub e o `provisionar.sh` do começo ao fim |
| `vm/02-acesso-pelo-host.txt` | o Windows acessando as duas APIs pelo IP fixo, e a 5432 fechada |
| `vm/03-teste-falha-vm.txt` e `vm/03b-teste-cpu-com-prioridade.txt` | os testes de falha na VM |
| `vm/04-estado-da-vm.txt` | `hostnamectl`, `ip addr`, netplan, DNS, ufw, serviços, timers e journal do monitor |
| `vm/05-audit.log`, `vm/06-monitor.log` | os logs de auditoria e do monitor da VM |
| `vm/07-auditd.txt` | o auditd registrando quem leu os segredos e quem mexeu no código publicado |
| `01-provisionamento.txt` | no container: o `provisionar.sh` do começo ao fim |
| `02-teste-falha.txt` | os três testes de falha com os tempos |
| `03-audit.log` | o log de auditoria gerado |
| `04-monitor.log` | o log do monitor com o alerta de CPU |
| `05-servicos.txt` | `systemctl status` dos serviços e timers |

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
