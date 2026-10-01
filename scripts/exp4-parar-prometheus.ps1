# Experimento 4 - Interrupcao do Monitoramento
# Para o Prometheus por alguns instantes, testa se a aplicacao continua respondendo
# e depois religa o Prometheus.
# Uso (na raiz do projeto):  .\scripts\exp4-parar-prometheus.ps1
# Parametro opcional: -DuracaoQueda 90   (segundos com o Prometheus parado)

param(
    [int]$DuracaoQueda = 90
)

. "$PSScriptRoot\common.ps1"
Iniciar-Evidencia "exp4-parar-prometheus"

$NSMON   = "monitoring"
$PROMCR  = "monitoring-kube-prometheus-prometheus"   # recurso "Prometheus" gerenciado pelo operator
$PROMLBL = "app.kubernetes.io/name=prometheus"

function Get-PodsProm {
    $json = kubectl get pods -n $NSMON -l $PROMLBL -o json | ConvertFrom-Json
    $saida = @()
    foreach ($p in $json.items) {
        $cs = $p.status.containerStatuses
        $pronto = $false
        if ($cs) { $pronto = -not ($cs | Where-Object { -not $_.ready }) }
        $saida += [pscustomobject]@{ Nome = $p.metadata.name; Pronto = [bool]$pronto }
    }
    return $saida
}

# Altera o numero de replicas do Prometheus (via recurso do operator, que atualiza o StatefulSet)
function Set-ReplicasProm {
    param([int]$N)
    $arq = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $arq -Value ('{"spec":{"replicas":' + $N + '}}') -Encoding ascii
    kubectl patch prometheus $PROMCR -n $NSMON --type merge --patch-file $arq
    Remove-Item $arq -ErrorAction SilentlyContinue
}

# Chama a aplicacao por dentro do cluster, passando pelo Service (nao depende de port-forward)
function Testar-App {
    $py = "import urllib.request; print(urllib.request.urlopen('http://api-primos/primo/97').read().decode())"
    $saida = kubectl exec -n $NS deploy/api-primos -- python -c $py 2>&1
    return ($saida | Out-String).Trim()
}

Log "=== ESTADO INICIAL ==="
kubectl get pods -n $NSMON -l $PROMLBL
kubectl get pods -n $NS -l $LABEL
Log ("Aplicacao respondendo: " + (Testar-App))

# ---------- PARANDO O PROMETHEUS ----------
Log "=== PARANDO O PROMETHEUS (T0) ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Set-ReplicasProm 0

while ($sw.Elapsed.TotalSeconds -lt 120) {
    $n = @(Get-PodsProm).Count
    if ($n -eq 0) { break }
    Start-Sleep -Seconds 2
}
$tParado = $sw.Elapsed.TotalSeconds
Log ("Prometheus fora do ar (+{0:N0}s). Pods do Prometheus:" -f $tParado)
kubectl get pods -n $NSMON -l $PROMLBL
Log "Se o port-forward da porta 9090 estava aberto, ele caiu. A interface em localhost:9090 nao abre mais."

# ---------- APLICACAO DURANTE A INTERRUPCAO ----------
Log "=== APLICACAO DURANTE A INTERRUPCAO (por $DuracaoQueda s) ==="
$inicioQueda = Get-Date
$mostrouPods = $false
while (((Get-Date) - $inicioQueda).TotalSeconds -lt $DuracaoQueda) {
    Log ("Resposta da aplicacao: " + (Testar-App))
    if (-not $mostrouPods) {
        kubectl get pods -n $NS -l $LABEL
        $mostrouPods = $true
    }
    Start-Sleep -Seconds 10
}
Log "Aplicacao seguiu atendendo normalmente sem o Prometheus."

# ---------- RELIGANDO ----------
Log "=== RELIGANDO O PROMETHEUS (T1) ==="
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
Set-ReplicasProm 1

$tVoltou = $null
while ($sw2.Elapsed.TotalSeconds -lt 300) {
    $p = @(Get-PodsProm) | Select-Object -First 1
    if ($p -and $p.Pronto) { $tVoltou = $sw2.Elapsed.TotalSeconds; break }
    Start-Sleep -Seconds 3
}

Log "=== ESTADO FINAL ==="
kubectl get pods -n $NSMON -l $PROMLBL
kubectl get pvc -n $NSMON

Log "=== RESULTADO ==="
Log ("Duracao da interrupcao (Prometheus parado): ~{0:N0} s" -f $DuracaoQueda)
if ($null -ne $tVoltou) { Log ("Religar -> Prometheus Ready de novo: {0:N0} s" -f $tVoltou) }
else { Log "Prometheus nao ficou Ready em 300 s (verifique: kubectl describe pod -n monitoring)." }
Log "PROXIMOS PASSOS MANUAIS:"
Log "  1. Reabra o port-forward:  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
Log "  2. No Prometheus (aba Graph, janela de 15 min), consulte:  up{namespace=""primos""}"
Log "     e  primos_requisicoes_total   -> deve haver um BURACO no periodo da interrupcao."
Log "  3. Tire print do grafico mostrando o buraco e a retomada."

Finalizar-Evidencia