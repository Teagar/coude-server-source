#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName
)

$ErrorActionPreference = "Stop"

$Domain = "ad.coude.com.br"
$DomainController = "srv1.ad.coude.com.br"
$DnsServer = "192.168.1.10"
$DomainUser = "Administrator@ad.coude.com.br"

function Get-ActiveAdapter {
    $DefaultRoute = Get-NetRoute `
        -AddressFamily IPv4 `
        -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

    if ($DefaultRoute) {
        $Adapter = Get-NetAdapter `
            -InterfaceIndex $DefaultRoute.InterfaceIndex `
            -ErrorAction SilentlyContinue

        if ($Adapter -and $Adapter.Status -eq "Up") {
            return $Adapter
        }
    }

    return Get-NetAdapter |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.HardwareInterface
        } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1
}

try {
    $WindowsEdition = (Get-ComputerInfo).WindowsProductName

    if ($WindowsEdition -match "\bHome\b") {
        throw "O Windows Home não pode ingressar em um domínio Active Directory."
    }

    $ComputerSystem = Get-CimInstance Win32_ComputerSystem

    if ($ComputerSystem.PartOfDomain) {
        if ($ComputerSystem.Domain -ine $Domain) {
            throw "Este computador já pertence ao domínio $($ComputerSystem.Domain)."
        }

        Write-Host "Este computador já pertence ao domínio $Domain."
        Write-Host "Verificando a relação de confiança..."

        if (Test-ComputerSecureChannel -Server $DomainController -Quiet) {
            Write-Host "A relação de confiança está íntegra."
            exit 0
        }

        Write-Warning "A relação de confiança está quebrada."

        $Credential = Get-Credential `
            -UserName $DomainUser `
            -Message "Informe a senha do administrador para reparar esta estação"

        Write-Host "Reparando o canal seguro de $env:COMPUTERNAME..."

        $Repaired = Test-ComputerSecureChannel `
            -Repair `
            -Server $DomainController `
            -Credential $Credential

        if (-not $Repaired) {
            throw @"
Não foi possível reparar a relação de confiança.

Verifique se outro computador está usando o nome:
$env:COMPUTERNAME

Se houver nome duplicado, não repare os dois com o mesmo nome.
Renomeie uma das estações e ingresse-a novamente no domínio.
"@
        }

        if (-not (Test-ComputerSecureChannel `
                    -Server $DomainController `
                    -Quiet)) {
            throw "O reparo foi executado, mas o canal seguro continua inválido."
        }

        Write-Host "Relação de confiança reparada."
        Write-Host "Reiniciando em 15 segundos..."

        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        $ComputerName = Read-Host `
            "Informe um nome EXCLUSIVO para este PC (ex.: COUDE-PC-01)"
    }

    $ComputerName = $ComputerName.Trim().ToUpperInvariant()

    if (
        $ComputerName -notmatch "^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$"
    ) {
        throw @"
Nome de computador inválido: $ComputerName

Use de 1 a 15 caracteres, apenas letras, números e hífen.
O nome não pode começar nem terminar com hífen.
Exemplo: COUDE-PC-01
"@
    }

    if ($ComputerName -in @(
        "DESKTOP",
        "COMPUTADOR",
        "WINDOWS",
        "COUDE-PC",
        "PC"
    )) {
        throw "Escolha um nome específico e exclusivo, como COUDE-PC-01."
    }

    Write-Host ""
    Write-Host "Nome atual: $env:COMPUTERNAME"
    Write-Host "Nome que será cadastrado: $ComputerName"
    Write-Host ""
    Write-Warning `
        "Não use este nome em nenhum outro computador do domínio."

    $Confirmation = Read-Host "Digite SIM para continuar"

    if ($Confirmation -ine "SIM") {
        throw "Operação cancelada."
    }

    $ActiveAdapter = Get-ActiveAdapter

    if (-not $ActiveAdapter) {
        throw "Nenhuma interface de rede ativa foi encontrada."
    }

    Write-Host "Interface ativa: $($ActiveAdapter.Name)"
    Write-Host "Configurando $DnsServer como DNS..."

    Set-DnsClientServerAddress `
        -InterfaceIndex $ActiveAdapter.IfIndex `
        -ServerAddresses $DnsServer

    $IPv6Dns = @(
        (
            Get-DnsClientServerAddress `
                -InterfaceIndex $ActiveAdapter.IfIndex `
                -AddressFamily IPv6
        ).ServerAddresses
    )

    if ($IPv6Dns -contains "fe80::1") {
        Write-Host `
            "DNS IPv6 fe80::1 detectado. Desabilitando IPv6 temporariamente..."

        Disable-NetAdapterBinding `
            -Name $ActiveAdapter.Name `
            -ComponentID ms_tcpip6 |
            Out-Null
    }

    Clear-DnsClientCache

    Write-Host "Testando comunicação com o servidor..."

    if (-not (Test-Connection `
                -ComputerName $DnsServer `
                -Count 2 `
                -Quiet)) {
        throw "O servidor $DnsServer não respondeu ao ping."
    }

    Write-Host "Validando o registro DNS do controlador..."

    $ARecord = Resolve-DnsName `
        -Name $DomainController `
        -Type A `
        -Server $DnsServer `
        -DnsOnly

    if ($DnsServer -notin @($ARecord.IPAddress)) {
        throw "$DomainController não aponta para $DnsServer."
    }

    Write-Host "Validando o serviço LDAP..."

    $SrvRecord = Resolve-DnsName `
        -Name "_ldap._tcp.dc._msdcs.$Domain" `
        -Type SRV `
        -Server $DnsServer `
        -DnsOnly

    if (-not $SrvRecord) {
        throw "O registro SRV LDAP do domínio não foi encontrado."
    }

    foreach ($Port in 53, 88, 389, 445) {
        Write-Host "Testando a porta TCP $Port..."

        $Open = Test-NetConnection `
            -ComputerName $DnsServer `
            -Port $Port `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue

        if (-not $Open) {
            throw "A porta TCP $Port não está acessível em $DnsServer."
        }
    }

    Write-Host "Localizando o controlador de domínio..."

    & nltest.exe "/dsgetdc:$Domain" "/force"

    if ($LASTEXITCODE -ne 0) {
        throw "O Windows não conseguiu localizar o domínio $Domain."
    }

    Write-Host ""
    Write-Host "Antes de continuar, confirme que '$ComputerName' nunca foi"
    Write-Host "atribuído a outra estação ativa."

    $Credential = Get-Credential `
        -UserName $DomainUser `
        -Message "Informe a senha do administrador do domínio COUDE"

    Write-Host "Ingressando $ComputerName no domínio $Domain..."

    Add-Computer `
        -DomainName $Domain `
        -Server $DomainController `
        -NewName $ComputerName `
        -Credential $Credential `
        -Options AccountCreate, JoinWithNewName `
        -Force

    Write-Host ""
    Write-Host "Ingresso concluído com sucesso."
    Write-Host "Estação: $ComputerName"
    Write-Host "Domínio: $Domain"
    Write-Host "Reiniciando em 15 segundos..."

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
