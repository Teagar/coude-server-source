#!/usr/bin/env bash
# =============================================================================
# COUDE — Infraestrutura v2.0 — Script de Instalação Completo
# Debian 12 | Samba AD | Samba File Server | Flask API
# =============================================================================
# Uso: sudo bash coude-setup.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n${RED}[✗] ERRO na linha $LINENO. Verifique o log acima.${NC}" >&2' ERR

# Garante que /sbin e /usr/sbin estejam no PATH (necessário para useradd,
# quotaon, quotacheck, etc. caso o script seja executado via 'su' sem '-'
# ou em sessões com PATH restrito)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =============================================================================
# CONFIGURAÇÕES — Edite esta seção antes de executar
# =============================================================================

DOMAIN="ad.coude.com.br"
REALM="AD.COUDE.COM.BR"
NETBIOS="COUDE"
DC_HOSTNAME="srv1"
SERVER_FQDN="srv1.ad.coude.com.br"
SERVER_IP="192.168.1.10"
GATEWAY="192.168.1.1"
LAN_CIDR="192.168.1.0/24"   # rede local — usado na regra de firewall da API
NET_IFACE="enp0s3"          # ajuste para sua interface (ip link para listar)

SAMBA_DATA="/srv/samba"
BACKUP_DEST="/mnt/backup"
LOG_DIR="/var/log/coude"
API_DIR="/opt/coude-api"
CERT_DIR="/etc/coude"
API_PORT="8080"

ADMIN_USER="admin.coude"    # usuário local de administração do Linux
ADMIN_SSH_KEY=""            # Cole aqui sua chave pública SSH (ssh-ed25519 AAA...)
                            # Deixe vazio para manter senha (configure depois)

# =============================================================================
# CORES E HELPERS
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
info()    { echo -e "${CYAN}[i]${NC} $*"; }
fatal()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[[ $EUID -ne 0 ]] && fatal "Execute como root: sudo bash $0"

# Verificar Debian 12
if ! grep -q "bookworm\|12" /etc/os-release 2>/dev/null; then
    warn "Sistema não detectado como Debian 12. Prosseguindo mesmo assim..."
fi

echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║      COUDE Infraestrutura v2.0 — Instalação     ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}\n"
info "Domínio : $REALM"
info "Servidor: $SERVER_FQDN ($SERVER_IP)"
info "API     : http://$SERVER_IP:$API_PORT/api/v1"
echo ""
read -rp "Confirmar instalação? [s/N] " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && fatal "Instalação cancelada."

# =============================================================================
# SEÇÃO 1 — HOSTNAME E REDE
# =============================================================================
section "1/19 · Hostname e Rede"

hostnamectl set-hostname "$SERVER_FQDN"
log "Hostname definido: $SERVER_FQDN"

# /etc/hosts — NUNCA 127.x para o DC
cat > /etc/hosts <<EOF
127.0.0.1   localhost
$SERVER_IP  $SERVER_FQDN $DC_HOSTNAME

# IPv6
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
log "/etc/hosts configurado (IP real, sem 127.x para o DC)"

# IP fixo via interfaces
cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet static
  address   $SERVER_IP
  netmask   255.255.255.0
  gateway   $GATEWAY
  dns-nameservers 127.0.0.1
  dns-search $DOMAIN
EOF
log "IP fixo configurado em $NET_IFACE"

# =============================================================================
# SEÇÃO 2 — PACOTES
# =============================================================================
section "2/19 · Instalação de Pacotes"

export DEBIAN_FRONTEND=noninteractive

# Pré-configurar krb5-user para evitar prompt interativo
debconf-set-selections <<DEBCONF
krb5-config krb5-config/default_realm     string $REALM
krb5-config krb5-config/kerberos_servers  string $SERVER_FQDN
krb5-config krb5-config/admin_server      string $SERVER_FQDN
DEBCONF

apt-get update -qq

apt-get install -y \
    samba krb5-user winbind smbclient dnsutils \
    acl attr python3-samba \
    quota \
    ufw \
    rsyslog \
    python3 python3-pip python3-venv \
    openssl rsync curl wget jq \
    htop net-tools lsof vim \
    2>/dev/null

log "Todos os pacotes instalados"

# =============================================================================
# SEÇÃO 3 — ESTRUTURA DE DIRETÓRIOS
# =============================================================================
section "3/19 · Estrutura de Diretórios"

mkdir -p "$SAMBA_DATA"/{users,turmas,professores,monitores,arquivo_morto}
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DEST"/{samba,ad}
mkdir -p "$CERT_DIR"
mkdir -p /usr/local/bin

# Habilitar ACL no ponto de montagem de /srv
SAMBA_MOUNT=$(df "$SAMBA_DATA" | awk 'NR==2{print $6}')
mount -o remount,acl,usrquota,grpquota "$SAMBA_MOUNT" 2>/dev/null \
    || warn "Remontagem com ACL/quota pendente. Adicione 'acl,usrquota,grpquota' ao fstab e reinicie."

log "Estrutura /srv/samba criada com ACL"

# =============================================================================
# SEÇÃO 4 — SAMBA AD: PROVISION
# =============================================================================
section "4/19 · Samba AD — Provision"

# Parar e desativar serviços conflitantes
for SVC in smbd nmbd winbind; do
    systemctl stop "$SVC"    2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
done

# Remover smb.conf existente e bancos de dados legados
[[ -f /etc/samba/smb.conf ]] && mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
find /var/lib/samba -name "*.ldb" -o -name "*.tdb" 2>/dev/null \
    | xargs rm -f 2>/dev/null || true

# Gerar senha de admin (complexa)
if [[ -z "${SAMBA_ADMIN_PASS:-}" ]]; then
    SAMBA_ADMIN_PASS="Coude@$(openssl rand -base64 8 | tr -dc 'A-Za-z0-9' | head -c10)!"
fi

# Salvar senha com permissão restrita
echo "$SAMBA_ADMIN_PASS" > "$CERT_DIR/admin_password.txt"
chmod 400 "$CERT_DIR/admin_password.txt"

warn "Senha do Administrador AD: $SAMBA_ADMIN_PASS"
warn "Salva em $CERT_DIR/admin_password.txt — guarde em local seguro!"

info "Provisionando domínio (pode levar ~30s)..."

samba-tool domain provision \
    --use-rfc2307 \
    --realm="$REALM" \
    --domain="$NETBIOS" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass="$SAMBA_ADMIN_PASS" \
    2>&1 | tee -a "$LOG_DIR/provision.log"

log "Samba AD provisionado"

# =============================================================================
# SEÇÃO 5 — SAMBA AD: SERVIÇO
# =============================================================================
section "5/19 · Samba AD — Serviço"

systemctl unmask samba-ad-dc
systemctl enable --now samba-ad-dc
sleep 4
log "samba-ad-dc habilitado e iniciado"

# Proteger resolv.conf contra sobrescrita
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
search $DOMAIN
EOF
chattr +i /etc/resolv.conf
log "resolv.conf protegido com chattr +i"

# =============================================================================
# SEÇÃO 6 — SMB.CONF
# =============================================================================
section "6/19 · smb.conf"

cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup               = $NETBIOS
    realm                   = $REALM
    server role             = active directory domain controller
    dns forwarder           = $GATEWAY
    idmap_ldb:use rfc2307   = yes

    # ACL
    vfs objects             = dfs_samba4 acl_xattr
    map acl inherit         = yes
    store dos attributes    = yes

    # Log
    log file                = /var/log/samba/log.%m
    max log size            = 50
    logging                 = syslog@1

[netlogon]
    path      = /var/lib/samba/sysvol/$DOMAIN/scripts
    read only = No

[sysvol]
    path      = /var/lib/samba/sysvol
    read only = No

[users]
    path          = $SAMBA_DATA/users
    browseable    = No
    valid users   = @alunos @administradores @professores @monitores
    create mask   = 0600
    directory mask = 0700
    vfs objects   = dfs_samba4 acl_xattr

[turmas]
    path          = $SAMBA_DATA/turmas
    browseable    = Yes
    valid users   = @alunos @professores @monitores @administradores
    vfs objects   = dfs_samba4 acl_xattr full_audit
    full_audit:success  = unlink rmdir rename write
    full_audit:failure  = none
    full_audit:facility = LOCAL7
    full_audit:priority = notice
    full_audit:prefix   = %u|%I|%m|%S

[professores]
    path        = $SAMBA_DATA/professores
    browseable  = No
    valid users = @professores @administradores
    vfs objects = dfs_samba4 acl_xattr

[monitores]
    path        = $SAMBA_DATA/monitores
    browseable  = No
    valid users = @monitores @administradores
    vfs objects = dfs_samba4 acl_xattr
EOF

systemctl restart samba-ad-dc
sleep 3
log "smb.conf criado e Samba reiniciado"

# =============================================================================
# SEÇÃO 7 — OUs E GRUPOS NO AD
# =============================================================================
section "7/19 · OUs e Grupos no AD"

DC_SUFFIX="DC=ad,DC=coude,DC=com,DC=br"

# Criar OUs
declare -a OUS=(
    "OU=Usuarios,$DC_SUFFIX"
    "OU=Alunos,OU=Usuarios,$DC_SUFFIX"
    "OU=Professores,OU=Usuarios,$DC_SUFFIX"
    "OU=Monitores,OU=Usuarios,$DC_SUFFIX"
    "OU=Administradores,OU=Usuarios,$DC_SUFFIX"
    "OU=Turmas,$DC_SUFFIX"
    "OU=Computadores,$DC_SUFFIX"
    "OU=Deletados,$DC_SUFFIX"
)
for OU in "${OUS[@]}"; do
    samba-tool ou create "$OU" 2>/dev/null \
        && log "OU criada: $OU" \
        || info "OU já existe: $OU"
done

# Criar grupos de cargo
for GROUP in alunos professores monitores administradores; do
    samba-tool group add "$GROUP" 2>/dev/null \
        && log "Grupo criado: $GROUP" \
        || info "Grupo já existe: $GROUP"
done

log "OUs e grupos base prontos"

# =============================================================================
# SEÇÃO 8 — SCRIPTS DE GERENCIAMENTO
# =============================================================================
section "8/19 · Scripts de Gerenciamento"

# ── 8.1 Gerador de username (Python) ─────────────────────────────────────────
cat > /usr/local/bin/coude-gen-username.py <<'PYEOF'
#!/usr/bin/env python3
"""
Gerador de usernames COUDE — Seção 16 do documento de infraestrutura.
Uso: python3 coude-gen-username.py "Nome Completo"
"""
import sys, unicodedata, subprocess

IGNORE = {"de","da","do","dos","das","e","di","du","van","von"}

def normalize(s):
    """Remove acentos e converte para minúsculas ASCII."""
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(c for c in s if unicodedata.category(c) != "Mn" and c.isalpha())

def fragments(word, min_len=3, max_len=5):
    """Gera fragmentos prefixo de tamanho min_len..max_len."""
    return [word[:l] for l in range(min_len, min(max_len + 1, len(word) + 1))]

def username_exists(u):
    r = subprocess.run(
        ["samba-tool", "user", "show", u],
        capture_output=True, text=True
    )
    return r.returncode == 0

if len(sys.argv) < 2:
    print("Uso: coude-gen-username.py 'Nome Completo'", file=sys.stderr)
    sys.exit(1)

full = sys.argv[1]
parts = [p for p in full.split() if normalize(p) not in IGNORE and normalize(p)]

if len(parts) < 2:
    print("Erro: nome precisa de pelo menos 2 palavras significativas.", file=sys.stderr)
    sys.exit(1)

first = normalize(parts[0])
last  = normalize(parts[-1])

name_frags    = fragments(first, 3, 5)
surname_frags = fragments(last,  3, 5)

# Gera ~24 candidatos: nome+sobrenome e sobrenome+nome
candidates = []
seen = set()
for nf in name_frags:
    for sf in surname_frags:
        for u in [(nf + sf)[:8], (sf + nf)[:8]]:
            if 4 <= len(u) <= 8 and u not in seen:
                seen.add(u)
                candidates.append(u)

for u in candidates:
    if not username_exists(u):
        print(u)
        sys.exit(0)

print("Erro: sem candidatos disponíveis para este nome.", file=sys.stderr)
sys.exit(1)
PYEOF

cat > /usr/local/bin/coude-gen-username.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-gen-username.sh "Nome Completo"
exec python3 /usr/local/bin/coude-gen-username.py "$@"
EOF

# ── 8.2 Criar pasta pessoal do usuário ───────────────────────────────────────
cat > /usr/local/bin/coude-create-user-dir.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-create-user-dir.sh <username> <cargo>
set -euo pipefail

USERNAME="$1"
CARGO="$2"
SAMBA_DATA="/srv/samba"
USERDIR="$SAMBA_DATA/users/$USERNAME"

mkdir -p "$USERDIR"/{Documents,Desktop,Downloads}

# ACL: dono tem rwx, Domain Admins também
setfacl -R -m "u:${USERNAME}:rwx" "$USERDIR"
setfacl -R -m "g:Domain Admins:rwx" "$USERDIR"
setfacl -R -d -m "u:${USERNAME}:rwx" "$USERDIR"
setfacl -R -d -m "g:Domain Admins:rwx" "$USERDIR"

# Outros: sem acesso
chmod o-rwx "$USERDIR"

# Quota: 5 GB soft / 6 GB hard
setquota -u "$USERNAME" 5242880 6291456 0 0 /srv 2>/dev/null \
    || echo "[!] Quota não aplicada (verifique se quotas estão ativas em /srv)"

echo "[✓] Pasta pessoal criada: $USERDIR"
EOF

# ── 8.3 Criar pasta de turma ──────────────────────────────────────────────────
cat > /usr/local/bin/coude-create-turma-dir.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-create-turma-dir.sh <nome_turma>
# Ex.: coude-create-turma-dir.sh turma_fullstack_001
set -euo pipefail

TURMA="$1"
BASE="/srv/samba/turmas/$TURMA"

mkdir -p "$BASE/_geral"/{Materiais,Avisos}
mkdir -p "$BASE/alunos"

# Remover permissões padrão
chmod -R o-rwx "$BASE"

# _geral: professor rwx | monitor r-x | alunos da turma r-x
setfacl -R -m "g:professores:rwx"   "$BASE/_geral"
setfacl -R -m "g:monitores:r-x"     "$BASE/_geral"
setfacl -R -m "g:alunos:r-x"        "$BASE/_geral"
setfacl -R -m "g:${TURMA}:r-x"     "$BASE/_geral"

# Herança para novos arquivos
setfacl -R -d -m "g:professores:rwx"  "$BASE/_geral"
setfacl -R -d -m "g:monitores:r-x"    "$BASE/_geral"
setfacl -R -d -m "g:alunos:r-x"       "$BASE/_geral"
setfacl -R -d -m "g:${TURMA}:r-x"    "$BASE/_geral"

echo "[✓] Turma criada: $BASE"
EOF

# ── 8.4 Criar pasta do aluno dentro da turma ─────────────────────────────────
cat > /usr/local/bin/coude-create-aluno-dir.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-create-aluno-dir.sh <username> <turma>
set -euo pipefail

USERNAME="$1"
TURMA="$2"
BASE="/srv/samba/turmas/$TURMA/alunos/$USERNAME"

mkdir -p "$BASE"/{Projetos,Entregas}
chmod -R o-rwx "$BASE"

# Aluno: rwx | Professor: rwx | Monitor: r-x | outros alunos: sem acesso
setfacl -R -m "u:${USERNAME}:rwx"   "$BASE"
setfacl -R -m "g:professores:rwx"   "$BASE"
setfacl -R -m "g:monitores:r-x"     "$BASE"

setfacl -R -d -m "u:${USERNAME}:rwx"  "$BASE"
setfacl -R -d -m "g:professores:rwx"  "$BASE"
setfacl -R -d -m "g:monitores:r-x"    "$BASE"

echo "[✓] Pasta de aluno criada: $BASE"
EOF

# ── 8.5 Soft Delete ──────────────────────────────────────────────────────────
cat > /usr/local/bin/coude-soft-delete.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-soft-delete.sh <username>
set -euo pipefail

USERNAME="$1"
DC_SUFFIX="DC=ad,DC=coude,DC=com,DC=br"
LOG="/var/log/coude/audit.log"

samba-tool user disable "$USERNAME"
samba-tool user move "$USERNAME" "OU=Deletados,$DC_SUFFIX"
samba-tool user setexpiry "$USERNAME" --days=30 2>/dev/null || true

echo "$(date '+%Y-%m-%d %H:%M:%S') soft_delete user=$USERNAME" >> "$LOG"
echo "[✓] $USERNAME desativado e movido para OU=Deletados (purge em 30 dias)"
EOF

# ── 8.6 Restaurar usuário ────────────────────────────────────────────────────
cat > /usr/local/bin/coude-restore-user.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-restore-user.sh <username> <cargo>
# cargo: aluno | professor | monitor | admin
set -euo pipefail

USERNAME="$1"
CARGO="${2:-aluno}"
DC_SUFFIX="DC=ad,DC=coude,DC=com,DC=br"
LOG="/var/log/coude/audit.log"

declare -A OU_MAP
OU_MAP["aluno"]="OU=Alunos,OU=Usuarios,$DC_SUFFIX"
OU_MAP["professor"]="OU=Professores,OU=Usuarios,$DC_SUFFIX"
OU_MAP["monitor"]="OU=Monitores,OU=Usuarios,$DC_SUFFIX"
OU_MAP["admin"]="OU=Administradores,OU=Usuarios,$DC_SUFFIX"

TARGET_OU="${OU_MAP[$CARGO]:-${OU_MAP[aluno]}}"

samba-tool user enable "$USERNAME"
samba-tool user move "$USERNAME" "$TARGET_OU"

echo "$(date '+%Y-%m-%d %H:%M:%S') restore user=$USERNAME cargo=$CARGO" >> "$LOG"
echo "[✓] $USERNAME reativado → $TARGET_OU"
EOF

# ── 8.7 Purge de contas expiradas (cron diário) ──────────────────────────────
cat > /usr/local/bin/coude-purge-deleted.sh <<'EOF'
#!/usr/bin/env bash
# Executado pelo cron diariamente às 02:00
set -euo pipefail

DC_SUFFIX="DC=ad,DC=coude,DC=com,DC=br"
SAMBA_DATA="/srv/samba"
ARCHIVE="$SAMBA_DATA/arquivo_morto"
LOG="/var/log/coude/purge.log"
CUTOFF_EPOCH=$(date -d "30 days ago" +%s)

mkdir -p "$ARCHIVE"
exec >> "$LOG" 2>&1
echo "=== Purge iniciado: $(date) ==="

# Listar todos os usuários e verificar se estão na OU=Deletados
samba-tool user list 2>/dev/null | while read -r USER; do
    DN=$(samba-tool user show "$USER" 2>/dev/null \
        | grep -i "^dn:" | awk '{$1=""; print $0}' | xargs || true)

    [[ -z "$DN" ]] && continue
    echo "$DN" | grep -qi "OU=Deletados" || continue

    # Pegar whenChanged e converter para epoch
    WHEN_RAW=$(samba-tool user show "$USER" 2>/dev/null \
        | grep -i "whenChanged:" | awk '{print $2}' || echo "")
    [[ -z "$WHEN_RAW" ]] && continue

    # whenChanged formato: YYYYMMDDHHmmss.0Z → extrair data
    WHEN_DATE=$(echo "$WHEN_RAW" | cut -c1-8)
    WHEN_EPOCH=$(date -d "${WHEN_DATE:0:4}-${WHEN_DATE:4:2}-${WHEN_DATE:6:2}" +%s 2>/dev/null || echo "0")

    if [[ "$WHEN_EPOCH" -le "$CUTOFF_EPOCH" ]]; then
        STAMP=$(date +%Y%m%d_%H%M%S)
        echo "Purgando: $USER (whenChanged: $WHEN_DATE)"

        USERDIR="$SAMBA_DATA/users/$USER"
        if [[ -d "$USERDIR" ]]; then
            mv "$USERDIR" "$ARCHIVE/${USER}_${STAMP}"
            echo "  Pasta movida para arquivo_morto"
        fi

        samba-tool user delete "$USER" 2>/dev/null \
            && echo "  Conta deletada do AD" \
            || echo "  Falha ao deletar conta do AD"
    fi
done

echo "=== Purge concluído: $(date) ==="
EOF

# ── 8.8 Criar turma completa (AD + diretório) ────────────────────────────────
cat > /usr/local/bin/coude-new-turma.sh <<'EOF'
#!/usr/bin/env bash
# Uso: coude-new-turma.sh <nome_turma>
# Ex.: coude-new-turma.sh turma_fullstack_001
set -euo pipefail

TURMA="$1"

# Validar formato
if ! echo "$TURMA" | grep -qE '^turma_[a-z0-9_]+$'; then
    echo "Erro: nome deve ser turma_<slug>  ex: turma_fullstack_001"
    exit 1
fi

# Criar grupo no AD
samba-tool group add "$TURMA" 2>/dev/null || echo "[i] Grupo já existe"

# Criar estrutura de diretórios e ACLs
/usr/local/bin/coude-create-turma-dir.sh "$TURMA"

echo "[✓] Turma $TURMA criada no AD e no sistema de arquivos"
EOF

chmod +x /usr/local/bin/coude-*.sh /usr/local/bin/coude-gen-username.py
log "Todos os scripts de gerenciamento criados em /usr/local/bin/"

# =============================================================================
# SEÇÃO 9 — API FLASK
# =============================================================================
section "9/19 · API Flask v2"

mkdir -p "$API_DIR"
python3 -m venv "$API_DIR/venv"
"$API_DIR/venv/bin/pip" install --quiet flask gunicorn bcrypt

# Gerar chave de API (64 hex chars = 32 bytes)
API_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "$API_KEY" > "$CERT_DIR/api.key"
chmod 400 "$CERT_DIR/api.key"
log "Chave de API gerada (salva em $CERT_DIR/api.key)"

# Escrever o app Flask
cat > "$API_DIR/app.py" <<PYEOF
#!/usr/bin/env python3
"""
COUDE API v2 — Flask
Base URL: http://${SERVER_IP}:${API_PORT}/api/v1
Auth: header X-API-Key
"""
import os, subprocess, hashlib, hmac, time, re, logging
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
        "timestamp": datetime.utcnow().isoformat() + "Z"
    })


@app.route("/api/v1/usuarios/cadastrar", methods=["POST"])
@require_auth
def cadastrar():
    data = request.get_json(force=True) or {}
    log_op("/usuarios/cadastrar")

    # Idempotência por id_externo
    id_ext = data.get("metadata", {}).get("id_externo", "")
    if id_ext and id_ext in IDEMPOTENCY:
        return jsonify(IDEMPOTENCY[id_ext]), 200

    # ── Validações ────────────────────────────────────────────────────────
    errs = {}

    nome = data.get("nome_completo", "")
    if len(nome.split()) < 2:
        errs["nome_completo"] = "Mínimo 2 palavras"

    email = data.get("email", "")
    if not re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', email):
        errs["email"] = "Formato inválido (RFC 5321)"

    cpf = data.get("cpf", "")
    if not validate_cpf(cpf):
        errs["cpf"] = "CPF inválido (dígitos verificadores)"

    cargo = data.get("cargo", "")
    if cargo not in ("aluno", "professor", "monitor", "admin"):
        errs["cargo"] = "Valores: aluno | professor | monitor | admin"

    senha_hash = data.get("senha_hash", "")
    if not re.match(r'^\\\$2[abxy]?\\\$(1[2-9]|2[0-9]|3[01])\\\$', senha_hash):
        errs["senha_hash"] = "bcrypt custo >= 12 obrigatório"

    turma = data.get("turma", "")
    if cargo in ("aluno", "monitor") and not turma:
        errs["turma"] = "Obrigatório para aluno e monitor"

    if errs:
        return jsonify({"ok": False, "errors": errs}), 422

    # ── Criação ────────────────────────────────────────────────────────────
    try:
        username = gen_username(nome)
        ou       = ou_for_cargo(cargo)
        email_ad = f"{username}@ad.coude.com.br"

        # Criar conta no AD com senha aleatória (usuário troca no login)
        rc, out, err = samba(
            "user", "create", username,
            "--given-name",    nome.split()[0],
            "--surname",       " ".join(nome.split()[1:]),
            "--mail-address",  email_ad,
            "--use-username-as-cn",
            "--random-password"
        )
        if rc != 0:
            return jsonify({"ok": False, "error": err.strip()}), 500

        # Mover para OU correta
        samba("user", "move", username, ou)

        # Adicionar a grupos
        samba("group", "addmembers", group_for_cargo(cargo), username)
        if turma:
            samba("group", "addmembers", turma, username)

        # Criar pastas e ACLs
        subprocess.run(
            ["/usr/local/bin/coude-create-user-dir.sh", username, cargo],
            check=False
        )
        if turma and cargo in ("aluno", "monitor"):
            subprocess.run(
                ["/usr/local/bin/coude-create-aluno-dir.sh", username, turma],
                check=False
            )

        resp = {
            "ok":       True,
            "username": username,
            "email_ad": email_ad,
            "pasta":    f"{SAMBA_DATA}/users/{username}",
            "grupos":   [group_for_cargo(cargo)] + ([turma] if turma else [])
        }
        if id_ext:
            IDEMPOTENCY[id_ext] = resp

        logging.info(f"Usuário criado: {username} cargo={cargo} turma={turma}")
        return jsonify(resp), 201

    except ValueError as ve:
        return jsonify({"ok": False, "error": str(ve)}), 400
    except Exception as ex:
        logging.error(f"Erro ao criar usuário: {ex}")
        return jsonify({"ok": False, "error": "Erro interno"}), 500


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


# =============================================================================
if __name__ == "__main__":
    app.run(host=SERVER_IP, port=API_PORT)
PYEOF

log "API Flask criada em $API_DIR/app.py"

# =============================================================================
# SEÇÃO 10 — SYSTEMD: SERVIÇO DA API
# =============================================================================
section "10/19 · Serviço systemd da API"

cat > /etc/systemd/system/coude-api.service <<EOF
[Unit]
Description=COUDE API Flask v2
Documentation=https://github.com/coude/infra
After=network.target samba-ad-dc.service
Requires=samba-ad-dc.service

[Service]
Type=simple
User=root
WorkingDirectory=$API_DIR
ExecStart=$API_DIR/venv/bin/gunicorn \\
    --workers 2 \\
    --bind ${SERVER_IP}:${API_PORT} \\
    --access-logfile $LOG_DIR/api_access.log \\
    --error-logfile  $LOG_DIR/api_error.log \\
    --timeout 60 \\
    app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable coude-api
log "Serviço coude-api registrado (iniciará no próximo boot ou via: systemctl start coude-api)"

# =============================================================================
# SEÇÃO 11 — TLS AUTO-ASSINADO
# =============================================================================
section "11/19 · Certificado TLS"

openssl req -x509 -nodes -days 730 -newkey rsa:4096 \
    -keyout "$CERT_DIR/api.key.pem" \
    -out    "$CERT_DIR/api.crt.pem" \
    -subj   "/CN=$SERVER_FQDN/O=COUDE/C=BR" \
    2>/dev/null

chmod 400 "$CERT_DIR/api.key.pem"
chmod 444 "$CERT_DIR/api.crt.pem"
log "Certificado TLS gerado em $CERT_DIR/ (válido 2 anos)"
info "Para habilitar HTTPS, configure gunicorn com --certfile e --keyfile"

# =============================================================================
# SEÇÃO 12 — SSH HARDENING
# =============================================================================
section "12/19 · SSH Hardening"

# Criar usuário admin Linux
if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
    log "Usuário Linux '$ADMIN_USER' criado"
fi

# Adicionar chave SSH se configurada
if [[ -n "$ADMIN_SSH_KEY" ]]; then
    SSH_DIR="/home/$ADMIN_USER/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$ADMIN_SSH_KEY" > "$SSH_DIR/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    log "Chave SSH configurada para $ADMIN_USER"

    # Hardening sshd (só desabilita senha se tiver chave)
    cat > /etc/ssh/sshd_config.d/99-coude.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers $ADMIN_USER
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF
    systemctl restart sshd
    log "SSH: root desabilitado, somente chave pública, usuário=$ADMIN_USER"
else
    warn "ADMIN_SSH_KEY vazia — SSH hardening não aplicado (senha ainda permitida)"
    warn "Configure a variável ADMIN_SSH_KEY e re-execute, ou edite /etc/ssh/sshd_config.d/99-coude.conf"
fi

# =============================================================================
# SEÇÃO 13 — QUOTAS DE DISCO
# =============================================================================
section "13/19 · Quotas de Disco"

SRV_DEV=$(df /srv | awk 'NR==2{print $1}')
SRV_MOUNT=$(df /srv | awk 'NR==2{print $6}')

# Atualizar fstab se necessário
if ! grep "$SRV_MOUNT" /etc/fstab | grep -q "usrquota"; then
    cp /etc/fstab /etc/fstab.coude_bak
    # Adicionar opções de quota ao ponto de montagem de /srv
    sed -i "/${SRV_MOUNT//\//\\/}/s/defaults/defaults,usrquota,grpquota/" /etc/fstab 2>/dev/null \
        || warn "Adicione manualmente 'usrquota,grpquota' ao fstab em $SRV_MOUNT e reinicie"
    log "fstab atualizado com usrquota,grpquota para $SRV_MOUNT"
fi

# Tentar ativar quotas (pode precisar de reboot se fstab não foi remontado acima)
quotacheck -cum "$SRV_MOUNT" 2>/dev/null || true
quotaon   "$SRV_MOUNT" 2>/dev/null \
    && log "Quotas ativas em $SRV_MOUNT" \
    || warn "Quotas precisam de reboot. Execute após reiniciar: quotaon $SRV_MOUNT"

# =============================================================================
# SEÇÃO 14 — FIREWALL UFW
# =============================================================================
section "14/19 · Firewall UFW"

ufw --force disable
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp                                          comment 'SSH'
ufw allow 53                                              comment 'DNS (Samba)'
ufw allow 88                                              comment 'Kerberos'
ufw allow 389                                             comment 'LDAP'
ufw allow 636/tcp                                         comment 'LDAPS'
ufw allow 135/tcp                                         comment 'RPC Endpoint Mapper'
ufw allow 445/tcp                                         comment 'SMB'
ufw allow 49152:65535/tcp                                 comment 'RPC Dinâmico'
ufw allow 123/udp                                         comment 'NTP'
ufw allow from "$LAN_CIDR" to any port "$API_PORT"        comment 'API (somente LAN)'

ufw --force enable
log "UFW configurado e ativo"

# =============================================================================
# SEÇÃO 15 — RSYSLOG: AUDITORIA
# =============================================================================
section "15/19 · Auditoria (rsyslog)"

# Debian 12 não traz rsyslog por padrão (usa journald) — instalar se faltar
if ! command -v rsyslogd &>/dev/null; then
    info "rsyslog não encontrado, instalando..."
    apt-get install -y rsyslog 2>/dev/null
fi

mkdir -p /etc/rsyslog.d

cat > /etc/rsyslog.d/10-coude-audit.conf <<EOF
# COUDE — Auditoria de operações destrutivas no Samba (full_audit)
local7.notice    /var/log/coude/file_audit.log
& stop
EOF

systemctl enable rsyslog 2>/dev/null || true
systemctl restart rsyslog
log "rsyslog configurado: LOCAL7 → $LOG_DIR/file_audit.log"

# =============================================================================
# SEÇÃO 16 — BACKUP INCREMENTAL
# =============================================================================
section "16/19 · Backup Incremental"

cat > /usr/local/bin/coude-backup.sh <<EOF
#!/usr/bin/env bash
# COUDE — Backup incremental diário com link-dest (rsync)
# Retém 7 snapshots diários de /srv/samba e 7 do AD
set -euo pipefail

SAMBA_DATA="$SAMBA_DATA"
DEST="$BACKUP_DEST/samba"
AD_DEST="$BACKUP_DEST/ad"
LOG="$LOG_DIR/backup.log"
DATE=\$(date +%Y%m%d_%H%M%S)
RETENTION=7

exec >> "\$LOG" 2>&1
echo "=== Backup iniciado: \$(date) ==="

mkdir -p "\$DEST/\$DATE" "\$AD_DEST/\$DATE"

# ── Backup incremental de /srv/samba ─────────────────────────────────────────
if [[ -L "\$DEST/latest" ]]; then
    rsync -av --delete --link-dest="\$DEST/latest" \\
        "\$SAMBA_DATA/" "\$DEST/\$DATE/" \\
        && echo "[✓] Backup incremental OK" \\
        || echo "[✗] FALHA no backup rsync"
else
    rsync -av "\$SAMBA_DATA/" "\$DEST/\$DATE/" \\
        && echo "[✓] Backup inicial OK"
fi
ln -sfn "\$DEST/\$DATE" "\$DEST/latest"

# ── Backup online do AD ───────────────────────────────────────────────────────
ADMIN_PASS=\$(cat $CERT_DIR/admin_password.txt 2>/dev/null || echo "")
if [[ -n "\$ADMIN_PASS" ]]; then
    samba-tool domain backup online \\
        --targetdir="\$AD_DEST/\$DATE" \\
        -U "Administrator%\$ADMIN_PASS" \\
        2>&1 && echo "[✓] Backup AD OK" || echo "[✗] FALHA no backup AD"
else
    echo "[!] Senha do admin não encontrada — pulando backup do AD"
fi

# ── Purge de snapshots antigos ────────────────────────────────────────────────
find "\$DEST"    -maxdepth 1 -type d -name "20*" -mtime +\$RETENTION -exec rm -rf {} \\; 2>/dev/null || true
find "\$AD_DEST" -maxdepth 1 -type d -name "20*" -mtime +\$RETENTION -exec rm -rf {} \\; 2>/dev/null || true

echo "=== Backup concluído: \$(date) ==="
EOF

chmod +x /usr/local/bin/coude-backup.sh
log "Script de backup criado"

# =============================================================================
# SEÇÃO 17 — HEALTH CHECK
# =============================================================================
section "17/19 · Health Check"

cat > /usr/local/bin/coude-healthcheck.sh <<EOF
#!/usr/bin/env bash
# COUDE — Health check (executado pelo cron a cada 5 minutos)
LOG="$LOG_DIR/healthcheck.log"
DISK_THRESHOLD=85
SERVER_IP="$SERVER_IP"
API_PORT="$API_PORT"
DOMAIN="$DOMAIN"
DC_HOSTNAME="$DC_HOSTNAME"

exec >> "\$LOG" 2>&1
TS=\$(date '+%Y-%m-%d %H:%M:%S')
FAIL=0

ok()   { echo "[\$TS] [OK]   \$1"; }
fail() { echo "[\$TS] [FAIL] \$1"; FAIL=1; }
warn() { echo "[\$TS] [WARN] \$1"; }

# samba-ad-dc ativo?
systemctl is-active samba-ad-dc &>/dev/null && ok "samba-ad-dc" || fail "samba-ad-dc parado"

# API ativa?
systemctl is-active coude-api &>/dev/null && ok "coude-api" || fail "coude-api parada"

# DNS resolve o servidor?
host -t A "\$DC_HOSTNAME.\$DOMAIN" 127.0.0.1 &>/dev/null && ok "DNS" || fail "DNS falhou"

# SRV LDAP no DNS?
host -t SRV "_ldap._tcp.\$DOMAIN" &>/dev/null && ok "SRV LDAP" || fail "SRV LDAP ausente"

# API HTTP responde?
curl -sf "http://\$SERVER_IP:\$API_PORT/api/v1/health" -o /dev/null && ok "API HTTP" || fail "API HTTP sem resposta"

# Disco /srv
USAGE=\$(df /srv --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "0")
if [[ "\$USAGE" -ge "\$DISK_THRESHOLD" ]]; then
    warn "Disco /srv em \${USAGE}% (limite: \${DISK_THRESHOLD}%)"
    FAIL=1
else
    ok "Disco /srv: \${USAGE}%"
fi

exit \$FAIL
EOF

chmod +x /usr/local/bin/coude-healthcheck.sh
log "Health check criado"

# =============================================================================
# SEÇÃO 18 — CRON JOBS
# =============================================================================
section "18/19 · Cron Jobs"

cat > /etc/cron.d/coude <<'CRON'
# COUDE — Tarefas automáticas
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Health check a cada 5 minutos
*/5 * * * *   root  /usr/local/bin/coude-healthcheck.sh

# Purge de contas expiradas (diário às 02:00)
0 2 * * *     root  /usr/local/bin/coude-purge-deleted.sh

# Backup incremental (diário às 03:00)
0 3 * * *     root  /usr/local/bin/coude-backup.sh

# Compactar logs de auditoria grandes (domingo às 04:00)
0 4 * * 0     root  find /var/log/coude -name "*.log" -size +50M -exec gzip -f {} \;
CRON

log "Cron jobs configurados"

# =============================================================================
# SEÇÃO 19 — LOGROTATE
# =============================================================================
section "19/19 · Logrotate"

cat > /etc/logrotate.d/coude <<'LOGROTATE'
/var/log/coude/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
    sharedscripts
    postrotate
        systemctl reload coude-api 2>/dev/null || true
    endscript
}
LOGROTATE

log "Logrotate configurado (semanal, 4 semanas)"

# =============================================================================
# VALIDAÇÃO FINAL
# =============================================================================
echo ""
section "Validação Final"

echo "Aguardando Samba estabilizar (8s)..."
sleep 8

PASS=0; FAIL=0

chk() {
    local desc="$1"; shift
    if "$@" &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Infraestrutura base
chk "samba-ad-dc ativo"              systemctl is-active samba-ad-dc
chk "hostname correto"               bash -c "[[ \$(hostname -f) == '$SERVER_FQDN' ]]"
chk "hosts sem 127.x para o DC"      bash -c "! grep '$DC_HOSTNAME' /etc/hosts | grep -q '127\\.'"
chk "resolv.conf → 127.0.0.1"        grep -q "nameserver 127.0.0.1" /etc/resolv.conf
chk "resolv.conf imutável (chattr)"  bash -c "lsattr /etc/resolv.conf | grep -q -- '-i'"
chk "DNS: A record do servidor"      host -t A "$SERVER_FQDN" 127.0.0.1
chk "DNS: SRV _ldap._tcp"            host -t SRV "_ldap._tcp.$DOMAIN"
chk "smbclient lista shares"         smbclient -L "$DC_HOSTNAME" -N
# Diretórios
chk "Pasta users existe"             test -d "$SAMBA_DATA/users"
chk "Pasta turmas existe"            test -d "$SAMBA_DATA/turmas"
chk "Pasta professores existe"       test -d "$SAMBA_DATA/professores"
chk "Pasta arquivo_morto existe"     test -d "$SAMBA_DATA/arquivo_morto"
chk "Backup dest existe"             test -d "$BACKUP_DEST/samba"
# Scripts
chk "coude-gen-username.py"          test -x /usr/local/bin/coude-gen-username.py
chk "coude-create-user-dir.sh"       test -x /usr/local/bin/coude-create-user-dir.sh
chk "coude-create-turma-dir.sh"      test -x /usr/local/bin/coude-create-turma-dir.sh
chk "coude-soft-delete.sh"           test -x /usr/local/bin/coude-soft-delete.sh
chk "coude-backup.sh"                test -x /usr/local/bin/coude-backup.sh
chk "coude-healthcheck.sh"           test -x /usr/local/bin/coude-healthcheck.sh
# API e segurança
chk "TLS cert gerado"                test -f "$CERT_DIR/api.crt.pem"
chk "API key gerada"                 test -f "$CERT_DIR/api.key"
chk "coude-api registrado no systemd" systemctl is-enabled coude-api
chk "UFW ativo"                      bash -c "ufw status | grep -q 'Status: active'"
chk "Porta 53 (UFW)"                 bash -c "ufw status | grep -q '53'"
chk "Porta 445 (UFW)"                bash -c "ufw status | grep -q '445'"
chk "Porta API (UFW LAN)"            bash -c "ufw status | grep -q '$API_PORT'"
chk "Cron jobs configurados"         test -f /etc/cron.d/coude
chk "Logrotate configurado"          test -f /etc/logrotate.d/coude
chk "rsyslog audit configurado"      test -f /etc/rsyslog.d/10-coude-audit.conf
# Grupos no AD
chk "Grupo 'alunos' no AD"           samba-tool group show alunos
chk "Grupo 'professores' no AD"      samba-tool group show professores
chk "Grupo 'monitores' no AD"        samba-tool group show monitores
# OUs no AD
chk "OU=Alunos existe"               bash -c "samba-tool ou list 2>/dev/null | grep -qi 'Alunos'"
chk "OU=Deletados existe"            bash -c "samba-tool ou list 2>/dev/null | grep -qi 'Deletados'"

echo ""
echo -e "  ${BOLD}Resultado: ${GREEN}$PASS passou(aram)${NC} | ${RED}$FAIL falhou(aram)${NC}"

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║          COUDE Infraestrutura v2.0 — Instalação Concluída   ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Domínio AD${NC}     : ${GREEN}$REALM${NC}"
echo -e "  ${BOLD}Servidor${NC}       : ${GREEN}$SERVER_FQDN  ($SERVER_IP)${NC}"
echo -e "  ${BOLD}API${NC}            : ${GREEN}http://$SERVER_IP:$API_PORT/api/v1${NC}"
echo -e "  ${BOLD}Admin AD${NC}       : ${GREEN}Administrator@$REALM${NC}"
echo -e "  ${BOLD}Senha Admin${NC}    : ${RED}$(cat "$CERT_DIR/admin_password.txt" 2>/dev/null || echo 'ver /etc/coude/admin_password.txt')${NC}"
echo -e "  ${BOLD}API Key${NC}        : ${YELLOW}$(cat "$CERT_DIR/api.key" 2>/dev/null || echo 'ver /etc/coude/api.key')${NC}"
echo ""
echo -e "${BOLD}${YELLOW}Próximos passos obrigatórios:${NC}"
echo "  1. ⚠️  SALVE a senha do Admin AD e a API Key acima em local seguro"
echo "  2. Reinicie o servidor: sudo reboot"
echo "  3. Após reboot, verifique: samba-tool domain level show"
echo "  4. Inicie a API: systemctl start coude-api"
echo "  5. Monte o HD de backup externo em $BACKUP_DEST e teste: coude-backup.sh"
echo "  6. Configure GPOs nos clientes Windows (DNS: $SERVER_IP)"
echo "  7. Se ADMIN_SSH_KEY estava vazio, adicione-a e configure SSH hardening"
echo ""
echo -e "${BOLD}${YELLOW}Comandos rápidos:${NC}"
echo "  # Criar turma"
echo "  coude-new-turma.sh turma_fullstack_001"
echo ""
echo "  # Gerar username"
echo "  coude-gen-username.sh 'Thiago Cerqueira'   # → thicer"
echo ""
echo "  # Cadastrar via API"
echo "  curl -s -X POST http://$SERVER_IP:$API_PORT/api/v1/usuarios/cadastrar \\"
echo "    -H 'X-API-Key: \$(cat $CERT_DIR/api.key)' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"nome_completo\":\"Thiago Cerqueira\",\"email\":\"t@t.com\","
echo "         \"cpf\":\"529.982.247-25\",\"cargo\":\"aluno\","
echo "         \"turma\":\"turma_fullstack_001\","
echo "         \"senha_hash\":\"\$2b\$12\$salthashaqui...\","
echo "         \"metadata\":{\"id_externo\":\"EXT-001\"}}'"
echo ""
echo "  # Health check manual"
echo "  coude-healthcheck.sh && echo OK"
echo ""
echo "  # Validação Samba"
echo "  samba-tool domain level show"
echo "  host -t SRV _ldap._tcp.$DOMAIN"
echo "  kinit Administrator@$REALM"
echo ""
[[ $FAIL -gt 0 ]] && echo -e "${RED}Atenção: $FAIL verificação(ões) falharam. Revise o log em $LOG_DIR/provision.log${NC}\n"
