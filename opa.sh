#!/usr/bin/env bash
# Cria README.md e docs/linux-setup.md no repositório atual.
# Uso:
#   chmod +x criar-docs-linux.sh
#   ./criar-docs-linux.sh

set -euo pipefail

if [[ ! -f "setup.sh" || ! -d "docs" ]]; then
    echo "Erro: execute este script na raiz do repositório COUDE." >&2
    exit 1
fi

# Evita sobrescrever documentação existente.
for file in README.md docs/linux-setup.md; do
    if [[ -e "$file" ]]; then
        echo "Erro: '$file' já existe. Nenhum arquivo foi alterado." >&2
        exit 1
    fi
done

cat > README.md <<'EOF'
# COUDE — Infraestrutura de domínio

Infraestrutura baseada em Debian 12 com:

- Samba Active Directory;
- compartilhamentos de arquivos;
- gerenciamento de alunos, professores, monitores e turmas;
- API Flask;
- integração com estações Windows;
- acesso aos arquivos por computadores Linux.

## Estrutura

```text
.
├── docs
│   ├── linux-setup.md
│   └── windows-setup.md
├── scripts
│   └── install_domain.ps1
├── infra.pdf
├── setup.sh
└── validate.sh
```

## Servidor

| Propriedade | Valor |
|---|---|
| Domínio DNS | `ad.coude.com.br` |
| Realm | `AD.COUDE.COM.BR` |
| NetBIOS | `COUDE` |
| Servidor | `srv1.ad.coude.com.br` |
| IP | `192.168.1.10` |
| API | `http://192.168.1.10:8080/api/v1` |

## Instalação do servidor

No Debian 12:

```bash
sudo bash setup.sh
sudo reboot
sudo bash validate.sh
```

Revise as configurações no início de `setup.sh` antes da instalação,
principalmente a interface de rede, gateway e endereço IP.

## Clientes Windows

Para ingressar computadores Windows no domínio e habilitar login com contas do
Active Directory, consulte:

- [Configuração do Windows](docs/windows-setup.md)

## Clientes Linux

Para acessar pastas de turmas e professores a partir de uma máquina Linux
pessoal, sem trocar o login local nem ingressar a máquina no domínio, consulte:

- [Acesso pelo Linux](docs/linux-setup.md)

O acesso Linux descrito nessa documentação usa SMB. O professor continua
usando sua conta local normalmente e autentica sua conta COUDE somente ao
abrir os compartilhamentos.

## Compartilhamentos

```text
smb://192.168.1.10/turmas
smb://192.168.1.10/professores
smb://192.168.1.10/users
smb://192.168.1.10/monitores
```

Também é possível usar o nome do servidor quando o DNS do domínio estiver
configurado:

```text
smb://srv1.ad.coude.com.br/turmas
```

O acesso efetivo depende dos grupos e ACLs configurados no servidor.
EOF

cat > docs/linux-setup.md <<'EOF'
# COUDE — Acesso às pastas pelo Linux

Este documento explica como acessar os compartilhamentos do servidor COUDE em
uma máquina Linux pessoal.

Este procedimento:

- não cria um usuário de domínio para login no Linux;
- não ingressa a máquina no Active Directory;
- não substitui o usuário local;
- permite enviar e receber arquivos pelo gerenciador de arquivos;
- solicita uma conta válida do domínio COUDE.

## Dados do servidor

| Propriedade | Valor |
|---|---|
| Domínio | `ad.coude.com.br` |
| NetBIOS | `COUDE` |
| Servidor | `srv1.ad.coude.com.br` |
| IP | `192.168.1.10` |

## 1. Instalar o suporte a SMB

### Debian, Ubuntu e derivados

```bash
sudo apt update
sudo apt install -y gvfs-backends smbclient cifs-utils
```

### Fedora

```bash
sudo dnf install -y gvfs-smb samba-client cifs-utils
```

### Arch Linux e derivados

```bash
sudo pacman -S --needed gvfs-smb smbclient cifs-utils
```

Encerre e abra novamente o gerenciador de arquivos após a instalação, caso a
opção de conexão SMB não apareça.

## 2. Conectar pelo gerenciador de arquivos

No Nautilus, Nemo, Dolphin ou gerenciador equivalente:

1. Abra **Rede**, **Outros locais** ou **Conectar ao servidor**.
2. Informe:

```text
smb://192.168.1.10/
```

Para abrir diretamente as turmas:

```text
smb://192.168.1.10/turmas
```

3. Quando solicitado, use:

```text
Usuário: username fornecido pela COUDE
Domínio: COUDE
Senha: senha da conta do domínio
```

Não use necessariamente o e-mail como usuário. Utilize o `username` retornado
no cadastro da conta.

## 3. Pastas disponíveis

### Turmas

```text
smb://192.168.1.10/turmas
```

Professores podem acessar os materiais e pastas de turmas conforme as
permissões configuradas no servidor.

### Área dos professores

```text
smb://192.168.1.10/professores
```

O acesso é permitido a membros do grupo `professores`.

### Pastas pessoais

```text
smb://192.168.1.10/users
```

O compartilhamento `users` não é navegável publicamente. Quando necessário,
abra diretamente a pasta do usuário:

```text
smb://192.168.1.10/users/USERNAME
```

### Monitores

```text
smb://192.168.1.10/monitores
```

O acesso é permitido a membros do grupo `monitores`.

## 4. Enviar e receber arquivos

Depois da conexão, o compartilhamento aparecerá na barra lateral do
gerenciador de arquivos.

Use copiar e colar ou arraste arquivos entre:

- as pastas locais da máquina;
- a pasta da turma;
- a área dos professores;
- a pasta pessoal no servidor.

No GNOME/GVFS, o ponto interno de montagem costuma ficar em:

```text
/run/user/UID/gvfs/
```

Não é necessário manipular esse diretório manualmente.

## 5. Salvar como favorito

Depois de abrir o compartilhamento, marque-o como favorito no gerenciador de
arquivos.

Se o sistema oferecer a opção de memorizar a senha, ela será armazenada no
chaveiro da conta local. Em máquinas compartilhadas, não salve a senha.

## 6. Desconectar

Clique no botão de ejetar ou desmontar ao lado do compartilhamento na barra
lateral.

Isso desconecta apenas o compartilhamento. A máquina não entra nem sai do
domínio.

## 7. Testar pelo terminal

Liste os compartilhamentos:

```bash
smbclient -L //192.168.1.10 -U 'COUDE\USERNAME'
```

Abra o compartilhamento de turmas:

```bash
smbclient //192.168.1.10/turmas -U 'COUDE\USERNAME'
```

A senha será solicitada sem ser exibida no terminal.

Comandos úteis dentro do `smbclient`:

```text
ls
cd DIRETORIO
get ARQUIVO
put ARQUIVO
exit
```

## 8. Montagem opcional em uma pasta local

Use o gerenciador de arquivos como opção padrão. Se precisar de um caminho
local para ferramentas que não suportam `smb://`, monte o compartilhamento
manualmente.

Crie o diretório:

```bash
mkdir -p "$HOME/COUDE/Turmas"
```

Monte:

```bash
sudo mount -t cifs //192.168.1.10/turmas "$HOME/COUDE/Turmas" \
  -o "username=USERNAME,domain=COUDE,uid=$(id -u),gid=$(id -g),vers=3.1.1"
```

A senha será solicitada. Os arquivos aparecerão em:

```text
~/COUDE/Turmas
```

Desmonte ao terminar:

```bash
sudo umount "$HOME/COUDE/Turmas"
```

Não coloque a senha diretamente em `/etc/fstab` ou em scripts.

## 9. Diagnóstico

### O servidor não abre

Teste a conectividade:

```bash
ping -c 3 192.168.1.10
```

Teste a porta SMB:

```bash
nc -vz 192.168.1.10 445
```

### O nome do servidor não resolve

Use o IP:

```text
smb://192.168.1.10/turmas
```

O endereço com nome:

```text
smb://srv1.ad.coude.com.br/turmas
```

depende do DNS `192.168.1.10` estar configurado na máquina ou na rede.

### A senha é recusada

Verifique:

- se o domínio informado é `COUDE`;
- se foi usado o `username`, e não o nome completo;
- se a senha inicial precisa ser alterada;
- se a conta está habilitada;
- se a máquina consegue alcançar o servidor.

### O compartilhamento abre, mas uma pasta é negada

Isso normalmente indica uma restrição de grupo ou ACL no servidor. Confirme
que a conta pertence ao grupo correto:

```bash
sudo samba-tool user getgroups USERNAME
```

Esse comando deve ser executado pelo administrador no servidor COUDE.

## Login do Linux usando o domínio

Este guia cobre somente acesso a arquivos.

Se a instituição quiser que alunos e professores entrem na própria sessão do
Linux usando suas contas do Active Directory, será necessária uma configuração
separada com `realmd` e SSSD em cada estação. Isso não é necessário para abrir,
enviar ou receber arquivos pelos compartilhamentos SMB.
EOF

echo "Estrutura criada:"
printf '  %s\n' "README.md" "docs/linux-setup.md"
echo
echo "Revise com:"
echo "  git diff -- README.md docs/linux-setup.md"
