# 🐘 pg-flyway-test-runner

# 🐘 pg-flyway-test-runner

[![CI](https://github.com/emanuelpedrozo/pg-flyway-test-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/emanuelpedrozo/pg-flyway-test-runner/actions)  
![PostgreSQL 16](https://img.shields.io/badge/PostgreSQL-16-blue?logo=postgresql)  
![PostGIS 3.5](https://img.shields.io/badge/PostGIS-3.5-00aaff)  
![Flyway 10.x](https://img.shields.io/badge/Flyway-10.x-red)  
![Docker Ready](https://img.shields.io/badge/Docker-ready-2496ED?logo=docker&logoColor=white)  

Ambiente **Docker + Flyway + PostGIS** para **versionamento, migração e testes automatizados** de funções SQL em PostgreSQL.

Este projeto foi criado para padronizar e automatizar o ciclo de vida de funções de banco de dados — desde a criação e versionamento até a execução de testes automatizados e CI/CD completo no GitHub Actions.

---

## 📦 Stack utilizada

| Componente | Versão | Descrição |
|-------------|---------|-----------|
| **PostgreSQL** | 16.x | Banco relacional principal |
| **PostGIS** | 3.5 | Extensão espacial para PostgreSQL |
| **Flyway** | 10.x | Controle de versionamento e migrações SQL |
| **Docker Compose** | latest | Orquestração local dos serviços |
| **GitHub Actions** | - | CI/CD automatizado com validação de migrações e testes |

---

## ⚙️ Estrutura do projeto

```
pg-flyway-test-runner/
├─ docker-compose.yml
├─ .github/
│   └─ workflows/
│       └─ ci.yml
├─ initdb/
│   └─ 01_extensions.sql
├─ sql/
│   ├─ baseline/
│   │   └─ V1__baseline.sql
│   ├─ migrations/
│   │   └─ V2__ajuste.sql
│   └─ callbacks/
│       └─ afterMigrate__run_tests.sql
├─ tests/
│   └─ test_paa_rio.sql
├─ tests_output/
├─ .env.example
└─ .gitignore
```

---

## 🚀 Como executar localmente

### 1️⃣ Configurar variáveis de ambiente
Crie um arquivo `.env` a partir do `.env.example`:

```bash
cp .env.example .env
```

### 2️⃣ Subir o ambiente
```bash
docker compose up -d postgres
```

### 3️⃣ Aplicar baseline e migrações
```bash
docker compose run --rm flyway-migrate
```

### 4️⃣ Executar testes automatizados
```bash
docker compose run --rm db-tests
```

O resultado do teste será salvo em:
```
tests_output/test_paa_rio_result.json
```

### 5️⃣ Recriar o ambiente do zero
```bash
docker compose down -v
docker compose up -d postgres
docker compose run --rm flyway-migrate
```

---

## 🔁 Integração Contínua (CI/CD)

Cada **push** no branch `main` ou **Pull Request** aciona automaticamente o pipeline do GitHub Actions:

- Sobe um container PostGIS
- Executa as migrações Flyway
- Roda os testes SQL definidos em `/tests`
- Exibe o resultado diretamente nos logs do GitHub Actions

A pipeline está em:
```
.github/workflows/ci.yml
```

---

## 🧠 Conceitos principais

| Conceito | Descrição |
|-----------|------------|
| **Baseline** | Representa o estado inicial do banco de dados versionado. |
| **Migração (V2, V3...)** | Scripts incrementais para criar ou alterar funções/tabelas. |
| **Testes SQL** | Scripts automatizados que validam o comportamento das funções (com asserts ou `RAISE EXCEPTION`). |
| **CI/CD** | Pipeline que garante que cada commit mantenha o banco íntegro e testado. |

---

## 📊 Exemplo de resultado de teste

Arquivo: `tests_output/test_paa_rio_result.json`

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "layer": "APP",
        "area_ha": 1.23
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[...]]]
      }
    }
  ]
}
```

---

## 🧰 Comandos úteis

| Comando | Descrição |
|----------|------------|
| `docker compose up -d postgres` | Sobe o banco local |
| `docker compose run --rm flyway-migrate` | Aplica migrações |
| `docker compose run --rm db-tests` | Executa testes SQL |
| `docker compose down -v` | Remove containers e volume de dados |
| `flyway info` | Mostra status das migrações |

---

## 🧑‍💻 Autor

**Emanuel Pedrozo**  
📍 Engenharia de Dados | Administração PostgreSQL | PostGIS | DevOps  
📫 [linkedin.com/in/emanuelpedrozo](https://linkedin.com/in/emanuelpedrozo)

---

## 🪪 Licença

Distribuído sob a licença MIT.  
Sinta-se livre para usar, modificar e contribuir com o projeto.
