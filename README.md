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
│   ├── windows-setup.md
│   └── coude-documentacao-tecnica.md   # Documentação de integração da API
├── scripts
│   ├── install_domain.ps1
│   └── coude-update-api.sh             # Atualiza a API num servidor já instalado
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

## Atualizando a API em um servidor já instalado

Se o servidor já está no ar e você só quer aplicar uma versão nova da API
(sem reprovisionar o domínio), use o script de atualização em vez de rodar
`setup.sh` de novo:

```bash
sudo bash scripts/coude-update-api.sh
```

Ele detecta a configuração já instalada (IP, porta, diretórios), faz backup
do `app.py` atual, aplica a nova versão e reinicia o serviço `coude-api`. Se
o serviço não subir, reverte o backup automaticamente.

## API — Integração

Para quem quer consumir a API a partir de um sistema próprio (matrícula,
portal, automação de cadastro), veja a documentação completa de integração:

- [Documentação técnica da API](docs/coude-documentacao-tecnica.md)

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
