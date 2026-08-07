#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$Domain = "ad.coude.com.br"
$DomainController = "srv1.ad.coude.com.br"
$DnsServer = "192.168.1.10"
$DomainUser = "Administrator@ad.coude.com.br"

try {
    $WindowsEdition = (Get-ComputerInfo).WindowsProductName

    if ($WindowsEdition -match "Home") {
        throw "O Windows Home não pode ingressar em um domínio Active Directory."
    }

    $ComputerSystem = Get-CimInstance Win32_ComputerSystem

    if ($ComputerSystem.PartOfDomain) {
        if ($ComputerSystem.Domain -ieq $Domain) {
            Write-Host "Este computador já pertence ao domínio $Domain."
            exit 0
        }

        throw "Este computador já pertence ao domínio $($ComputerSystem.Domain)."
    }

    $ActiveAdapter = Get-NetAdapter |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.HardwareInterface
        } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1

    if (-not $ActiveAdapter) {
        throw "Nenhuma interface física de rede ativa foi encontrada."
    }

    Write-Host "Interface ativa: $($ActiveAdapter.Name)"
    Write-Host "Configurando $DnsServer como DNS..."

    Set-DnsClientServerAddress `
        -InterfaceIndex $ActiveAdapter.IfIndex `
        -ServerAddresses $DnsServer

    $IPv6Dns = (
        Get-DnsClientServerAddress `
            -InterfaceIndex $ActiveAdapter.IfIndex `
            -AddressFamily IPv6
    ).ServerAddresses

    if ($IPv6Dns -contains "fe80::1") {
        Write-Host "DNS IPv6 fe80::1 detectado. Desabilitando IPv6 temporariamente..."

        Disable-NetAdapterBinding `
            -Name $ActiveAdapter.Name `
            -ComponentID ms_tcpip6
    }

    Clear-DnsClientCache

    Write-Host "Testando comunicação com o servidor..."

    if (-not (Test-Connection -ComputerName $DnsServer -Count 2 -Quiet)) {
        throw "O servidor $DnsServer não respondeu ao ping."
    }

    Write-Host "Validando o registro DNS do controlador..."

    $ARecord = Resolve-DnsName `
        -Name $DomainController `
        -Type A `
        -Server $DnsServer `
        -DnsOnly

    if ($DnsServer -notin $ARecord.IPAddress) {
        throw "$DomainController não aponta para $DnsServer."
    }

    Write-Host "Validando o serviço LDAP do domínio..."

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

        if (-not (Test-NetConnection $DnsServer -Port $Port `
                    -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            throw "A porta TCP $Port não está acessível em $DnsServer."
        }
    }

    Write-Host "Localizando o controlador de domínio..."

    & nltest.exe "/dsgetdc:$Domain" "/force"

    if ($LASTEXITCODE -ne 0) {
        throw "O Windows não conseguiu localizar o domínio $Domain."
    }

    $Credential = Get-Credential `
        -UserName $DomainUser `
        -Message "Informe a senha do administrador do domínio COUDE"

    Write-Host "Ingressando o computador no domínio $Domain..."

    Add-Computer `
        -DomainName $Domain `
        -Credential $Credential `
        -Force

    Write-Host ""
    Write-Host "O computador ingressou com sucesso no domínio $Domain."
    Write-Host "Ele será reiniciado em 15 segundos."
    Write-Host "Após reiniciar, entre como COUDE\usuario."

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
