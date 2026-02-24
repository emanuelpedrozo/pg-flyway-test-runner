# pg-flyway-test-runner (modular)

Projeto base para executar módulos de funções SQL geoespaciais com PostgreSQL + PostGIS + Flyway + testes SQL.

## Estrutura

```text
.
├─ docker-compose.yml
├─ .env / .env.example
├─ initdb/
│  └─ 01_extensions.sql
├─ modules/
│  ├─ dpg/
│  │  ├─ sql/
│  │  │  ├─ baseline/
│  │  │  └─ migrations/
│  │  └─ tests/
│  └─ prepreenchido/
│     ├─ sql/
│     │  ├─ baseline/
│     │  └─ migrations/
│     └─ tests/
├─ scripts/
│  └─ run-module.sh
└─ .github/workflows/ci.yml
```

## Conceito

- Cada módulo tem seu próprio SQL e testes.
- A infraestrutura (Postgres, Flyway, runner de testes, CI) é compartilhada.
- O módulo ativo é definido por `MODULE` no ambiente (`dpg`, `prepreenchido`, etc.).

## Configuração

1. Crie `.env`:

```bash
cp .env.example .env
```

2. Ajuste variáveis se necessário:

```env
PGHOST=postgres
PGPORT=5432
PGDATABASE=dpg_dev
PGUSER=postgres
PGPASSWORD=postgres
FLYWAY_SCHEMAS=geometry_bases
MODULE=dpg
```

## Execução local

### Usando docker compose diretamente

```bash
docker compose up -d postgres
docker compose run --rm flyway-migrate
docker compose run --rm db-tests
```

### Usando helper script

```bash
# roda up + migrate + test
./scripts/run-module.sh dpg all

# só migrate
./scripts/run-module.sh dpg migrate

# só tests
./scripts/run-module.sh dpg test
```

Para o novo módulo:

```bash
./scripts/run-module.sh prepreenchido all
```

## CI/CD

O workflow usa matriz por módulo (`dpg` e `prepreenchido`):

- detecta se o módulo tem SQL e testes
- aplica migrações Flyway apenas quando houver SQL
- executa testes SQL apenas quando houver testes
- valida JSONs `*_result.json`
- publica viewer no GitHub Pages em subpastas por módulo (`/dpg`, `/prepreenchido`)

Arquivo: `.github/workflows/ci.yml`

## Convenções para novos módulos

- Baseline: `modules/<modulo>/sql/baseline/V1__baseline.sql`
- Migrações: `modules/<modulo>/sql/migrations/V2__*.sql`, `V3__*.sql`, ...
- Testes: `modules/<modulo>/tests/*.sql`
- Saída de teste: use `\g /tests_output/<nome>_result.json`
