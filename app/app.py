"""
API de Primos - aplicação de teste para a Atividade 4 (Kubernetes + Prometheus).

Endpoints:
  /               informações da aplicação e do pod que respondeu
  /health         usado pela livenessProbe do Kubernetes
  /primo/<n>      verifica se n é primo (trabalho "de verdade", leve)
  /cpu            consome CPU de propósito (Experimento 3 - HPA)
  /crash          derruba o processo de propósito (Experimento 2)
  /metrics        métricas no formato Prometheus
"""
import os
import socket
import threading
import time

from flask import Flask, Response, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from waitress import serve

app = Flask(__name__)

# Dentro do Kubernetes, o hostname do container é o nome do pod.
# Assim cada resposta mostra qual pod atendeu (útil para ver o balanceamento).
POD = socket.gethostname()
INICIO = time.time()

REQUISICOES = Counter(
    "primos_requisicoes_total",
    "Total de requisicoes recebidas",
    ["endpoint", "status"],
)


@app.after_request
def contar_requisicao(resposta):
    endpoint = request.url_rule.rule if request.url_rule else "desconhecido"
    REQUISICOES.labels(endpoint=endpoint, status=resposta.status_code).inc()
    return resposta


@app.route("/")
def raiz():
    return jsonify(
        aplicacao="api-primos",
        versao="1.0",
        pod=POD,
        uptime_segundos=round(time.time() - INICIO, 1),
    )


@app.route("/health")
def health():
    return jsonify(status="ok", pod=POD)


@app.route("/primo/<int:n>")
def primo(n):
    if n > 10**12:
        return jsonify(erro="n muito grande (maximo 10^12)"), 400
    if n < 2:
        return jsonify(n=n, primo=False, pod=POD)
    i = 2
    while i * i <= n:
        if n % i == 0:
            return jsonify(n=n, primo=False, divisor=i, pod=POD)
        i += 1
    return jsonify(n=n, primo=True, pod=POD)


@app.route("/cpu")
def cpu():
    """Mantém a CPU ocupada por N segundos (padrão 5, máximo 60)."""
    segundos = min(request.args.get("segundos", default=5, type=float), 60)
    fim = time.perf_counter() + segundos
    contador = 0
    while time.perf_counter() < fim:
        contador += 1  # loop ocupado, só para gastar CPU
    return jsonify(mensagem="CPU consumida", segundos=segundos, pod=POD)


@app.route("/crash")
def crash():
    """Derruba o processo (e portanto o container) logo após responder."""
    threading.Timer(0.5, lambda: os._exit(1)).start()
    return jsonify(mensagem="o processo vai encerrar em 0.5s", pod=POD)


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    porta = int(os.environ.get("PORT", "8080"))
    print(f"api-primos iniciando na porta {porta} (pod {POD})", flush=True)
    serve(app, host="0.0.0.0", port=porta, threads=8)