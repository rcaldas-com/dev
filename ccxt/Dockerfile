FROM python:3.12-slim AS base
LABEL maintainer="RCaldas <docker@rcaldas.com>"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Instala as dependências num prefixo isolado para copiar só elas ao final,
# deixando o cache do pip e ferramentas de build fora da imagem publicada.
FROM base AS deps
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM base AS runner
WORKDIR /app

COPY --from=deps /install /usr/local
COPY app.py .

RUN adduser --system --no-create-home --uid 1001 ccxt
USER ccxt

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
