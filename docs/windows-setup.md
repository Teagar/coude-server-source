# COUDE — Tutorial: Cadastro de Usuários e Login no Windows 10/11

Este documento explica como configurar computadores Windows 10/11 para usar o servidor COUDE, ingressar no domínio, autenticar usuários e acessar as pastas compartilhadas.

---

## 1. Informações do ambiente

| Item | Valor |
|---|---|
| Domínio DNS/AD | `ad.coude.com.br` |
| Realm Kerberos | `AD.COUDE.COM.BR` |
| Nome NetBIOS | `COUDE` |
| Controlador de domínio | `srv1.ad.coude.com.br` |
| IP do servidor | `192.168.1.10` |
| DNS interno | `192.168.1.10` |
| API | `http://192.168.1.10:8080/api/v1` |
| Compartilhamento principal | `\\srv1.ad.coude.com.br\turmas` |

> Use sempre o DNS interno `192.168.1.10` nos computadores do domínio. Não configure Google DNS, Cloudflare, o roteador ou outro DNS como servidor alternativo.

---

## 2. Pré-requisitos

### 2.1 Edição do Windows

O computador precisa executar uma destas edições:

- Windows 10 Pro, Enterprise ou Education;
- Windows 11 Pro, Enterprise ou Education.

O Windows Home não pode ingressar em um domínio Active Directory.

Para verificar a edição:

1. Pressione `Win + R`.
2. Execute:

```text
winver
```

Também é possível consultar pelo PowerShell:

```powershell
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion
```

### 2.2 Rede

O computador deve:

- estar conectado à mesma rede do servidor;
- conseguir alcançar `192.168.1.10`;
- usar `192.168.1.10` como DNS;
- ter data e hora sincronizadas;
- não estar usando VPN durante a configuração.

Teste a comunicação:

```powershell
ping 192.168.1.10
```

Teste as portas principais:

```powershell
Test-NetConnection 192.168.1.10 -Port 53
Test-NetConnection 192.168.1.10 -Port 88
Test-NetConnection 192.168.1.10 -Port 389
Test-NetConnection 192.168.1.10 -Port 445
```

As portas verificadas correspondem a:

| Porta | Serviço |
|---|---|
| `53` | DNS |
| `88` | Kerberos |
| `389` | LDAP |
| `445` | SMB |

---

## 3. Abrir o PowerShell como administrador

1. Abra o menu Iniciar.
2. Pesquise por `PowerShell`.
3. Clique com o botão direito em **Windows PowerShell**.
4. Selecione **Executar como administrador**.

Os comandos das próximas seções devem ser executados nessa janela.

---

## 4. Identificar a interface de rede

Liste as interfaces:

```powershell
Get-NetAdapter
```

Exemplo:

```text
Name       InterfaceDescription                  Status
----       --------------------                  ------
Wi-Fi 2    Adaptador de rede sem fio             Up
Ethernet   Controlador Ethernet                   Disconnected
```

Use exatamente o nome exibido na coluna `Name`.

Neste tutorial, o exemplo usa:

```text
Wi-Fi 2
```

Se o computador mostrar outro nome, substitua `"Wi-Fi 2"` nos comandos.

Também é possível listar apenas as interfaces ativas:

```powershell
Get-NetAdapter | Where-Object Status -eq "Up"
```

---

## 5. Configurar o DNS do Windows

Configure o servidor COUDE como único DNS IPv4:

```powershell
Set-DnsClientServerAddress `
  -InterfaceAlias "Wi-Fi 2" `
  -ServerAddresses 192.168.1.10
```

Limpe o cache DNS:

```powershell
Clear-DnsClientCache
```

Confira a configuração:

```powershell
Get-DnsClientServerAddress -InterfaceAlias "Wi-Fi 2"
```

O resultado IPv4 deve mostrar:

```text
ServerAddresses : {192.168.1.10}
```

Também é possível verificar com:

```powershell
ipconfig /all
```

Na interface ativa, procure:

```text
Servidores DNS . . . . . . . . . . . : 192.168.1.10
```

### 5.1 Configuração pela interface gráfica

1. Abra **Painel de Controle**.
2. Entre em **Rede e Internet**.
3. Abra **Central de Rede e Compartilhamento**.
4. Clique em **Alterar as configurações do adaptador**.
5. Clique com o botão direito na interface ativa.
6. Selecione **Propriedades**.
7. Abra **Protocolo IP Versão 4 (TCP/IPv4)**.
8. Marque **Usar os seguintes endereços de servidor DNS**.
9. Informe:

```text
Servidor DNS preferencial: 192.168.1.10
Servidor DNS alternativo: deixar vazio
```

10. Confirme todas as janelas.

---

## 6. Corrigir conflito com DNS IPv6

Em alguns roteadores, o Windows recebe um DNS IPv6 como `fe80::1`. Nesse caso, ele pode consultar o roteador em vez do servidor COUDE, mesmo quando o DNS IPv4 está correto.

### 6.1 Verificar os servidores DNS IPv4 e IPv6

```powershell
Get-DnsClientServerAddress -InterfaceAlias "Wi-Fi 2"
```

Se IPv6 mostrar algo como:

```text
ServerAddresses : {fe80::1}
```

e as consultas normais retornarem `NXDOMAIN`, desabilite temporariamente o IPv6 nessa interface:

```powershell
Disable-NetAdapterBinding `
  -Name "Wi-Fi 2" `
  -ComponentID ms_tcpip6
```

Reaplique o DNS, limpe o cache e reinicie a interface:

```powershell
Set-DnsClientServerAddress `
  -InterfaceAlias "Wi-Fi 2" `
  -ServerAddresses 192.168.1.10

Clear-DnsClientCache

Restart-NetAdapter -Name "Wi-Fi 2"
```

A conexão pode cair por alguns segundos.

Confirme novamente:

```powershell
Get-DnsClientServerAddress -InterfaceAlias "Wi-Fi 2"
```

### 6.2 Reativar IPv6 posteriormente

O IPv6 pode ser reativado depois que o DNS IPv6 da rede e o registro `AAAA` do servidor forem corrigidos:

```powershell
Enable-NetAdapterBinding `
  -Name "Wi-Fi 2" `
  -ComponentID ms_tcpip6
```

Não reative enquanto o Windows ainda estiver usando um DNS IPv6 incorreto ou tentando acessar o controlador por um endereço IPv6 inválido.

---

## 7. Validar o DNS e o controlador de domínio

Não prossiga com o ingresso antes de todos os testes desta seção funcionarem.

### 7.1 Consultar o servidor

```powershell
Resolve-DnsName srv1.ad.coude.com.br
```

O endereço IPv4 esperado é:

```text
192.168.1.10
```

Alternativa:

```powershell
nslookup srv1.ad.coude.com.br
```

O servidor DNS utilizado deve ser `192.168.1.10`.

### 7.2 Consultar o serviço LDAP

```powershell
Resolve-DnsName `
  _ldap._tcp.dc._msdcs.ad.coude.com.br `
  -Type SRV
```

O destino esperado é:

```text
srv1.ad.coude.com.br
```

A porta esperada é:

```text
389
```

Também pode ser testado com:

```powershell
nslookup -type=SRV _ldap._tcp.dc._msdcs.ad.coude.com.br
```

### 7.3 Localizar o controlador

```powershell
nltest /dsgetdc:ad.coude.com.br /force
```

O resultado deve conter informações semelhantes a:

```text
DC: \\srv1.ad.coude.com.br
Endereço: \\192.168.1.10
Nome do Dom: ad.coude.com.br
Nome da Floresta: ad.coude.com.br
Comando concluído com êxito
```

### 7.4 Teste explícito do DNS

Se a consulta normal falhar, teste diretamente contra o servidor:

```powershell
Resolve-DnsName `
  srv1.ad.coude.com.br `
  -Server 192.168.1.10
```

```powershell
Resolve-DnsName `
  _ldap._tcp.dc._msdcs.ad.coude.com.br `
  -Type SRV `
  -Server 192.168.1.10
```

Se a consulta explícita funcionar, mas a normal falhar, o computador ainda está usando outro DNS. Verifique principalmente:

- DNS IPv6 fornecido pelo roteador;
- adaptador VPN;
- adaptadores virtuais;
- interface errada;
- DNS público configurado como alternativo.

---

## 8. Ajustar data e hora

Kerberos exige que o relógio do computador e do servidor estejam sincronizados.

Confira o horário:

```powershell
Get-Date
```

Force uma sincronização:

```powershell
w32tm /resync
```

Antes de o computador ingressar no domínio, o comando pode usar a fonte de tempo atual do Windows. Após o ingresso e reinício, o controlador de domínio deverá ser usado de acordo com a hierarquia do domínio.

---

## 9. Ingressar o Windows no domínio

### 9.1 Método recomendado pelo PowerShell

Execute como administrador:

```powershell
Add-Computer `
  -DomainName "ad.coude.com.br" `
  -Credential "Administrator@ad.coude.com.br" `
  -Restart
```

Uma janela solicitará a senha do administrador do domínio.

Use:

```text
Usuário: Administrator@ad.coude.com.br
```

ou:

```text
COUDE\Administrator
```

> Use barra invertida em `COUDE\Administrator`. Não use `AD/Administrador`.

O computador será reiniciado automaticamente se o ingresso for concluído.

### 9.2 Método pela interface gráfica

1. Pressione `Win + R`.
2. Execute:

```text
sysdm.cpl
```

3. Abra a aba **Nome do Computador**.
4. Clique em **Alterar**.
5. Se desejar, defina um nome adequado para o computador.
6. Marque **Domínio**.
7. Digite:

```text
ad.coude.com.br
```

8. Confirme.
9. Quando as credenciais forem solicitadas, use:

```text
Administrator@ad.coude.com.br
```

ou:

```text
COUDE\Administrator
```

10. Após a mensagem de boas-vindas ao domínio, reinicie o computador.

### 9.3 Verificar o ingresso

Depois do reinício:

```powershell
Get-CimInstance Win32_ComputerSystem |
  Select-Object Name, Domain, PartOfDomain
```

Resultado esperado:

```text
Domain       : ad.coude.com.br
PartOfDomain : True
```

Também é possível executar:

```powershell
systeminfo | findstr /B /C:"Domínio"
```

---

## 10. Cadastrar usuários

Os usuários devem ser criados no Active Directory antes do primeiro login no Windows.

Há duas formas possíveis:

- pela API COUDE;
- diretamente pelo Samba no servidor.

### 10.1 Consultar a saúde da API

No servidor Debian:

```bash
curl -i http://192.168.1.10:8080/api/v1/health
```

Resultado esperado:

```text
HTTP/1.1 200 OK
```

Com um corpo semelhante a:

```json
{
  "samba": true,
  "status": "ok"
}
```

### 10.2 Consultar a documentação real da API

Antes de cadastrar usuários, consulte a documentação ou o código da API para confirmar:

- endpoint;
- campos obrigatórios;
- formato da senha;
- formato de `senha_hash`;
- regras para turma e perfil;
- códigos de resposta.

Não envie um hash bcrypt no lugar de uma senha comum sem confirmar que esse é o contrato do endpoint.

A autenticação utiliza o cabeçalho:

```text
X-API-Key
```

No servidor, a chave pode ser lida sem exibi-la no terminal:

```bash
curl \
  -H "X-API-Key: $(cat /etc/coude/api.key)" \
  http://192.168.1.10:8080/api/v1/health
```

> Use aspas duplas. Aspas simples impedem a expansão de `$(cat /etc/coude/api.key)`.

### 10.3 Exemplo genérico de cadastro pela API

Adapte o endpoint e os campos ao contrato real da API:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $(cat /etc/coude/api.key)" \
  -d '{
    "nome": "Maria Silva",
    "usuario": "maria.silva",
    "senha": "SUBSTITUA_POR_UMA_SENHA_TEMPORARIA",
    "turma": "turma-a"
  }' \
  http://192.168.1.10:8080/api/v1/usuarios
```

Não coloque a chave da API diretamente em documentos, scripts versionados ou mensagens.

### 10.4 Cadastro direto pelo Samba

No servidor Debian:

```bash
sudo samba-tool user create maria.silva
```

O comando solicitará a senha do novo usuário.

Para listar os usuários:

```bash
sudo samba-tool user list
```

Para consultar um usuário:

```bash
sudo samba-tool user show maria.silva
```

Para redefinir a senha:

```bash
sudo samba-tool user setpassword maria.silva
```

Para habilitar um usuário:

```bash
sudo samba-tool user enable maria.silva
```

Para desabilitar um usuário:

```bash
sudo samba-tool user disable maria.silva
```

### 10.5 Adicionar o usuário a um grupo

Exemplo:

```bash
sudo samba-tool group addmembers "turma-a" maria.silva
```

Confira os membros:

```bash
sudo samba-tool group listmembers "turma-a"
```

O grupo deve existir antes dessa operação.

---

## 11. Primeiro login no Windows

Depois que:

- o computador ingressar no domínio;
- o computador for reiniciado;
- o usuário estiver cadastrado no Active Directory;

faça o primeiro login.

Na tela de entrada:

1. Selecione **Outro usuário**.
2. Informe uma destas formas:

```text
maria.silva@ad.coude.com.br
```

ou:

```text
COUDE\maria.silva
```

3. Digite a senha do domínio.

No primeiro login, o Windows criará um perfil local para o usuário do domínio.

### 11.1 Confirmar o usuário autenticado

Após entrar:

```powershell
whoami
```

Resultado esperado:

```text
coude\maria.silva
```

Confira o domínio:

```powershell
$env:USERDOMAIN
```

Resultado esperado:

```text
COUDE
```

Confira o controlador usado:

```powershell
$env:LOGONSERVER
```

Resultado esperado:

```text
\\SRV1
```

---

## 12. Acessar as pastas compartilhadas

### 12.1 Abrir pelo Explorador de Arquivos

Pressione `Win + R` e execute:

```text
\\srv1.ad.coude.com.br
```

Ou diretamente:

```text
\\srv1.ad.coude.com.br\turmas
```

Também é possível usar o IP para diagnóstico:

```text
\\192.168.1.10\turmas
```

Para uso normal, prefira o FQDN:

```text
\\srv1.ad.coude.com.br\turmas
```

### 12.2 Mapear uma unidade de rede

No PowerShell:

```powershell
New-PSDrive `
  -Name T `
  -PSProvider FileSystem `
  -Root "\\srv1.ad.coude.com.br\turmas" `
  -Persist
```

A unidade aparecerá como:

```text
T:
```

Alternativa pelo Prompt de Comando:

```cmd
net use T: \\srv1.ad.coude.com.br\turmas /persistent:yes
```

### 12.3 Remover o mapeamento

```cmd
net use T: /delete
```

### 12.4 Limpar credenciais SMB antigas

Se o Windows estiver reutilizando credenciais incorretas:

```cmd
net use * /delete
```

Esse comando encerra todas as conexões SMB atuais. Confirme somente se não houver arquivos de rede abertos.

Também é possível abrir o Gerenciador de Credenciais:

```text
control /name Microsoft.CredentialManager
```

Remova credenciais antigas relacionadas a:

```text
srv1
srv1.ad.coude.com.br
192.168.1.10
```

Depois, acesse novamente usando:

```text
COUDE\usuario
```

---

## 13. Mapeamento automático por GPO

Para mapear unidades automaticamente para os usuários, use uma Política de Grupo.

Em uma estação administrativa com RSAT:

1. Abra **Gerenciamento de Política de Grupo**.
2. Crie ou edite uma GPO vinculada à unidade organizacional dos usuários.
3. Navegue até:

```text
Configuração do Usuário
  → Preferências
    → Configurações do Windows
      → Mapas de Unidade
```

4. Crie um novo mapeamento:
   - Ação: `Atualizar`;
   - Local: `\\srv1.ad.coude.com.br\turmas`;
   - Letra: `T:`;
   - Marcar **Reconectar**.

Atualize as políticas no cliente:

```powershell
gpupdate /force
```

Confira o resultado:

```powershell
gpresult /r
```

Para gerar um relatório:

```powershell
gpresult /h "$env:USERPROFILE\Desktop\gpresult.html"
```

---

## 14. Diagnóstico de problemas comuns

### 14.1 `ERROR_NO_SUCH_DOMAIN` ou erro 1355

Sintomas:

```text
Não foi possível contatar um controlador de domínio
```

ou:

```text
ERROR_NO_SUCH_DOMAIN
```

Teste:

```powershell
Resolve-DnsName srv1.ad.coude.com.br
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.coude.com.br -Type SRV
nltest /dsgetdc:ad.coude.com.br /force
```

Causas comuns:

- DNS do Windows não aponta para `192.168.1.10`;
- o roteador está sendo usado como DNS;
- existe DNS IPv6 como `fe80::1`;
- VPN ou adaptador virtual está interferindo;
- registros DNS do Samba estão incorretos;
- firewall está bloqueando o tráfego;
- computador e servidor estão em redes diferentes.

### 14.2 `nslookup` usa `fe80::1`

Verifique:

```powershell
Get-DnsClientServerAddress
```

Identifique a interface ativa e desabilite temporariamente IPv6 nela:

```powershell
Disable-NetAdapterBinding `
  -Name "Wi-Fi 2" `
  -ComponentID ms_tcpip6
```

Depois:

```powershell
Set-DnsClientServerAddress `
  -InterfaceAlias "Wi-Fi 2" `
  -ServerAddresses 192.168.1.10

Clear-DnsClientCache
Restart-NetAdapter -Name "Wi-Fi 2"
```

Repita:

```powershell
nslookup srv1.ad.coude.com.br
nltest /dsgetdc:ad.coude.com.br /force
```

### 14.3 Consulta explícita funciona, mas a consulta normal falha

Exemplo:

```powershell
Resolve-DnsName srv1.ad.coude.com.br -Server 192.168.1.10
```

funciona, mas:

```powershell
Resolve-DnsName srv1.ad.coude.com.br
```

falha.

Isso confirma que o DNS Samba está respondendo, mas o Windows não o está usando como resolvedor efetivo.

Verifique:

```powershell
Get-NetAdapter
Get-DnsClientServerAddress
ipconfig /all
```

Analise todas as interfaces, inclusive:

- Wi-Fi;
- Ethernet;
- VPN;
- Hyper-V;
- WSL;
- VirtualBox;
- VMware;
- adaptadores desconectados com configuração persistente.

### 14.4 Nome do servidor retorna IPv6 incorreto

Teste:

```powershell
Resolve-DnsName srv1.ad.coude.com.br -Type AAAA
```

Se aparecer um IPv6 público ou inválido que não pertence ao controlador, o registro `AAAA` deve ser removido ou corrigido no DNS Samba.

No servidor, primeiro consulte o registro:

```bash
sudo samba-tool dns query \
  127.0.0.1 \
  ad.coude.com.br \
  srv1 \
  AAAA \
  -U Administrator
```

Se confirmar que o valor está incorreto, remova-o usando o endereço exato retornado:

```bash
sudo samba-tool dns delete \
  127.0.0.1 \
  ad.coude.com.br \
  srv1 \
  AAAA \
  ENDERECO_IPV6_INCORRETO \
  -U Administrator
```

Depois, no Windows:

```powershell
Clear-DnsClientCache
```

> Não copie um endereço IPv6 sem confirmar o valor existente no DNS. Excluir um registro DNS é uma alteração administrativa e deve ser feita somente após a consulta.

### 14.5 O computador consegue pingar, mas não encontra o domínio

Ping não valida o Active Directory. O ingresso depende principalmente de DNS, Kerberos e LDAP.

Execute:

```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.coude.com.br -Type SRV
Test-NetConnection 192.168.1.10 -Port 88
Test-NetConnection 192.168.1.10 -Port 389
nltest /dsgetdc:ad.coude.com.br /force
```

### 14.6 Erro de credenciais ao ingressar

Use uma destas formas:

```text
Administrator@ad.coude.com.br
```

```text
COUDE\Administrator
```

Não use:

```text
AD/Administrador
Administrador
ad.coude.com.br/Administrator
```

Observe:

- o nome padrão é `Administrator`;
- `COUDE\Administrator` usa barra invertida;
- a senha deve ser a senha atual do administrador do AD.

### 14.7 Erro de relacionamento de confiança

Se aparecer uma mensagem informando que a relação de confiança falhou, o objeto do computador e a senha local da conta de máquina podem estar dessincronizados.

Primeiro tente reparar com uma conta administrativa do domínio:

```powershell
Test-ComputerSecureChannel `
  -Repair `
  -Credential "COUDE\Administrator"
```

Depois:

```powershell
Restart-Computer
```

Se isso não resolver, investigue o objeto do computador no AD antes de removê-lo ou recriá-lo.

### 14.8 Usuário não consegue entrar

No servidor, confira se o usuário existe:

```bash
sudo samba-tool user show usuario
```

Liste os usuários:

```bash
sudo samba-tool user list
```

Confirme que a conta está habilitada:

```bash
sudo samba-tool user enable usuario
```

Se necessário, redefina a senha:

```bash
sudo samba-tool user setpassword usuario
```

No Windows, use:

```text
COUDE\usuario
```

ou:

```text
usuario@ad.coude.com.br
```

### 14.9 Pasta compartilhada não abre

Teste a porta SMB:

```powershell
Test-NetConnection 192.168.1.10 -Port 445
```

Teste pelo FQDN:

```text
\\srv1.ad.coude.com.br\turmas
```

Teste pelo IP somente para diagnóstico:

```text
\\192.168.1.10\turmas
```

No servidor, confira os compartilhamentos:

```bash
smbclient -L localhost -N
```

O resultado esperado inclui:

```text
netlogon
sysvol
turmas
IPC$
```

A mensagem abaixo é normal:

```text
SMB1 disabled -- no workgroup available
```

Não habilite SMB1 para removê-la.

### 14.10 A API não responde em `127.0.0.1`

O Gunicorn está vinculado ao endereço:

```text
192.168.1.10:8080
```

Portanto, use:

```bash
curl -i http://192.168.1.10:8080/api/v1/health
```

Se necessário, confira o serviço:

```bash
sudo systemctl status coude-api --no-pager
```

Confira a porta:

```bash
sudo ss -lntp | grep ':8080'
```

---

## 15. Comandos rápidos de diagnóstico no Windows

Execute no PowerShell como administrador:

```powershell
Get-NetAdapter

Get-DnsClientServerAddress

ipconfig /all

Resolve-DnsName srv1.ad.coude.com.br

Resolve-DnsName `
  _ldap._tcp.dc._msdcs.ad.coude.com.br `
  -Type SRV

Test-NetConnection 192.168.1.10 -Port 53

Test-NetConnection 192.168.1.10 -Port 88

Test-NetConnection 192.168.1.10 -Port 389

Test-NetConnection 192.168.1.10 -Port 445

nltest /dsgetdc:ad.coude.com.br /force

w32tm /query /status
```

Depois do ingresso:

```powershell
whoami

$env:USERDOMAIN

$env:LOGONSERVER

Get-CimInstance Win32_ComputerSystem |
  Select-Object Name, Domain, PartOfDomain

gpresult /r
```

---

## 16. Comandos rápidos de diagnóstico no servidor

```bash
hostname
hostname -f
ip -4 address
ip route
```

```bash
sudo systemctl status samba-ad-dc --no-pager
sudo systemctl status coude-api --no-pager
```

```bash
host -t A srv1.ad.coude.com.br 127.0.0.1
host -t SRV _ldap._tcp.ad.coude.com.br 127.0.0.1
host -t SRV _ldap._tcp.dc._msdcs.ad.coude.com.br 127.0.0.1
```

```bash
smbclient -L localhost -N
```

```bash
sudo samba-tool domain info 127.0.0.1
sudo samba-tool user list
sudo samba-tool group list
```

```bash
curl -i http://192.168.1.10:8080/api/v1/health
```

Validação completa:

```bash
sudo /root/validate.sh
```

Resultado esperado:

```text
34 passou(aram) | 0 falhou(aram)
```

---

## 17. Segurança

### 17.1 Rotacionar a senha administrativa

A senha administrativa foi exposta durante a instalação e os testes. Considere-a comprometida e altere-a antes de usar o ambiente em produção:

```bash
sudo samba-tool user setpassword Administrator
```

Atualize qualquer processo administrativo que dependa dessa credencial.

### 17.2 Rotacionar a chave da API

A API Key também foi exposta durante os testes. Gere uma nova chave usando o procedimento suportado pela aplicação e atualize:

```text
/etc/coude/api.key
```

Depois, reinicie o serviço:

```bash
sudo systemctl restart coude-api
```

Valide:

```bash
curl -i http://192.168.1.10:8080/api/v1/health
```

Não registre a chave em:

- README;
- Git;
- scripts compartilhados;
- históricos de comandos;
- mensagens;
- capturas de tela.

### 17.3 Recomendações adicionais

- Não habilite SMB1.
- Não use DNS público nos clientes do domínio.
- Restrinja a API às redes autorizadas.
- Use senhas temporárias fortes para novos usuários.
- Exija alteração de senha quando aplicável.
- Mantenha Debian, Samba e Windows atualizados.
- Faça backups regulares.
- Copie backups para armazenamento externo.
- Teste periodicamente a restauração.
- Restrinja privilégios administrativos.
- Não use a conta `Administrator` para tarefas cotidianas.

---

## 18. Checklist de configuração do computador

### Antes do ingresso

- [ ] Windows Pro, Enterprise ou Education.
- [ ] Computador conectado à mesma rede do servidor.
- [ ] `ping 192.168.1.10` funciona.
- [ ] Interface ativa identificada com `Get-NetAdapter`.
- [ ] DNS IPv4 configurado exclusivamente como `192.168.1.10`.
- [ ] DNS IPv6 incorreto removido ou IPv6 temporariamente desabilitado.
- [ ] `Resolve-DnsName srv1.ad.coude.com.br` retorna `192.168.1.10`.
- [ ] Consulta LDAP SRV retorna `srv1.ad.coude.com.br`.
- [ ] `nltest /dsgetdc:ad.coude.com.br /force` conclui com êxito.
- [ ] Data e hora estão corretas.
- [ ] Usuário administrativo do domínio está disponível.

### Ingresso

- [ ] Domínio informado como `ad.coude.com.br`.
- [ ] Credencial usada como `Administrator@ad.coude.com.br` ou `COUDE\Administrator`.
- [ ] Mensagem de boas-vindas ao domínio foi exibida.
- [ ] Computador foi reiniciado.

### Depois do ingresso

- [ ] `PartOfDomain` retorna `True`.
- [ ] Usuário foi criado no Active Directory.
- [ ] Login funciona com `COUDE\usuario`.
- [ ] `whoami` mostra o domínio `COUDE`.
- [ ] `LOGONSERVER` aponta para `SRV1`.
- [ ] `\\srv1.ad.coude.com.br\turmas` abre corretamente.
- [ ] GPOs foram atualizadas com `gpupdate /force`.
- [ ] Unidade de rede aparece quando aplicável.

---

## 19. Fluxo resumido

```text
1. Conectar o Windows à mesma rede do servidor
2. Identificar a interface ativa
3. Configurar 192.168.1.10 como único DNS
4. Corrigir o DNS IPv6, se estiver usando fe80::1
5. Validar A, SRV e nltest
6. Ingressar em ad.coude.com.br
7. Reiniciar
8. Cadastrar ou confirmar o usuário no Active Directory
9. Entrar como COUDE\usuario
10. Acessar \\srv1.ad.coude.com.br\turmas
```

---

## 20. Referência rápida

```text
Domínio:       ad.coude.com.br
Realm:         AD.COUDE.COM.BR
NetBIOS:       COUDE
Controlador:   srv1.ad.coude.com.br
IP/DNS:        192.168.1.10
API:           http://192.168.1.10:8080/api/v1
Compartilhado: \\srv1.ad.coude.com.br\turmas
Administrador: Administrator@ad.coude.com.br
Login comum:   COUDE\usuario
```
