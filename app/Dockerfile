# Imagem base leve com Python
FROM python:3.12-slim

# Logs sem buffer (aparecem na hora em "kubectl logs") e sem arquivos .pyc
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Copiar só o requirements primeiro aproveita o cache do Docker:
# as dependências só são reinstaladas se esse arquivo mudar.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Roda como usuário comum (boa prática de segurança)
RUN useradd --no-create-home appuser
USER appuser

EXPOSE 8080

CMD ["python", "app.py"]