# Experimento 3 - Sobrecarga de CPU (HPA)
# Cria um pod "carga" dentro do cluster que chama /cpu em loop pelo Service,
# observa o HPA aumentar as replicas, depois remove a carga e observa a reducao.
# Uso (na raiz do projeto):  .\scripts\exp3-carga-cpu.ps1
# Parametros opcionais: -Paralelismo 6  -TempoMaxCarga 360  -TempoMaxQueda 600

param(
    [int]$Paralelismo = 6,
    [int]$TempoMaxCarga = 360,
    [int]$TempoMaxQueda = 600
)

. "$PSScriptRoot\common.ps1"
Iniciar-Evidencia "exp3-carga-cpu"

function Get-EstadoHpa {
    $h = kubectl get hpa api-primos -n $NS -o json | ConvertFrom-Json
    $m = $h.status.currentMetrics
    $cpu = $null
    if ($m) { $cpu = $m[0].resource.current.averageUtilization }
    $prontos = @(Get-PodsApp | Where-Object { $_.Pronto -and (-not $_.Terminando) }).Count
    [pscustomobject]@{
        CPU      = $cpu
        Atual    = [int]$h.status.currentReplicas
        Desejado = [int]$h.status.desiredReplicas
        Prontos  = $prontos
        Min      = [int]$h.spec.minReplicas
        Max      = [int]$h.spec.maxReplicas
        Meta     = [int]$h.spec.metrics[0].resource.target.averageUtilization
    }
}

$amostras = New-Object System.Collections.ArrayList
function Registrar {
    param($Fase, $T, $E)
    Log ("[{0}] t={1,6:N0}s  CPU={2}%  replicas atual/desejado={3}/{4}  pods Ready={5}" -f $Fase, $T, $E.CPU, $E.Atual, $E.Desejado, $E.Prontos)
    [void]$amostras.Add([pscustomobject]@{
        Fase = $Fase; Segundos = [math]::Round($T, 1); CPU_percent = $E.CPU
        ReplicasAtual = $E.Atual; ReplicasDesejado = $E.Desejado; PodsReady = $E.Prontos
    })
}

Log "=== ESTADO INICIAL ==="
kubectl get hpa -n $NS
kubectl get pods -n $NS -l $LABEL
kubectl top pods -n $NS

$e0 = Get-EstadoHpa
$min = $e0.Min; $max = $e0.Max; $meta = $e0.Meta
Log "HPA: min=$min  max=$max  meta de CPU=$meta%"

# Garante que nao sobrou um pod de carga de uma execucao anterior
kubectl delete pod carga -n $NS --ignore-not-found --grace-period=1 | Out-Null

# Comando que roda dentro do pod de carga: N loops paralelos chamando /cpu (20 s cada)
$lista = (1..$Paralelismo) -join " "
$cmd = "for i in $lista; do (while true; do wget -q -O /dev/null 'http://api-primos/cpu?segundos=20'; done) & done; wait"

Log "Criando pod de carga ($Paralelismo requisicoes paralelas)..."
kubectl run carga -n $NS --image=busybox:1.36 --restart=Never -- sh -c $cmd | Out-Null
kubectl wait --for=condition=Ready pod/carga -n $NS --timeout=180s | Out-Null

# ---------- FASE 1: CARGA ----------
Log "=== CARGA INICIADA (T0) ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$marcos = @{}
$maxProntos = 0

while ($sw.Elapsed.TotalSeconds -lt $TempoMaxCarga) {
    $e = Get-EstadoHpa
    $t = $sw.Elapsed.TotalSeconds
    Registrar "carga" $t $e
    if ($e.Prontos -gt $maxProntos) { $maxProntos = $e.Prontos }

    if (($null -eq $marcos.CpuAcimaMeta) -and ($null -ne $e.CPU) -and ($e.CPU -gt $meta)) {
        $marcos.CpuAcimaMeta = $t; Log (">>> CPU acima da meta ({0}% > {1}%) em +{2:N0}s" -f $e.CPU, $meta, $t)
    }
    if (($null -eq $marcos.HpaDecidiu) -and ($e.Desejado -gt $min)) {
        $marcos.HpaDecidiu = $t; Log (">>> HPA decidiu aumentar replicas (desejado={0}) em +{1:N0}s" -f $e.Desejado, $t)
    }
    if (($null -eq $marcos.PrimeiroNovoReady) -and ($e.Prontos -gt $min)) {
        $marcos.PrimeiroNovoReady = $t; Log (">>> Primeiro pod novo Ready (Ready={0}) em +{1:N0}s" -f $e.Prontos, $t)
    }
    if (($null -eq $marcos.Maximo) -and ($e.Prontos -ge $max)) {
        $marcos.Maximo = $t; Log (">>> MAXIMO de pods atingido ({0}) em +{1:N0}s" -f $e.Prontos, $t)
        kubectl get pods -n $NS -l $LABEL
        kubectl top pods -n $NS
    }
    # depois de atingir o maximo, segura a carga mais 30 s para dar tempo de gravar evidencia
    if (($null -ne $marcos.Maximo) -and ($t -ge ($marcos.Maximo + 30))) { break }
    Start-Sleep -Seconds 5
}

Log "=== ESTADO COM CARGA ==="
kubectl get hpa -n $NS
kubectl get pods -n $NS -l $LABEL

# ---------- FASE 2: REMOVENDO A CARGA ----------
Log "=== CARGA REMOVIDA (T1) ==="
kubectl delete pod carga -n $NS --grace-period=1 --wait=false | Out-Null
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$tVolta = $null

while ($sw2.Elapsed.TotalSeconds -lt $TempoMaxQueda) {
    $e = Get-EstadoHpa
    $t = $sw2.Elapsed.TotalSeconds
    Registrar "queda" $t $e
    if (($null -eq $tVolta) -and ($e.Atual -le $min) -and ($e.Prontos -le $min)) {
        $tVolta = $t; Log (">>> Voltou ao minimo de {0} replicas em +{1:N0}s apos remover a carga" -f $min, $t)
        break
    }
    Start-Sleep -Seconds 5
}

Log "=== ESTADO FINAL ==="
kubectl get hpa -n $NS
kubectl get pods -n $NS -l $LABEL

# Salva as amostras em CSV (util para montar um grafico no relatorio)
$csv = Join-Path $EvidDir ("exp3-amostras-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$amostras | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Log "Amostras gravadas em: $csv"

Log "=== RESULTADO ==="
Log "Replicas: minimo=$min  maximo configurado=$max  maximo observado (Ready)=$maxProntos"
if ($null -ne $marcos.CpuAcimaMeta)     { Log ("Inicio da carga -> CPU acima da meta       : {0:N0} s" -f $marcos.CpuAcimaMeta) }
if ($null -ne $marcos.HpaDecidiu)       { Log ("Inicio da carga -> HPA decidiu escalar     : {0:N0} s" -f $marcos.HpaDecidiu) }
if ($null -ne $marcos.PrimeiroNovoReady){ Log ("TEMPO DE ESCALONAMENTO (ate 1o pod novo Ready): {0:N0} s" -f $marcos.PrimeiroNovoReady) }
if ($null -ne $marcos.Maximo)           { Log ("TEMPO ATE O MAXIMO DE PODS                  : {0:N0} s" -f $marcos.Maximo) }
if ($null -ne $tVolta)                  { Log ("Retirada da carga -> volta ao minimo        : {0:N0} s" -f $tVolta) }
Log "Obs.: precisao de ~5 s (intervalo de amostragem)."
Log "No Prometheus consulte:"
Log '  kube_horizontalpodautoscaler_status_current_replicas{namespace="primos"}'
Log '  kube_horizontalpodautoscaler_status_desired_replicas{namespace="primos"}'
Log '  sum(rate(container_cpu_usage_seconds_total{namespace="primos",container="api-primos"}[1m]))'

Finalizar-Evidencia