# Módulo `prepreenchido`

Estrutura esperada:

- `sql/baseline/V1__baseline.sql`
- `sql/migrations/V2__*.sql`, `V3__*.sql`, ...
- `tests/*.sql`

Comandos úteis (na raiz do projeto):

```bash
./scripts/run-module.sh prepreenchido all
./scripts/run-module.sh prepreenchido migrate
./scripts/run-module.sh prepreenchido test
```
