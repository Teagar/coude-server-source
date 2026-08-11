# COUDE — Infraestrutura de domínio

Infraestrutura baseada em Debian 13 com:

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

No Debian 13:

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
