# Experimento 2 - Falha no Container
# Chama /crash em um pod (o processo encerra com exit 1) e observa o Kubernetes
# REINICIAR O CONTAINER no mesmo pod: o RESTARTS sobe, nome e IP continuam iguais.
# Uso (na raiz do projeto):  .\scripts\exp2-crash-container.ps1

. "$PSScriptRoot\common.ps1"
Iniciar-Evidencia "exp2-crash-container"

Log "=== ESTADO INICIAL ==="
kubectl get pods -n $NS -l $LABEL -o wide

$alvoObj = @(Get-PodsApp | Where-Object { $_.Pronto -and (-not $_.Terminando) }) | Select-Object -First 1
if (-not $alvoObj) { Log "Nenhum pod pronto encontrado."; Finalizar-Evidencia; exit 1 }

$alvo = $alvoObj.Nome
$restartsAntes = $alvoObj.Restarts
$ipAntes = $alvoObj.IP
Log "Pod alvo: $alvo (IP $ipAntes, RESTARTS = $restartsAntes)"

Log "=== PROVOCANDO A FALHA (T0) ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$py = "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/crash').read().decode())"
kubectl exec -n $NS $alvo -- python -c $py
Log "Chamada a /crash enviada. O processo encerra em ~0,5 s."

$tReiniciou = $null; $tPronto = $null
$ultimo = ""

while ($sw.Elapsed.TotalSeconds -lt 120) {
    $p = @(Get-PodsApp) | Where-Object { $_.Nome -eq $alvo } | Select-Object -First 1
    $t = $sw.Elapsed.TotalSeconds
    if ($p) {
        $estado = "fase={0} pronto={1} RESTARTS={2}" -f $p.Fase, $p.Pronto, $p.Restarts
        if ($estado -ne $ultimo) { Log ("(+{0:N1}s) {1}" -f $t, $estado); $ultimo = $estado }
        if (($null -eq $tReiniciou) -and ($p.Restarts -gt $restartsAntes)) {
            $tReiniciou = $t
            Log ("RESTARTS aumentou: {0} -> {1}  (+{2:N1}s)" -f $restartsAntes, $p.Restarts, $t)
        }
        if (($null -ne $tReiniciou) -and $p.Pronto) { $tPronto = $t; break }
    }
    Start-Sleep -Milliseconds 500
}

Log "=== ESTADO FINAL ==="
kubectl get pods -n $NS -l $LABEL -o wide

$depois = @(Get-PodsApp) | Where-Object { $_.Nome -eq $alvo } | Select-Object -First 1
Log "=== PROVA: MESMO POD, CONTAINER REINICIADO ==="
Log ("Nome  antes/depois: {0} / {1}" -f $alvo, $depois.Nome)
Log ("IP    antes/depois: {0} / {1}" -f $ipAntes, $depois.IP)
Log ("RESTARTS antes/depois: {0} / {1}" -f $restartsAntes, $depois.Restarts)

Log "=== DETALHES DO ULTIMO ENCERRAMENTO (kubectl describe) ==="
kubectl describe pod $alvo -n $NS | Select-String -Pattern "Last State|Reason|Exit Code|Restart Count|Started:|Finished:"

Log "=== LOG DO CONTAINER ANTERIOR (o que morreu) ==="
kubectl logs $alvo -n $NS --previous --tail=5

Log "=== RESULTADO ==="
if ($null -ne $tReiniciou) { Log ("Falha provocada -> RESTARTS incrementado: {0:N1} s" -f $tReiniciou) }
if ($null -ne $tPronto)    { Log ("Falha provocada -> container Ready de novo: {0:N1} s" -f $tPronto) }
Log "No Prometheus consulte:"
Log '  kube_pod_container_status_restarts_total{namespace="primos"}'

Finalizar-Evidencia