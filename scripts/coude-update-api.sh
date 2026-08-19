#!/usr/bin/env bash
# =============================================================================
# COUDE — Atualizador da API (coude-update-api.sh)
# =============================================================================
# Aplica a versão mais recente de /opt/coude-api/app.py em um servidor COUDE
# JÁ INSTALADO e funcional, sem reprovisionar o domínio Samba AD nem tocar
# em nada além da API. Faz backup do app.py atual antes de sobrescrever e
# reinicia o serviço coude-api ao final.
#
# Uso (no servidor, como root):
#   sudo bash coude-update-api.sh
# =============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }
fatal() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && fatal "Execute como root: sudo bash $0"

APP_FILE="/opt/coude-api/app.py"
[[ -f "$APP_FILE" ]] || fatal "Não encontrei $APP_FILE — este script é para atualizar uma instalação existente. Use setup.sh para uma instalação nova."

info "Lendo configuração da instalação atual em $APP_FILE ..."

SERVER_IP=$(grep -oP '(?<=^SERVER_IP    = ")[^"]+' "$APP_FILE") || fatal "Não consegui detectar SERVER_IP no app.py atual"
API_PORT=$(grep -oP '(?<=^API_PORT     = )[0-9]+' "$APP_FILE")   || fatal "Não consegui detectar API_PORT no app.py atual"
CERT_DIR=$(grep -oP '(?<=^API_KEY_FILE = ")[^"]+(?=/api\.key")' "$APP_FILE") || fatal "Não consegui detectar CERT_DIR no app.py atual"
SAMBA_DATA=$(grep -oP '(?<=^SAMBA_DATA   = ")[^"]+' "$APP_FILE") || fatal "Não consegui detectar SAMBA_DATA no app.py atual"
API_DIR=$(dirname "$APP_FILE")

info "SERVER_IP=$SERVER_IP  API_PORT=$API_PORT  CERT_DIR=$CERT_DIR  SAMBA_DATA=$SAMBA_DATA"

# Dependência necessária para o endpoint PUT /usuarios/<username>
# (atualização de e-mail/nome usa ldbmodify).
if ! command -v ldbmodify >/dev/null 2>&1; then
    info "Instalando ldb-tools (necessário para PUT /usuarios/<username>) ..."
    apt-get update -qq && apt-get install -y ldb-tools 2>/dev/null \
        && log "ldb-tools instalado" \
        || warn "Não foi possível instalar ldb-tools automaticamente. Instale manualmente: apt-get install ldb-tools"
fi

BACKUP="$APP_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP_FILE" "$BACKUP"
log "Backup do app.py atual salvo em $BACKUP"

cat > "$API_DIR/app.py" <<PYEOF
#!/usr/bin/env python3
"""
COUDE API v2 — Flask
Base URL: http://${SERVER_IP}:${API_PORT}/api/v1
Auth: header X-API-Key
"""
import os, subprocess, hashlib, hmac, time, re, logging, secrets
from datetime import datetime
from functools import wraps
from flask import Flask, request, jsonify

app = Flask(__name__)

logging.basicConfig(
    filename='/var/log/coude/api.log',
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

# ── Constantes ────────────────────────────────────────────────────────────────
API_KEY_FILE = "$CERT_DIR/api.key"
DC_SUFFIX    = "DC=ad,DC=coude,DC=com,DC=br"
SAMBA_DATA   = "$SAMBA_DATA"
SERVER_IP    = "$SERVER_IP"
API_PORT     = $API_PORT
API_VERSION  = "2.1.0"
CARGOS       = ("aluno", "professor", "monitor", "admin")

# ── Estado em memória (em produção use Redis para rate limit) ─────────────────
RATE_STORE   = {}   # key → [timestamps]
IDEMPOTENCY  = {}   # id_externo → response


# =============================================================================
# HELPERS
# =============================================================================

def get_api_key():
    with open(API_KEY_FILE) as f:
        return f.read().strip()

def rate_ok(key, limit, window=60):
    now = time.time()
    times = [t for t in RATE_STORE.get(key, []) if now - t < window]
    times.append(now)
    RATE_STORE[key] = times
    return len(times) <= limit

def samba(*args):
    """Executa samba-tool e retorna (returncode, stdout, stderr)."""
    r = subprocess.run(["samba-tool"] + list(args),
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr

def validate_cpf(cpf):
    cpf = re.sub(r'\D', '', cpf)
    if len(cpf) != 11 or len(set(cpf)) == 1:
        return False
    for i in range(9, 11):
        s = sum(int(cpf[j]) * (i + 1 - j) for j in range(i))
        if int(cpf[i]) != (s * 10 % 11) % 10:
            return False
    return True

def normalize_cpf(cpf):
      return re.sub(r"\D", "", cpf)

def gen_username(nome):
    r = subprocess.run(
        ["python3", "/usr/local/bin/coude-gen-username.py", nome],
        capture_output=True, text=True
    )
    if r.returncode != 0:
        raise ValueError(f"Não foi possível gerar username: {r.stderr.strip()}")
    return r.stdout.strip()

def ou_for_cargo(cargo):
    m = {
        "aluno":     "OU=Alunos,OU=Usuarios",
        "professor": "OU=Professores,OU=Usuarios",
        "monitor":   "OU=Monitores,OU=Usuarios",
        "admin":     "OU=Administradores,OU=Usuarios",
    }
    return f"{m[cargo]},{DC_SUFFIX}"

def group_for_cargo(cargo):
    return {
        "aluno": "alunos", "professor": "professores",
        "monitor": "monitores", "admin": "administradores"
    }[cargo]

def cargo_for_group(group):
    return {
        "alunos": "aluno", "professores": "professor",
        "monitores": "monitor", "administradores": "admin"
    }.get(group)

def build_description(cpf):
    """Codifica metadados internos (hoje só o CPF normalizado) no atributo
    'description' do AD, já que o Samba AD não tem um campo nativo para CPF.
    Formato: 'coude:cpf=12345678900'
    """
    return f"coude:cpf={normalize_cpf(cpf)}"

def parse_description(description):
    """Extrai metadados do campo description gerado por build_description()."""
    meta = {}
    if description.startswith("coude:"):
        for part in description[len("coude:"):].split(";"):
            if "=" in part:
                k, _, v = part.partition("=")
                meta[k.strip()] = v.strip()
    return meta

def user_fields(username):
    """Executa 'user show' e devolve um dict com os atributos, ou None se
    o usuário não existir."""
    rc, out, _ = samba("user", "show", username)
    if rc != 0:
        return None
    fields = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip()
    return fields

def user_summary(username, fields=None):
    """Monta o resumo padrão de um usuário a partir dos atributos do AD."""
    fields = fields if fields is not None else user_fields(username)
    if fields is None:
        return None
    uac = fields.get("userAccountControl", "")
    enabled = "66050" not in uac and "514" not in uac
    dn = fields.get("dn", "")
    meta = parse_description(fields.get("description", ""))
    return {
        "username":    username,
        "displayName": fields.get("displayName", ""),
        "email":       fields.get("mail", ""),
        "enabled":     enabled,
        "deletado":    "OU=Deletados" in dn,
        "cpf":         meta.get("cpf", ""),
        "dn":          dn,
    }

def all_usernames():
    rc, out, err = samba("user", "list")
    if rc != 0:
        raise RuntimeError(err.strip())
    return sorted(l.strip() for l in out.splitlines() if l.strip())

def group_members(group):
    """Lista membros de um grupo. Retorna None se o grupo não existir."""
    rc, out, err = samba("group", "listmembers", group)
    if rc != 0:
        return None
    return sorted(l.strip() for l in out.splitlines() if l.strip())

def all_turmas():
    rc, out, err = samba("group", "list")
    if rc != 0:
        raise RuntimeError(err.strip())
    return sorted(
        l.strip() for l in out.splitlines()
        if l.strip().startswith("turma_")
    )


# =============================================================================
# AUTH DECORATOR
# =============================================================================

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        provided = request.headers.get("X-API-Key", "")
        expected = get_api_key()
        if not hmac.compare_digest(provided.encode(), expected.encode()):
            logging.warning(f"Auth falhou - IP:{request.remote_addr}")
            return jsonify({"ok": False, "error": "Unauthorized"}), 401
        ip  = request.remote_addr
        khash = hashlib.sha256(provided.encode()).hexdigest()[:8]
        if not rate_ok(ip, 60) or not rate_ok(khash, 200):
            return jsonify({"ok": False, "error": "Rate limit exceeded"}), 429
        return f(*args, **kwargs)
    return decorated

def log_op(endpoint, extra=""):
    khash = hashlib.sha256(
        request.headers.get("X-API-Key", "").encode()
    ).hexdigest()[:8]
    logging.info(
        f"endpoint={endpoint} ip={request.remote_addr} "
        f"key={khash} {extra}"
    )


# =============================================================================
# ENDPOINTS
# =============================================================================

@app.route("/api/v1/health", methods=["GET"])
def health():
    rc, _, _ = samba("domain", "level", "show")
    return jsonify({
        "status":    "ok" if rc == 0 else "degraded",
        "samba":     rc == 0,
        "version":   API_VERSION,
        "timestamp": datetime.utcnow().isoformat() + "Z"
    })


@app.route("/api/v1", methods=["GET"])
@app.route("/api/v1/", methods=["GET"])
def index():
    """Descoberta de endpoints. Não requer autenticação — não expõe dados,
    só a lista de rotas disponíveis (útil para quem está integrando)."""
    return jsonify({
        "ok":      True,
        "version": API_VERSION,
        "docs":    "Ver coude-documentacao-tecnica.md",
        "auth":    "Header X-API-Key em todas as rotas, exceto /health e /",
        "endpoints": {
            "GET  /api/v1/health":                      "Status do serviço (sem auth)",
            "POST /api/v1/usuarios/cadastrar":           "Criar usuário",
            "GET  /api/v1/usuarios":                     "Listar usuários (filtros: cargo, turma, status)",
            "GET  /api/v1/usuarios/disponibilidade":     "Checar e-mail/CPF antes de cadastrar",
            "GET  /api/v1/usuarios/<username>":          "Consultar usuário",
            "PUT  /api/v1/usuarios/<username>":          "Atualizar nome/email/cargo",
            "PUT  /api/v1/usuarios/<username>/turma":    "Trocar turma",
            "POST /api/v1/usuarios/<username>/senha":    "Redefinir senha",
            "POST /api/v1/usuarios/remover":             "Desativar (soft delete, reversível por 30 dias)",
            "POST /api/v1/usuarios/restaurar":           "Reativar usuário desativado",
            "DELETE /api/v1/usuarios/<username>":        "Excluir definitivamente (?confirmar=true)",
            "GET  /api/v1/turmas":                       "Listar turmas",
            "POST /api/v1/turmas/criar":                 "Criar turma",
            "GET  /api/v1/turmas/<nome>/membros":        "Listar membros de uma turma",
            "DELETE /api/v1/turmas/<nome>":               "Arquivar turma",
            "GET  /api/v1/estatisticas":                 "Contagens gerais"
        }
    })


@app.route("/api/v1/usuarios/cadastrar", methods=["POST"])
@require_auth
def cadastrar():
    data = request.get_json(force=True) or {}
    log_op("/usuarios/cadastrar")

    id_ext = data.get("metadata", {}).get("id_externo", "")
    if id_ext and id_ext in IDEMPOTENCY:
        return jsonify(IDEMPOTENCY[id_ext]), 200

    errs = {}

    nome = data.get("nome_completo", "").strip()
    if len(nome.split()) < 2:
        errs["nome_completo"] = "Mínimo 2 palavras"

    email = data.get("email", "").strip()
    if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
        errs["email"] = "Formato inválido"

    cpf = data.get("cpf", "")
    if not validate_cpf(cpf):
        errs["cpf"] = "CPF inválido (dígitos verificadores)"

    cargo = data.get("cargo", "")
    if cargo not in ("aluno", "professor", "monitor", "admin"):
        errs["cargo"] = "Valores: aluno | professor | monitor | admin"

    turma = data.get("turma", "")
    if cargo in ("aluno", "monitor") and not turma:
        errs["turma"] = "Obrigatório para aluno e monitor"

    if errs:
        return jsonify({"ok": False, "errors": errs}), 422

    cpf_norm = normalize_cpf(cpf)

    # Verifica duplicidade de e-mail e CPF antes de gerar o username,
    # já que o AD não impede CPFs repetidos por conta própria.
    try:
        for u in all_usernames():
            f = user_fields(u)
            if not f:
                continue
            if f.get("mail", "").strip().lower() == email.lower():
                return jsonify({
                    "ok": False,
                    "errors": {"email": "Já existe uma conta com este e-mail"}
                }), 409
            meta = parse_description(f.get("description", ""))
            if meta.get("cpf") == cpf_norm:
                return jsonify({
                    "ok": False,
                    "errors": {"cpf": "Já existe uma conta com este CPF"}
                }), 409
    except RuntimeError:
        logging.exception("Falha ao verificar duplicidade antes do cadastro")
        return jsonify({
            "ok": False,
            "error": "Não foi possível verificar duplicidade no momento"
        }), 500

    try:
        username = gen_username(nome)
        ou = ou_for_cargo(cargo)
        email_ad = f"{username}@ad.coude.com.br"
        initial_password = f"Coude@{cpf_norm}!"

        # --must-change-at-next-login vai direto na criação: chamar
        # 'user setpassword' depois, sem --newpassword, exige um prompt
        # interativo que não existe neste contexto (subprocess sem TTY) e
        # sempre falhava, revertendo o cadastro. Ver documentação técnica.
        rc, _, err = samba(
            "user",
            "create",
            username,
            initial_password,
            "--given-name",
            nome.split()[0],
            "--surname",
            " ".join(nome.split()[1:]),
            "--mail-address",
            email_ad,
            "--use-username-as-cn",
            "--must-change-at-next-login",
            "--description",
            build_description(cpf)
        )

        if rc != 0:
            logging.error(
                "Falha ao criar usuário %s: %s",
                username,
                err.strip()
            )
            return jsonify({
                "ok": False,
                "error": "Não foi possível criar o usuário no Active Directory"
            }), 500

        rc, _, err = samba("user", "move", username, ou)
        if rc != 0:
            samba("user", "delete", username)
            return jsonify({
                "ok": False,
                "error": "Não foi possível mover o usuário para a OU correta"
            }), 500

        rc, _, err = samba(
            "group",
            "addmembers",
            group_for_cargo(cargo),
            username
        )
        if rc != 0:
            samba("user", "delete", username)
            return jsonify({
                "ok": False,
                "error": "Não foi possível associar o grupo de cargo"
            }), 500

        if turma:
            rc, _, err = samba(
                "group",
                "addmembers",
                turma,
                username
            )
            if rc != 0:
                samba("user", "delete", username)
                return jsonify({
                    "ok": False,
                    "error": "Não foi possível associar a turma"
                }), 500

        subprocess.run(
            [
                "/usr/local/bin/coude-create-user-dir.sh",
                username,
                cargo
            ],
            check=False
        )

        if turma and cargo in ("aluno", "monitor"):
            subprocess.run(
                [
                    "/usr/local/bin/coude-create-aluno-dir.sh",
                    username,
                    turma
                ],
                check=False
            )

        resp = {
            "ok": True,
            "username": username,
            "email_ad": email_ad,
            "pasta": f"{SAMBA_DATA}/users/{username}",
            "grupos": (
                [group_for_cargo(cargo)] +
                ([turma] if turma else [])
            ),
            "must_change_password": True
        }

        if id_ext:
            IDEMPOTENCY[id_ext] = resp

        logging.info(
            "Usuário criado: %s cargo=%s turma=%s",
            username,
            cargo,
            turma
        )

        return jsonify(resp), 201

    except ValueError as exc:
        return jsonify({
            "ok": False,
            "error": str(exc)
        }), 400
    except Exception:
        logging.exception("Erro inesperado ao criar usuário")
        return jsonify({
            "ok": False,
            "error": "Erro interno"
        }), 500


@app.route("/api/v1/usuarios/remover", methods=["POST"])
@require_auth
def remover():
    data     = request.get_json(force=True) or {}
    username = data.get("username", "")
    if not username:
        return jsonify({"ok": False, "error": "Campo 'username' obrigatório"}), 422
    log_op("/usuarios/remover", f"user={username}")

    rc, _, err = samba("user", "disable", username)
    if rc != 0:
        return jsonify({"ok": False, "error": err.strip()}), 500

    samba("user", "move", username, f"OU=Deletados,{DC_SUFFIX}")
    logging.info(f"Soft delete: {username}")
    return jsonify({"ok": True, "username": username, "status": "disabled"})


@app.route("/api/v1/usuarios/restaurar", methods=["POST"])
@require_auth
def restaurar():
    data     = request.get_json(force=True) or {}
    username = data.get("username", "")
    cargo    = data.get("cargo", "aluno")
    if not username:
        return jsonify({"ok": False, "error": "Campo 'username' obrigatório"}), 422
    log_op("/usuarios/restaurar", f"user={username}")

    rc, _, err = samba("user", "enable", username)
    if rc != 0:
        return jsonify({"ok": False, "error": err.strip()}), 500

    samba("user", "move", username, ou_for_cargo(cargo))
    logging.info(f"Restaurado: {username}")
    return jsonify({"ok": True, "username": username, "status": "enabled"})


@app.route("/api/v1/usuarios/<username>", methods=["GET"])
@require_auth
def consultar(username):
    log_op(f"/usuarios/{username}")
    rc, out, _ = samba("user", "show", username)
    if rc != 0:
        return jsonify({"ok": False, "error": "Usuário não encontrado"}), 404

    fields = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip()

    uac     = fields.get("userAccountControl", "")
    enabled = "66050" not in uac and "514" not in uac

    return jsonify({
        "ok":          True,
        "username":    username,
        "displayName": fields.get("displayName", ""),
        "email":       fields.get("mail", ""),
        "enabled":     enabled,
        "dn":          fields.get("dn", "")
    })


@app.route("/api/v1/usuarios/<username>/turma", methods=["PUT"])
@require_auth
def troca_turma(username):
    data  = request.get_json(force=True) or {}
    nova  = data.get("turma_nova", "")
    velha = data.get("turma_anterior", "")
    if not nova:
        return jsonify({"ok": False, "error": "Campo 'turma_nova' obrigatório"}), 422
    log_op(f"/usuarios/{username}/turma", f"nova={nova}")

    if velha:
        samba("group", "removemembers", velha, username)

    rc, _, err = samba("group", "addmembers", nova, username)
    if rc != 0:
        return jsonify({"ok": False, "error": err.strip()}), 500

    logging.info(f"Troca de turma: {username} {velha} → {nova}")
    return jsonify({"ok": True, "username": username, "turma": nova})


@app.route("/api/v1/turmas/criar", methods=["POST"])
@require_auth
def criar_turma():
    data = request.get_json(force=True) or {}
    nome = data.get("nome", "")
    if not re.match(r'^turma_[a-z0-9_]+$', nome):
        return jsonify({
            "ok": False,
            "error": "Nome inválido. Formato: turma_<slug_minusculo>"
        }), 422
    log_op("/turmas/criar", f"turma={nome}")

    samba("group", "add", nome)
    subprocess.run(
        ["/usr/local/bin/coude-create-turma-dir.sh", nome],
        check=False
    )
    logging.info(f"Turma criada: {nome}")
    return jsonify({"ok": True, "turma": nome}), 201


@app.route("/api/v1/turmas/<nome>", methods=["DELETE"])
@require_auth
def arquivar_turma(nome):
    import shutil, time as t
    log_op(f"/turmas/{nome}")
    src = f"/srv/samba/turmas/{nome}"
    dst = f"/srv/samba/arquivo_morto/{nome}_{int(t.time())}"
    if os.path.isdir(src):
        shutil.move(src, dst)
    samba("group", "delete", nome)
    logging.info(f"Turma arquivada: {nome} → {dst}")
    return jsonify({"ok": True, "turma": nome, "status": "archived"})


@app.route("/api/v1/turmas", methods=["GET"])
@require_auth
def listar_turmas():
    log_op("/turmas")
    try:
        turmas = all_turmas()
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500
    return jsonify({"ok": True, "total": len(turmas), "turmas": turmas})


@app.route("/api/v1/turmas/<nome>/membros", methods=["GET"])
@require_auth
def membros_turma(nome):
    log_op(f"/turmas/{nome}/membros")
    membros = group_members(nome)
    if membros is None:
        return jsonify({"ok": False, "error": "Turma não encontrada"}), 404
    return jsonify({
        "ok": True,
        "turma": nome,
        "total_membros": len(membros),
        "membros": membros
    })


@app.route("/api/v1/usuarios", methods=["GET"])
@require_auth
def listar_usuarios():
    cargo  = request.args.get("cargo")
    turma  = request.args.get("turma")
    status = request.args.get("status", "ativos")  # ativos | deletados | todos

    if cargo and cargo not in CARGOS:
        return jsonify({
            "ok": False,
            "error": f"cargo inválido. Valores: {', '.join(CARGOS)}"
        }), 422
    if status not in ("ativos", "deletados", "todos"):
        return jsonify({
            "ok": False,
            "error": "status inválido. Valores: ativos | deletados | todos"
        }), 422

    try:
        page = max(1, int(request.args.get("page", 1)))
        per_page = int(request.args.get("per_page", 50))
    except ValueError:
        return jsonify({"ok": False, "error": "page/per_page devem ser inteiros"}), 422
    per_page = max(1, min(per_page, 200))

    log_op("/usuarios", f"cargo={cargo} turma={turma} status={status} page={page}")

    try:
        if turma:
            usernames = group_members(turma)
            if usernames is None:
                return jsonify({"ok": False, "error": "Turma não encontrada"}), 404
        elif cargo:
            usernames = group_members(group_for_cargo(cargo)) or []
        else:
            usernames = all_usernames()
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500

    usernames = sorted(set(usernames))
    total_bruto = len(usernames)
    start = (page - 1) * per_page
    pagina = usernames[start:start + per_page]

    usuarios = []
    for u in pagina:
        resumo = user_summary(u)
        if resumo is None:
            continue
        if status == "ativos" and (resumo["deletado"] or not resumo["enabled"]):
            continue
        if status == "deletados" and not resumo["deletado"]:
            continue
        usuarios.append(resumo)

    return jsonify({
        "ok": True,
        "page": page,
        "per_page": per_page,
        "total_geral": total_bruto,
        "total_pagina": len(usuarios),
        "usuarios": usuarios
    })


@app.route("/api/v1/usuarios/disponibilidade", methods=["GET"])
@require_auth
def disponibilidade():
    email = request.args.get("email", "").strip().lower()
    cpf   = request.args.get("cpf", "").strip()
    if not email and not cpf:
        return jsonify({
            "ok": False,
            "error": "Informe ao menos um parâmetro: email ou cpf"
        }), 422

    log_op("/usuarios/disponibilidade")
    cpf_norm = normalize_cpf(cpf) if cpf else ""

    resultado = {"ok": True}
    if email:
        resultado["email"] = {"valor": email, "disponivel": True}
    if cpf:
        resultado["cpf"] = {"valor": cpf_norm, "disponivel": True}

    try:
        for u in all_usernames():
            f = user_fields(u)
            if not f:
                continue
            if email and f.get("mail", "").strip().lower() == email:
                resultado["email"]["disponivel"] = False
                resultado["email"]["username"] = u
            if cpf_norm:
                meta = parse_description(f.get("description", ""))
                if meta.get("cpf") == cpf_norm:
                    resultado["cpf"]["disponivel"] = False
                    resultado["cpf"]["username"] = u
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500

    return jsonify(resultado)


def ldb_modify_attr(dn, attr, value):
    """Altera um atributo LDAP diretamente no sam.ldb local via ldbmodify.
    samba-tool não expõe um comando genérico de edição não-interativa de
    atributos (só 'user edit', que abre um editor de texto), então
    atributos fora do que 'user create' aceita (ex.: e-mail e nome de
    exibição em um usuário já existente) são alterados por este caminho.
    Executado localmente como root, sem necessidade de bind/senha."""
    ldif = f"dn: {dn}\nchangetype: modify\nreplace: {attr}\n{attr}: {value}\n"
    try:
        r = subprocess.run(
            ["ldbmodify", "-H", "/var/lib/samba/private/sam.ldb"],
            input=ldif, capture_output=True, text=True
        )
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 127, "", "ldbmodify não está instalado (pacote ldb-tools)"


@app.route("/api/v1/usuarios/<username>", methods=["PUT"])
@require_auth
def atualizar_usuario(username):
    fields = user_fields(username)
    if fields is None:
        return jsonify({"ok": False, "error": "Usuário não encontrado"}), 404

    data = request.get_json(force=True) or {}
    log_op(f"/usuarios/{username}", "update")

    novo_email = data.get("email", "").strip()
    novo_nome  = data.get("nome_completo", "").strip()
    novo_cargo = data.get("cargo", "").strip()

    if not novo_email and not novo_nome and not novo_cargo:
        return jsonify({
            "ok": False,
            "error": "Informe ao menos um campo: email, nome_completo ou cargo"
        }), 422

    if novo_email and not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", novo_email):
        return jsonify({"ok": False, "errors": {"email": "Formato inválido"}}), 422

    if novo_cargo and novo_cargo not in CARGOS:
        return jsonify({
            "ok": False,
            "errors": {"cargo": f"Valores: {', '.join(CARGOS)}"}
        }), 422

    alterado = {}
    dn = fields.get("dn", "")

    if novo_email:
        rc, _, err = ldb_modify_attr(dn, "mail", novo_email)
        if rc != 0:
            logging.error("Falha ao atualizar e-mail de %s: %s", username, err.strip())
            return jsonify({
                "ok": False,
                "error": "Não foi possível atualizar o e-mail: " + (err.strip() or "erro desconhecido")
            }), 500
        alterado["email"] = novo_email

    if novo_nome:
        rc, _, err = ldb_modify_attr(dn, "displayName", novo_nome)
        if rc != 0:
            logging.error("Falha ao atualizar nome de %s: %s", username, err.strip())
            return jsonify({
                "ok": False,
                "error": "Não foi possível atualizar o nome: " + (err.strip() or "erro desconhecido")
            }), 500
        alterado["nome_completo"] = novo_nome

    if novo_cargo:
        cargo_atual = None
        for c in CARGOS:
            m = group_members(group_for_cargo(c)) or []
            if username in m:
                cargo_atual = c
                break
        if cargo_atual and cargo_atual != novo_cargo:
            samba("group", "removemembers", group_for_cargo(cargo_atual), username)
        rc, _, err = samba("group", "addmembers", group_for_cargo(novo_cargo), username)
        if rc != 0:
            return jsonify({"ok": False, "error": err.strip()}), 500
        rc, _, err = samba("user", "move", username, ou_for_cargo(novo_cargo))
        if rc != 0:
            return jsonify({"ok": False, "error": err.strip()}), 500
        alterado["cargo"] = novo_cargo

    logging.info(f"Usuário atualizado: {username} campos={list(alterado.keys())}")
    return jsonify({"ok": True, "username": username, "alterado": alterado})


@app.route("/api/v1/usuarios/<username>/senha", methods=["POST"])
@require_auth
def resetar_senha(username):
    fields = user_fields(username)
    if fields is None:
        return jsonify({"ok": False, "error": "Usuário não encontrado"}), 404

    data = request.get_json(silent=True) or {}
    nova_senha = data.get("senha", "").strip()
    if nova_senha and len(nova_senha) < 8:
        return jsonify({
            "ok": False,
            "errors": {"senha": "Mínimo 8 caracteres"}
        }), 422
    if not nova_senha:
        nova_senha = f"Coude@{secrets.token_hex(4)}!"

    log_op(f"/usuarios/{username}/senha")

    rc, _, err = samba(
        "user", "setpassword", username,
        "--newpassword", nova_senha,
        "--must-change-at-next-login"
    )
    if rc != 0:
        logging.error("Falha ao redefinir senha de %s: %s", username, err.strip())
        return jsonify({"ok": False, "error": err.strip() or "Falha ao redefinir senha"}), 500

    logging.info(f"Senha redefinida (admin/API): {username}")
    return jsonify({
        "ok": True,
        "username": username,
        "senha_temporaria": nova_senha,
        "must_change_password": True
    })


@app.route("/api/v1/usuarios/<username>", methods=["DELETE"])
@require_auth
def excluir_usuario_definitivo(username):
    """Exclusão DEFINITIVA (fora do fluxo normal de soft delete/purge).
    Requer ?confirmar=true. Use POST /usuarios/remover para o fluxo padrão
    (soft delete + purge automático após 30 dias)."""
    if user_fields(username) is None:
        return jsonify({"ok": False, "error": "Usuário não encontrado"}), 404

    if request.args.get("confirmar") != "true":
        return jsonify({
            "ok": False,
            "error": "Confirmação obrigatória: adicione ?confirmar=true. "
                     "Prefira POST /usuarios/remover para exclusão reversível."
        }), 422

    log_op(f"/usuarios/{username}", "hard-delete")

    import shutil, time as t
    userdir = f"{SAMBA_DATA}/users/{username}"
    if os.path.isdir(userdir):
        archive = f"{SAMBA_DATA}/arquivo_morto/{username}_{int(t.time())}"
        try:
            shutil.move(userdir, archive)
        except OSError:
            logging.exception("Falha ao arquivar pasta de %s antes da exclusão", username)

    rc, _, err = samba("user", "delete", username)
    if rc != 0:
        return jsonify({"ok": False, "error": err.strip()}), 500

    logging.warning(f"Exclusão DEFINITIVA: {username}")
    return jsonify({"ok": True, "username": username, "status": "deleted_permanently"})


@app.route("/api/v1/estatisticas", methods=["GET"])
@require_auth
def estatisticas():
    log_op("/estatisticas")
    try:
        turmas = all_turmas()
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500

    por_cargo = {}
    for cargo in CARGOS:
        membros = group_members(group_for_cargo(cargo))
        por_cargo[cargo] = len(membros) if membros else 0

    por_turma = {}
    for t in turmas:
        membros = group_members(t)
        por_turma[t] = len(membros) if membros else 0

    return jsonify({
        "ok": True,
        "version": API_VERSION,
        "total_turmas": len(turmas),
        "usuarios_por_cargo": por_cargo,
        "usuarios_por_turma": por_turma,
        "total_usuarios_ativos": sum(por_cargo.values())
    })


# =============================================================================
if __name__ == "__main__":
    app.run(host=SERVER_IP, port=API_PORT)
PYEOF

chown root:root "$APP_FILE"
chmod 644 "$APP_FILE"
log "Novo app.py instalado em $APP_FILE"

info "Reiniciando serviço coude-api ..."
systemctl restart coude-api
sleep 2

if systemctl is-active --quiet coude-api; then
    log "Serviço coude-api ativo"
else
    warn "Serviço coude-api não subiu. Restaurando backup automaticamente ..."
    cp "$BACKUP" "$APP_FILE"
    systemctl restart coude-api
    fatal "Atualização revertida. Veja: journalctl -u coude-api -n 50 --no-pager"
fi

info "Testando endpoint de saúde ..."
if curl -sf "http://$SERVER_IP:$API_PORT/api/v1/health" -o /tmp/coude-health-check.json; then
    log "API respondendo em http://$SERVER_IP:$API_PORT/api/v1/health"
    cat /tmp/coude-health-check.json
    echo
else
    warn "API não respondeu no health check. Confira: journalctl -u coude-api -n 50 --no-pager"
fi

echo
log "Atualização concluída."
info "Endpoints novos disponíveis — veja coude-documentacao-tecnica.md para o contrato completo:"
echo "  GET    /api/v1/usuarios"
echo "  GET    /api/v1/usuarios/disponibilidade"
echo "  PUT    /api/v1/usuarios/<username>"
echo "  POST   /api/v1/usuarios/<username>/senha"
echo "  DELETE /api/v1/usuarios/<username>?confirmar=true"
echo "  GET    /api/v1/turmas"
echo "  GET    /api/v1/turmas/<nome>/membros"
echo "  GET    /api/v1/estatisticas"
