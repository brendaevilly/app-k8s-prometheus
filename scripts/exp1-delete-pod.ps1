# Experimento 1 - Delecao de Pod
# Deleta um pod e mede quanto tempo o Kubernetes leva para ter de volta
# o numero desejado de pods prontos (Ready).
# Uso (na raiz do projeto):  .\scripts\exp1-delete-pod.ps1

. "$PSScriptRoot\common.ps1"
Iniciar-Evidencia "exp1-delete-pod"

$desejado = [int](kubectl get deploy api-primos -n $NS -o jsonpath='{.spec.replicas}')

Log "=== ESTADO INICIAL ==="
kubectl get pods -n $NS -l $LABEL -o wide

$antes = @(Get-PodsApp | Where-Object { -not $_.Terminando })
if ($antes.Count -eq 0) { Log "Nenhum pod encontrado. Aplique os manifestos primeiro."; Finalizar-Evidencia; exit 1 }
$nomesAntes = $antes | ForEach-Object { $_.Nome }
$alvo = $nomesAntes[0]

Log "Pod escolhido para deletar: $alvo"
Log "Replicas desejadas: $desejado"
Log "=== DELETANDO (T0) ==="

$sw = [System.Diagnostics.Stopwatch]::StartNew()
kubectl delete pod $alvo -n $NS --wait=false

$tCriado = $null; $tRunning = $null; $tPronto = $null; $tRecuperado = $null
$mostrouTabela = $false

while ($sw.Elapsed.TotalSeconds -lt 180) {
    $atuais = @(Get-PodsApp)
    $t = $sw.Elapsed.TotalSeconds
    $novo = $atuais | Where-Object { ($nomesAntes -notcontains $_.Nome) -and (-not $_.Terminando) } | Select-Object -First 1

    if ($novo -and ($null -eq $tCriado)) {
        $tCriado = $t
        Log ("Novo pod criado automaticamente: {0}  (+{1:N1}s)" -f $novo.Nome, $t)
    }
    if ($novo -and ($null -eq $tRunning) -and $novo.Fase -eq "Running") {
        $tRunning = $t
        Log ("Novo pod em Running: {0}  (+{1:N1}s)" -f $novo.Nome, $t)
    }
    if ($novo -and ($null -eq $tPronto) -and $novo.Pronto) {
        $tPronto = $t
        Log ("Novo pod Ready (1/1): {0}  (+{1:N1}s)" -f $novo.Nome, $t)
    }
    if ($novo -and (-not $mostrouTabela)) {
        $mostrouTabela = $true
        Log "--- Snapshot: pod antigo Terminating + pod novo subindo ---"
        kubectl get pods -n $NS -l $LABEL
    }

    $prontos = @($atuais | Where-Object { $_.Pronto -and (-not $_.Terminando) }).Count
    if (($null -ne $tPronto) -and ($prontos -ge $desejado)) { $tRecuperado = $t; break }
    Start-Sleep -Milliseconds 500
}

Log "=== ESTADO FINAL ==="
kubectl get pods -n $NS -l $LABEL -o wide

Log "=== EVENTOS RECENTES (mostram Killing / Scheduled / Started) ==="
kubectl get events -n $NS --sort-by=.lastTimestamp | Select-Object -Last 12

Log "=== RESULTADO ==="
if ($null -ne $tCriado)  { Log ("Pod deletado -> novo pod criado : {0:N1} s" -f $tCriado) }
if ($null -ne $tRunning) { Log ("Pod deletado -> novo pod Running: {0:N1} s" -f $tRunning) }
if ($null -ne $tPronto)  { Log ("Pod deletado -> novo pod Ready  : {0:N1} s" -f $tPronto) }
if ($null -ne $tRecuperado) {
    Log ("TEMPO DE RECUPERACAO (delete ate {0}/{0} pods Ready): {1:N1} s" -f $desejado, $tRecuperado)
} else {
    Log "Nao recuperou dentro de 180 s (verifique com kubectl describe pod)."
}
Log "Obs.: precisao de ~0,5-1 s (intervalo de consulta + tempo do kubectl)."
Log "No Prometheus, consulte (aba Graph, janela de 15 min):"
Log '  count(kube_pod_status_phase{namespace="primos",phase="Running"})'
Log '  kube_pod_status_ready{namespace="primos",condition="true"}'

Finalizar-Evidencia