#Requires -RunAsAdministrator

param(
    [string]$NomeDoComputador
)

$ErrorActionPreference = "Stop"

$Dominio = "ad.coude.com.br"
$ControladorDominio = "srv1.ad.coude.com.br"
$ServidorDNS = "192.168.1.10"
$UsuarioDominio = "Administrator@ad.coude.com.br"

function Obter-AdaptadorAtivo {
    $RotaPadrao = Get-NetRoute `
        -AddressFamily IPv4 `
        -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1

    if ($null -ne $RotaPadrao) {
        $Adaptador = Get-NetAdapter `
            -InterfaceIndex $RotaPadrao.InterfaceIndex `
            -ErrorAction SilentlyContinue

        if ($null -ne $Adaptador -and $Adaptador.Status -eq "Up") {
            return $Adaptador
        }
    }

    return Get-NetAdapter |
        Where-Object {
            $_.Status -eq "Up" -and $_.HardwareInterface
        } |
        Select-Object -First 1
}

function Testar-CanalSeguro {
    try {
        $Resultado = Test-ComputerSecureChannel `
            -Server $ControladorDominio `
            -ErrorAction Stop

        return [bool]$Resultado
    }
    catch {
        return $false
    }
}

try {
    Write-Host "COUDE - Configuracao de dominio"
    Write-Host "--------------------------------"

    $EdicaoWindows = (Get-CimInstance Win32_OperatingSystem).Caption

    if ($EdicaoWindows -match "Home") {
        throw "O Windows Home nao pode ingressar em um dominio Active Directory."
    }

    $Sistema = Get-CimInstance Win32_ComputerSystem

    if ($Sistema.PartOfDomain) {
        if ($Sistema.Domain -ine $Dominio) {
            throw "Este computador ja pertence ao dominio $($Sistema.Domain)."
        }

        Write-Host "Este computador ja pertence ao dominio $Dominio."
        Write-Host "Estacao: $env:COMPUTERNAME"
        Write-Host "Verificando a relacao de confianca..."

        if (Testar-CanalSeguro) {
            Write-Host "A relacao de confianca esta integra."
            exit 0
        }

        Write-Warning "A relacao de confianca esta quebrada."
        Write-Warning "Confirme que nenhum outro computador usa o nome $env:COMPUTERNAME."

        $Confirmacao = Read-Host "Digite REPARAR para reparar esta estacao"

        if ($Confirmacao -ine "REPARAR") {
            throw "Reparo cancelado."
        }

        $Credencial = Get-Credential `
            -UserName $UsuarioDominio `
            -Message "Informe a senha do administrador do dominio"

        Write-Host "Reparando a relacao de confianca..."

        $Reparado = Test-ComputerSecureChannel `
            -Repair `
            -Server $ControladorDominio `
            -Credential $Credencial `
            -ErrorAction Stop

        if (-not $Reparado) {
            throw "Nao foi possivel reparar a relacao de confianca. Verifique se existe outro computador com o mesmo nome."
        }

        if (-not (Testar-CanalSeguro)) {
            throw "O reparo terminou, mas o canal seguro continua invalido."
        }

        Write-Host "Relacao de confianca reparada."
        Write-Host "O computador sera reiniciado em 10 segundos."

        Start-Sleep -Seconds 10
        Restart-Computer -Force
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($NomeDoComputador)) {
        $NomeDoComputador = Read-Host "Informe um nome exclusivo, por exemplo COUDE-PC-01"
    }

    $NomeDoComputador = $NomeDoComputador.Trim().ToUpperInvariant()

    if ($NomeDoComputador.Length -gt 15) {
        throw "O nome do computador deve ter no maximo 15 caracteres."
    }

    if ($NomeDoComputador -notmatch "^[A-Z0-9][A-Z0-9-]*[A-Z0-9]$") {
        if ($NomeDoComputador -notmatch "^[A-Z0-9]$") {
            throw "Use apenas letras, numeros e hifens. O nome nao pode comecar ou terminar com hifen."
        }
    }

    if ($NomeDoComputador -in @(
        "PC",
        "DESKTOP",
        "WINDOWS",
        "COMPUTADOR",
        "COUDE-PC"
    )) {
        throw "Escolha um nome especifico e exclusivo, como COUDE-PC-01."
    }

    Write-Host "Nome atual: $env:COMPUTERNAME"
    Write-Host "Novo nome:  $NomeDoComputador"
    Write-Warning "Este nome nao pode estar sendo usado por outro computador."

    $Confirmacao = Read-Host "Digite SIM para continuar"

    if ($Confirmacao -ine "SIM") {
        throw "Operacao cancelada."
    }

    $Adaptador = Obter-AdaptadorAtivo

    if ($null -eq $Adaptador) {
        throw "Nenhum adaptador de rede ativo foi encontrado."
    }

    Write-Host "Adaptador ativo: $($Adaptador.Name)"
    Write-Host "Configurando o DNS $ServidorDNS..."

    Set-DnsClientServerAddress `
        -InterfaceIndex $Adaptador.IfIndex `
        -ServerAddresses $ServidorDNS

    $DNSIPv6 = @(
        (Get-DnsClientServerAddress `
            -InterfaceIndex $Adaptador.IfIndex `
            -AddressFamily IPv6 `
            -ErrorAction SilentlyContinue).ServerAddresses
    )

    if ($DNSIPv6 -contains "fe80::1") {
        Write-Host "DNS IPv6 fe80::1 detectado."
        Write-Host "Desabilitando IPv6 temporariamente..."

        Disable-NetAdapterBinding `
            -Name $Adaptador.Name `
            -ComponentID "ms_tcpip6" |
            Out-Null
    }

    Clear-DnsClientCache

    Write-Host "Testando o servidor..."

    $RespostaPing = Test-Connection `
        -ComputerName $ServidorDNS `
        -Count 2 `
        -ErrorAction SilentlyContinue

    if ($null -eq $RespostaPing) {
        throw "O servidor $ServidorDNS nao respondeu ao ping."
    }

    Write-Host "Validando o registro DNS do controlador..."

    $RegistroA = Resolve-DnsName `
        -Name $ControladorDominio `
        -Type A `
        -Server $ServidorDNS `
        -DnsOnly

    $Enderecos = @($RegistroA | ForEach-Object { $_.IPAddress })

    if ($ServidorDNS -notin $Enderecos) {
        throw "$ControladorDominio nao aponta para $ServidorDNS."
    }

    Write-Host "Validando o registro LDAP do dominio..."

    $RegistroSRV = Resolve-DnsName `
        -Name "_ldap._tcp.dc._msdcs.$Dominio" `
        -Type SRV `
        -Server $ServidorDNS `
        -DnsOnly

    if ($null -eq $RegistroSRV) {
        throw "O registro SRV LDAP nao foi encontrado."
    }

    foreach ($Porta in @(53, 88, 389, 445)) {
        Write-Host "Testando a porta TCP $Porta..."

        $TestePorta = Test-NetConnection `
            -ComputerName $ServidorDNS `
            -Port $Porta `
            -WarningAction SilentlyContinue

        if (-not $TestePorta.TcpTestSucceeded) {
            throw "A porta TCP $Porta nao esta acessivel em $ServidorDNS."
        }
    }

    Write-Host "Localizando o controlador de dominio..."

    & nltest.exe "/dsgetdc:$Dominio" "/force"

    if ($LASTEXITCODE -ne 0) {
        throw "O Windows nao conseguiu localizar o dominio $Dominio."
    }

    $Credencial = Get-Credential `
        -UserName $UsuarioDominio `
        -Message "Informe a senha do administrador do dominio"

    Write-Host "Ingressando $NomeDoComputador no dominio $Dominio..."

    Add-Computer `
        -DomainName $Dominio `
        -Server $ControladorDominio `
        -NewName $NomeDoComputador `
        -Credential $Credencial `
        -Options AccountCreate, JoinWithNewName `
        -Force `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "Ingresso concluido com sucesso."
    Write-Host "Estacao: $NomeDoComputador"
    Write-Host "Dominio: $Dominio"
    Write-Host "O computador sera reiniciado em 15 segundos."

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
