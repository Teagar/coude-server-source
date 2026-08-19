# COUDE API — Documentação Técnica de Integração

**Para quem é este guia:** desenvolvedores que querem consumir a API COUDE a
partir de um sistema próprio — matrícula, portal do aluno, automação de
cadastro em massa, etc. — sem precisar entrar no servidor manualmente.

**Versão da API:** `2.1.0` · **Base URL:** `http://192.168.1.10:8080/api/v1`
(ajuste o IP para o do seu servidor)

> A API roda hoje em HTTP puro dentro da rede local (LAN), sem TLS. Não
> exponha a porta `8080` para a internet. Se precisar integrar a partir de
> fora da LAN, coloque um reverse proxy com TLS (ex. Caddy/Nginx) na frente
> e restrinja por IP/VPN — a API em si não faz esse trabalho.

---

## Sumário

1. [Autenticação](#1-autenticação)
2. [Formato de resposta e erros](#2-formato-de-resposta-e-erros)
3. [Rate limit e idempotência](#3-rate-limit-e-idempotência)
4. [Modelo de dados](#4-modelo-de-dados)
5. [Referência dos endpoints](#5-referência-dos-endpoints)
6. [Ciclo de vida de um usuário](#6-ciclo-de-vida-de-um-usuário)
7. [Exemplos de integração](#7-exemplos-de-integração)
8. [Segurança](#8-segurança)
9. [Changelog](#9-changelog)

---

## 1. Autenticação

Toda rota (exceto `GET /health` e `GET /`) exige o header:

```text
X-API-Key: <chave>
```

A chave fica salva no servidor em `/etc/coude/api.key` (permissão `400`,
só root lê). Peça a chave para quem administra o servidor — ela não é
gerada por integração alguma, é fixa por instalação (pode ser rotacionada
manualmente).

Requisição sem a chave, ou com chave errada, recebe:

```json
{ "ok": false, "error": "Unauthorized" }
```
com status `401`.

---

## 2. Formato de resposta e erros

Toda resposta é JSON e sempre traz o campo `ok`:

- `"ok": true` — sucesso. Os demais campos variam por endpoint.
- `"ok": false` — falha. Vem acompanhado de `"error"` (mensagem única) ou
  `"errors"` (objeto por campo, em validações de formulário).

Exemplo de erro de validação (status `422`):

```json
{
  "ok": false,
  "errors": {
    "email": "Formato inválido",
    "cpf": "CPF inválido (dígitos verificadores)"
  }
}
```

### Códigos de status usados

| Código | Significado |
|---|---|
| `200` | Sucesso (consulta ou operação idempotente repetida) |
| `201` | Recurso criado |
| `401` | `X-API-Key` ausente ou inválida |
| `404` | Recurso não encontrado (usuário/turma) |
| `409` | Conflito — e-mail ou CPF já cadastrado |
| `422` | Corpo da requisição inválido (campo faltando ou mal formatado) |
| `429` | Rate limit excedido |
| `500` | Erro interno (ex.: falha do `samba-tool`) |
| `501` | Recurso não implementado no servidor (ex.: `ldbmodify` ausente) |

---

## 3. Rate limit e idempotência

- **Rate limit:** 60 requisições/minuto por IP de origem e 200/minuto por
  chave de API. Excedeu → `429 { "ok": false, "error": "Rate limit exceeded" }`.
  Isso é mantido em memória no processo da API — reinicia se o serviço
  reiniciar. Não é um limite pensado para tráfego alto; é uma proteção
  básica contra loops/bugs no seu integrador.

- **Idempotência em `POST /usuarios/cadastrar`:** envie
  `metadata.id_externo` com o ID do registro no *seu* sistema (matrícula,
  por exemplo). Se você reenviar a mesma requisição com o mesmo
  `id_externo`, a API devolve a resposta já salva em vez de tentar criar o
  usuário de novo — útil para reprocessar filas ou timeouts sem duplicar
  cadastros. **A idempotência vive em memória e não sobrevive a um restart
  do serviço** — não é uma garantia permanente, é proteção para
  retries de curto prazo.

---

## 4. Modelo de dados

### Cargos

```text
aluno | professor | monitor | admin
```

Cada cargo tem uma OU e um grupo correspondentes no Active Directory:

| Cargo | OU | Grupo |
|---|---|---|
| `aluno` | `OU=Alunos,OU=Usuarios` | `alunos` |
| `professor` | `OU=Professores,OU=Usuarios` | `professores` |
| `monitor` | `OU=Monitores,OU=Usuarios` | `monitores` |
| `admin` | `OU=Administradores,OU=Usuarios` | `administradores` |

`turma` é obrigatória para `aluno` e `monitor`; opcional para os demais.

### Turmas

Nome sempre no formato `turma_<slug_minusculo>` (ex.: `turma_fullstack_001`).
Cada turma é um grupo do AD e uma pasta em `/srv/samba/turmas/<turma>`.

### Username gerado automaticamente

Você **nunca escolhe o username** — ele é derivado do nome completo pelo
servidor (fragmentos de 3 a 5 letras do primeiro e do último nome,
combinados até achar um username livre, 4 a 8 caracteres). Ex.: "Thiago
Cerqueira" → algo como `thicer`. O username definitivo só é conhecido na
resposta do `POST /usuarios/cadastrar`.

### Senha inicial

A senha inicial é gerada pelo servidor como `Coude@<CPF_só_números>!` e a
conta é criada com a flag "trocar senha no próximo login" — o usuário é
obrigado a definir uma senha nova no primeiro acesso ao Windows. **A API
não aceita uma senha vinda do seu sistema** no cadastro; se seu fluxo
precisa que o usuário escolha a própria senha antes do primeiro login,
gere a senha localmente para exibir a ele e/ou use
`POST /usuarios/<username>/senha` depois para definir uma senha específica.

### CPF

Usado só para (a) compor a senha inicial e (b) checar duplicidade — fica
guardado de forma normalizada (somente dígitos) no atributo `description`
do usuário no AD, já que o Samba AD não tem um campo nativo de CPF. Não é
exposto por padrão nas consultas de listagem, mas volta no
`GET /usuarios/disponibilidade`.

---

## 5. Referência dos endpoints

### `GET /health`
Sem autenticação. Uso: monitoramento externo (uptime checks, etc.).

```json
{ "status": "ok", "samba": true, "version": "2.1.0", "timestamp": "2026-08-19T12:00:00Z" }
```

### `GET /`
Sem autenticação. Lista todas as rotas disponíveis — útil para descobrir a
API programaticamente sem precisar deste documento em mãos.

---

### `POST /usuarios/cadastrar`

Cria um usuário no Active Directory: gera username, cria a conta na OU e
grupo do cargo, associa à turma (se aplicável) e cria as pastas pessoais.

**Body:**

```json
{
  "nome_completo": "Thiago Cerqueira",
  "email": "thiago@email.com",
  "cpf": "529.982.247-25",
  "cargo": "aluno",
  "turma": "turma_fullstack_001",
  "metadata": { "id_externo": "EXT-2026-0142" }
}
```

| Campo | Obrigatório | Regra |
|---|---|---|
| `nome_completo` | sim | mínimo 2 palavras |
| `email` | sim | formato válido; precisa ser único |
| `cpf` | sim | dígitos verificadores válidos; precisa ser único |
| `cargo` | sim | `aluno`\|`professor`\|`monitor`\|`admin` |
| `turma` | condicional | obrigatório se `cargo` for `aluno` ou `monitor` |
| `metadata.id_externo` | não | chave de idempotência (ver seção 3) |

**Resposta (`201`):**

```json
{
  "ok": true,
  "username": "thicer",
  "email_ad": "thicer@ad.coude.com.br",
  "pasta": "/srv/samba/users/thicer",
  "grupos": ["alunos", "turma_fullstack_001"],
  "must_change_password": true
}
```

Erros possíveis: `422` (validação), `409` (e-mail ou CPF já existe), `500`
(falha ao criar no AD — a API já reverte automaticamente qualquer etapa
parcial, então nunca fica um usuário "pela metade").

---

### `GET /usuarios`

Lista usuários com filtros e paginação.

**Query params:**

| Param | Default | Descrição |
|---|---|---|
| `cargo` | — | filtra por `aluno`\|`professor`\|`monitor`\|`admin` |
| `turma` | — | filtra por turma (ex.: `turma_fullstack_001`) |
| `status` | `ativos` | `ativos`\|`deletados`\|`todos` |
| `page` | `1` | página (1-based) |
| `per_page` | `50` | itens por página (máx. `200`) |

`cargo` e `turma` não se combinam — se os dois vierem, `turma` prevalece.

```bash
curl -s "http://192.168.1.10:8080/api/v1/usuarios?cargo=aluno&turma=turma_fullstack_001&page=1" \
  -H "X-API-Key: $API_KEY"
```

**Resposta:**

```json
{
  "ok": true,
  "page": 1,
  "per_page": 50,
  "total_geral": 3,
  "total_pagina": 3,
  "usuarios": [
    {
      "username": "thicer",
      "displayName": "Thiago Cerqueira",
      "email": "thiago@email.com",
      "enabled": true,
      "deletado": false,
      "cpf": "52998224725",
      "dn": "CN=Thiago Cerqueira,OU=Alunos,OU=Usuarios,DC=ad,DC=coude,DC=com,DC=br"
    }
  ]
}
```

> Este endpoint chama `samba-tool` uma vez por usuário retornado — é
> pensado para o tamanho de uma escola (centenas de contas), não para
> milhares. Use os filtros para reduzir o volume por chamada.

---

### `GET /usuarios/disponibilidade`

Confere, **antes de tentar cadastrar**, se um e-mail e/ou CPF já estão em
uso — útil para validar em tempo real num formulário de matrícula.

**Query params:** `email` e/ou `cpf` (pelo menos um).

```bash
curl -s "http://192.168.1.10:8080/api/v1/usuarios/disponibilidade?email=thiago@email.com&cpf=52998224725" \
  -H "X-API-Key: $API_KEY"
```

```json
{
  "ok": true,
  "email": { "valor": "thiago@email.com", "disponivel": false, "username": "thicer" },
  "cpf": { "valor": "52998224725", "disponivel": false, "username": "thicer" }
}
```

---

### `GET /usuarios/<username>`

Consulta um usuário específico.

```json
{
  "ok": true,
  "username": "thicer",
  "displayName": "Thiago Cerqueira",
  "email": "thiago@email.com",
  "enabled": true,
  "dn": "CN=Thiago Cerqueira,OU=Alunos,OU=Usuarios,DC=ad,DC=coude,DC=com,DC=br"
}
```

`404` se o username não existir (incluindo os que já foram excluídos
definitivamente).

---

### `PUT /usuarios/<username>`

Atualiza `nome_completo`, `email` e/ou `cargo` de um usuário existente.
Envie só os campos que quer alterar.

```json
{ "email": "thiago.novo@email.com", "cargo": "monitor" }
```

- Mudança de `cargo` move o usuário para a OU correta e troca o grupo de
  cargo automaticamente (não mexe na turma — use o endpoint de turma para
  isso).
- Mudança de `email`/`nome_completo` depende do utilitário `ldbmodify`
  (pacote `ldb-tools`) estar instalado no servidor. Se não estiver,
  responde `500` com uma mensagem explicando o motivo — rode
  `scripts/coude-update-api.sh` ou `apt-get install ldb-tools` no servidor
  para habilitar.

**Resposta:**

```json
{ "ok": true, "username": "thicer", "alterado": { "cargo": "monitor" } }
```

---

### `PUT /usuarios/<username>/turma`

Troca a turma de um usuário (ex.: aluno que migrou de turma).

```json
{ "turma_nova": "turma_devops_002", "turma_anterior": "turma_fullstack_001" }
```

`turma_anterior` é opcional — se vier, o usuário é removido dela antes de
entrar na nova. Se não vier, ele só é adicionado à nova (pode ficar em
mais de uma turma ao mesmo tempo, se for essa a intenção).

---

### `POST /usuarios/<username>/senha`

Redefine a senha de um usuário (ex.: "esqueci minha senha", atendido pela
secretaria/TI através do seu sistema).

**Body (opcional — sem corpo, gera uma senha aleatória):**

```json
{ "senha": "MinhaNovaSenha123" }
```

Se `senha` vier, precisa ter 8+ caracteres. Em ambos os casos a conta é
marcada para trocar a senha no próximo login.

**Resposta:**

```json
{
  "ok": true,
  "username": "thicer",
  "senha_temporaria": "Coude@a1b2c3d4!",
  "must_change_password": true
}
```

> A senha volta em texto plano na resposta porque é o único jeito de
> repassá-la para quem vai usá-la — trate essa resposta como dado
> sensível no seu sistema (não logue, não deixe em histórico visível).

---

### `POST /usuarios/remover`

Desativa a conta (soft delete): desabilita login, move para
`OU=Deletados` e agenda expiração em 30 dias. **Reversível** dentro
desse prazo — depois disso, o purge automático diário do servidor apaga a
conta definitivamente.

```json
{ "username": "thicer" }
```

### `POST /usuarios/restaurar`

Reverte o soft delete: reabilita a conta e move de volta para a OU do
cargo informado.

```json
{ "username": "thicer", "cargo": "aluno" }
```

### `DELETE /usuarios/<username>?confirmar=true`

Exclusão **definitiva e imediata**, fora do fluxo de soft delete/purge —
use com cautela (ex.: cadastro feito por engano). O parâmetro
`?confirmar=true` é obrigatório; sem ele a API recusa com `422` e sugere o
fluxo reversível. A pasta pessoal é movida para `arquivo_morto` antes da
exclusão da conta.

Para o dia a dia (aluno trancou matrícula, saiu da escola, etc.), prefira
sempre `POST /usuarios/remover`.

---

### `POST /turmas/criar`

```json
{ "nome": "turma_devops_002" }
```

Nome precisa bater com `^turma_[a-z0-9_]+$`. Cria o grupo no AD e a
estrutura de pastas (`_geral/Materiais`, `_geral/Avisos`, `alunos/`).

### `GET /turmas`

```json
{ "ok": true, "total": 2, "turmas": ["turma_devops_002", "turma_fullstack_001"] }
```

### `GET /turmas/<nome>/membros`

```json
{ "ok": true, "turma": "turma_fullstack_001", "total_membros": 24, "membros": ["thicer", "..."] }
```

### `DELETE /turmas/<nome>`

Arquiva a turma: move a pasta para `arquivo_morto` e apaga o grupo do AD.
Os usuários que estavam na turma continuam existindo (só perdem a
associação ao grupo da turma).

---

### `GET /estatisticas`

Contagens rápidas para um painel administrativo.

```json
{
  "ok": true,
  "version": "2.1.0",
  "total_turmas": 2,
  "usuarios_por_cargo": { "aluno": 40, "professor": 3, "monitor": 2, "admin": 1 },
  "usuarios_por_turma": { "turma_fullstack_001": 24, "turma_devops_002": 16 },
  "total_usuarios_ativos": 46
}
```

---

## 6. Ciclo de vida de um usuário

```text
disponibilidade (opcional, valida no formulário)
        │
        ▼
POST /usuarios/cadastrar  ──────────► conta criada, must_change_password=true
        │
        ├── PUT /usuarios/<u>/turma       (mudou de turma)
        ├── PUT /usuarios/<u>             (mudou e-mail/nome/cargo)
        ├── POST /usuarios/<u>/senha      (esqueceu a senha)
        │
        ▼
POST /usuarios/remover  ─────────────► desabilitado, OU=Deletados
        │                              (purge automático em 30 dias)
        ├── POST /usuarios/restaurar  ──► volta a ativo
        │
        ▼ (se realmente definitivo)
DELETE /usuarios/<u>?confirmar=true ──► apagado do AD, sem volta
```

---

## 7. Exemplos de integração

### cURL

```bash
API="http://192.168.1.10:8080/api/v1"
KEY="sua_chave_aqui"

curl -s -X POST "$API/usuarios/cadastrar" \
  -H "X-API-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "nome_completo": "Thiago Cerqueira",
    "email": "thiago@email.com",
    "cpf": "529.982.247-25",
    "cargo": "aluno",
    "turma": "turma_fullstack_001",
    "metadata": {"id_externo": "EXT-2026-0142"}
  }'
```

### JavaScript (fetch)

```javascript
async function cadastrarUsuario(dados) {
  const resp = await fetch("http://192.168.1.10:8080/api/v1/usuarios/cadastrar", {
    method: "POST",
    headers: {
      "X-API-Key": process.env.COUDE_API_KEY,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(dados)
  });
  const data = await resp.json();
  if (!resp.ok || !data.ok) {
    throw new Error(data.error || JSON.stringify(data.errors));
  }
  return data; // { username, email_ad, pasta, grupos, must_change_password }
}
```

### Python (requests)

```python
import os
import requests

API = "http://192.168.1.10:8080/api/v1"
HEADERS = {"X-API-Key": os.environ["COUDE_API_KEY"]}

def cadastrar_usuario(nome_completo, email, cpf, cargo, turma=None, id_externo=None):
    payload = {
        "nome_completo": nome_completo,
        "email": email,
        "cpf": cpf,
        "cargo": cargo,
    }
    if turma:
        payload["turma"] = turma
    if id_externo:
        payload["metadata"] = {"id_externo": id_externo}

    r = requests.post(f"{API}/usuarios/cadastrar", json=payload, headers=HEADERS, timeout=15)
    data = r.json()
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or data.get("errors"))
    return data
```

---

## 8. Segurança

- Nunca coloque a `X-API-Key` em código versionado, front-end público ou
  logs. Use variável de ambiente/segredo no seu backend.
- A chave dá acesso total de gestão de usuários — trate como uma senha de
  administrador.
- Rotação de chave (no servidor, como root):

  ```bash
  python3 -c "import secrets; print(secrets.token_hex(32))" | sudo tee /etc/coude/api.key
  sudo chmod 400 /etc/coude/api.key
  sudo systemctl restart coude-api
  ```

  Depois de rotacionar, atualize a chave em todos os sistemas que
  integram com a API.
- A API não faz TLS. Se o seu sistema roda fora da LAN do servidor, não
  chame a API diretamente pela internet — use VPN ou um reverse proxy com
  TLS entre o seu sistema e o servidor.
- Todas as chamadas autenticadas ficam registradas em
  `/var/log/coude/api.log` (hash parcial da chave usada, IP de origem,
  endpoint) para auditoria.

---

## 9. Changelog

### `2.1.0`
- **Correção:** o fluxo de cadastro tinha uma chamada a
  `samba-tool user setpassword --must-change-at-next-login` sem
  `--newpassword`, que exige um prompt interativo inexistente neste
  contexto e sempre falhava, revertendo o cadastro inteiro. A flag agora
  é aplicada direto na criação do usuário (`user create ...
  --must-change-at-next-login`).
- Adicionado: verificação de duplicidade de e-mail/CPF no cadastro
  (`409` em vez de criar contas conflitantes).
- Adicionado: `GET /usuarios`, `GET /usuarios/disponibilidade`,
  `PUT /usuarios/<username>`, `POST /usuarios/<username>/senha`,
  `DELETE /usuarios/<username>`, `GET /turmas`,
  `GET /turmas/<nome>/membros`, `GET /estatisticas`, `GET /`.
- `GET /health` agora inclui `version`.

### `2.0.0`
- Versão inicial: `health`, `usuarios/cadastrar`, `usuarios/remover`,
  `usuarios/restaurar`, `usuarios/<username>` (GET),
  `usuarios/<username>/turma` (PUT), `turmas/criar`,
  `turmas/<nome>` (DELETE).
