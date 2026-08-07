#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$NovoNome
)

$ErrorActionPreference = "Stop"

$Domain = "ad.coude.com.br"
$DomainController = "srv1.ad.coude.com.br"
$DnsServer = "192.168.1.10"
$DomainUser = "Administrator@ad.coude.com.br"
$JoinStatePath = "$env:ProgramData\COUDE\domain-join-state.json"

function Stop-WithError {
    param([string]$Message)

    throw $Message
}

function Test-TcpPort {
    param([int]$Port)

    return Test-NetConnection `
        -ComputerName $DnsServer `
        -Port $Port `
        -InformationLevel Quiet `
        -WarningAction SilentlyContinue
}

function Get-ActivePhysicalAdapter {
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

        if ($Adapter.Status -eq "Up" -and $Adapter.HardwareInterface) {
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
        Stop-WithError `
            "O Windows Home não pode ingressar em um domínio Active Directory."
    }

    $ComputerSystem = Get-CimInstance Win32_ComputerSystem
    $CurrentName = $env:COMPUTERNAME.ToUpperInvariant()

    if ($ComputerSystem.PartOfDomain) {
        if ($ComputerSystem.Domain -ine $Domain) {
            Stop-WithError `
                "Este computador já pertence ao domínio $($ComputerSystem.Domain)."
        }

        Write-Host "A máquina já pertence ao domínio. Verificando o canal seguro..."

        if (Test-ComputerSecureChannel -Server $DomainController -Quiet) {
            Write-Host "Canal seguro íntegro. Nenhuma alteração é necessária."
            exit 0
        }

        Write-Warning "O canal seguro desta máquina está quebrado."

        $Credential = Get-Credential `
            -UserName $DomainUser `
            -Message "Informe uma credencial autorizada a reparar esta estação"

        Write-Host "Reparando a conta de máquina $CurrentName..."

        $Repaired = Test-ComputerSecureChannel `
            -Repair `
            -Server $DomainController `
            -Credential $Credential

        if (-not $Repaired) {
            Stop-WithError `
                "Não foi possível reparar o canal seguro. Verifique se outra estação usa o nome $CurrentName."
        }

        if (-not (Test-ComputerSecureChannel `
                    -Server $DomainController `
                    -Quiet)) {
            Stop-WithError `
                "A reparação foi executada, mas o canal seguro continua inválido."
        }

        Write-Host "Canal seguro reparado. Reiniciando em 15 segundos..."
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit 0
    }

    if (-not $NovoNome) {
        do {
            $NovoNome = (
                Read-Host `
                    "Informe um nome EXCLUSIVO para este PC (ex.: COUDE-PC-01)"
            ).Trim().ToUpperInvariant()

            $NomeValido = (
                $NovoNome -match "^[A-Z0-9-]{1,15}$" -and
                $NovoNome -notmatch "^-|-$" -and
                $NovoNome -notin @(
                    "DESKTOP",
                    "COMPUTADOR",
                    "WINDOWS",
                    "COUDE-PC",
                    "PC"
                )
            )

            if (-not $NomeValido) {
                Write-Warning `
                    "Use de 1 a 15 caracteres: letras, números e hífen. O nome deve ser exclusivo."
            }
        } until ($NomeValido)
    }

    $NovoNome = $NovoNome.Trim().ToUpperInvariant()

    if (
        $NovoNome -notmatch "^[A-Z0-9-]{1,15}$" -or
        $NovoNome -match "^-|-$"
    ) {
        Stop-WithError `
            "Nome inválido. Use de 1 a 15 caracteres: letras, números e hífen."
    }

    $ActiveAdapter = Get-ActivePhysicalAdapter

    if (-not $ActiveAdapter) {
        Stop-WithError "Nenhuma interface física de rede ativa foi encontrada."
    }

    Write-Host "Interface ativa: $($ActiveAdapter.Name)"
    Write-Host "Configurando $DnsServer como único DNS IPv4..."

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

    if (
        $IPv6Dns |
        Where-Object {
            $_ -and
            $_ -ne "::1" -and
            $_ -notmatch "^fec0:0:0:ffff::"
        }
    ) {
        Write-Warning `
            "DNS IPv6 externo detectado: $($IPv6Dns -join ', '). Desabilitando IPv6 temporariamente."

        Disable-NetAdapterBinding `
            -Name $ActiveAdapter.Name `
            -ComponentID ms_tcpip6 | Out-Null
    }

    Clear-DnsClientCache

    if (-not (Test-Connection `
                -ComputerName $DnsServer `
                -Count 2 `
                -Quiet)) {
        Stop-WithError "O servidor $DnsServer não respondeu ao ping."
    }

    $ARecord = Resolve-DnsName `
        -Name $DomainController `
        -Type A `
        -Server $DnsServer `
        -DnsOnly

    if ($DnsServer -notin @($ARecord.IPAddress)) {
        Stop-WithError "$DomainController não aponta para $DnsServer."
    }

    $SrvRecord = Resolve-DnsName `
        -Name "_ldap._tcp.dc._msdcs.$Domain" `
        -Type SRV `
        -Server $DnsServer `
        -DnsOnly

    if (
        -not (
            $SrvRecord |
            Where-Object {
                $_.NameTarget.TrimEnd(".") -ieq $DomainController -and
                $_.Port -eq 389
            }
        )
    ) {
        Stop-WithError `
            "O registro SRV LDAP não aponta corretamente para $DomainController."
    }

    foreach ($Port in 53, 88, 389, 445) {
        Write-Host "Testando a porta TCP $Port..."

        if (-not (Test-TcpPort -Port $Port)) {
            Stop-WithError "A porta TCP $Port não está acessível em $DnsServer."
        }
    }

    Write-Host "Localizando o controlador de domínio..."

    & nltest.exe "/dsgetdc:$Domain" "/force"

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "O Windows não conseguiu localizar o domínio $Domain."
    }

    $Credential = Get-Credential `
        -UserName $DomainUser `
        -Message "Informe uma credencial autorizada a ingressar computadores"

    Write-Host "Verificando se o nome $NovoNome já existe no Active Directory..."

    $ExistingComputer = Get-ADComputer `
        -Identity "$NovoNome`$" `
        -Server $DomainController `
        -Credential $Credential `
        -ErrorAction SilentlyContinue

    if ($ExistingComputer) {
        Stop-WithError @"
A conta de computador '$NovoNome' já existe no Active Directory.
Não será sobrescrita, pois ela pode pertencer a outra estação.
Escolha outro nome exclusivo ou remova a conta antiga manualmente após confirmar que ela não está em uso.
"@
    }

    $StateDirectory = Split-Path $JoinStatePath -Parent
    New-Item `
        -ItemType Directory `
        -Path $StateDirectory `
        -Force | Out-Null

    [ordered]@{
        ComputerName = $NovoNome
        Domain       = $Domain
        JoinedAt     = (Get-Date).ToString("o")
    } |
        ConvertTo-Json |
        Set-Content `
            -Path $JoinStatePath `
            -Encoding UTF8

    Write-Host "Ingressando $NovoNome no domínio $Domain..."

    Add-Computer `
        -DomainName $Domain `
        -NewName $NovoNome `
        -Server $DomainController `
        -Credential $Credential `
        -Options JoinWithNewName, AccountCreate `
        -Force

    Write-Host ""
    Write-Host "Ingresso concluído."
    Write-Host "Nome da estação: $NovoNome"
    Write-Host "Domínio: $Domain"
    Write-Host "Reiniciando em 15 segundos..."

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
