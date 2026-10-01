# common.ps1 - variaveis e funcoes compartilhadas pelos scripts dos experimentos.
# Nao e executado diretamente: os outros scripts o carregam com ". common.ps1".
# (Arquivo em ASCII de proposito, para nao quebrar acentos no PowerShell 5.1.)

$NS      = "primos"
$LABEL   = "app=api-primos"
$EvidDir = Join-Path $PSScriptRoot "..\evidencias"

# Escreve uma linha com horario (com milissegundos) no terminal.
function Log {
    param([string]$Mensagem)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $Mensagem)
}

# Comeca a gravar TUDO que aparece no terminal em evidencias\<nome>-<data>.txt
function Iniciar-Evidencia {
    param([string]$Nome)
    if (-not (Test-Path $EvidDir)) { New-Item -ItemType Directory -Path $EvidDir | Out-Null }
    $arquivo = Join-Path $EvidDir ("{0}-{1}.txt" -f $Nome, (Get-Date -Format "yyyyMMdd-HHmmss"))
    Start-Transcript -Path $arquivo | Out-Null
    Log "Evidencia sendo gravada em: $arquivo"
}

function Finalizar-Evidencia {
    Stop-Transcript | Out-Null
}

# Retorna os pods da aplicacao como objetos simples (Nome, Fase, Pronto, Terminando, Restarts, IP).
function Get-PodsApp {
    $json = kubectl get pods -n $NS -l $LABEL -o json | ConvertFrom-Json
    $saida = @()
    foreach ($p in $json.items) {
        $cs = $p.status.containerStatuses
        $saida += [pscustomobject]@{
            Nome       = $p.metadata.name
            Fase       = $p.status.phase
            Pronto     = [bool]($cs -and $cs[0].ready)
            Terminando = [bool]$p.metadata.deletionTimestamp
            Restarts   = $(if ($cs) { [int]$cs[0].restartCount } else { 0 })
            IP         = $p.status.podIP
        }
    }
    return $saida
}