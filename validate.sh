#!/usr/bin/env bash
# =============================================================================
# COUDE — Infraestrutura v2.0 — Validação Final (standalone)
# Roda apenas a checklist final + resumo, sem reinstalar nada.
# Use quando as Seções 1-19 já foram concluídas mas a validação falhou
# por bug no checker (corrigido aqui).
# =============================================================================
# Uso: sudo bash coude-validar.sh
# =============================================================================

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
chk "ldbmodify disponível (ldb-tools)" bash -c "command -v ldbmodify"
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
echo "  # Cadastrar via API (a senha inicial é gerada pelo servidor a partir"
echo "  # do CPF e o usuário é obrigado a trocá-la no primeiro login — ver"
echo "  # coude-documentacao-tecnica.md)"
echo "  curl -s -X POST http://$SERVER_IP:$API_PORT/api/v1/usuarios/cadastrar \\"
echo "    -H 'X-API-Key: \$(cat $CERT_DIR/api.key)' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"nome_completo\":\"Thiago Cerqueira\",\"email\":\"t@t.com\","
echo "         \"cpf\":\"529.982.247-25\",\"cargo\":\"aluno\","
echo "         \"turma\":\"turma_fullstack_001\","
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
