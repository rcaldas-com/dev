"""Microserviço de cotações baseado em ccxt.

Expõe o preço de 1 unidade de uma moeda em outra (por padrão BRL), tentando uma
lista ordenada de exchanges (Binance primária, mais fallbacks). Resolve o par
diretamente (ex.: BTC/BRL) ou roteando por USDT (ex.: XLM/USDT * USDT/BRL).
"""

import os
import time
import ccxt
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# Ordem de tentativa das exchanges. Binance tem pares BRL (BTCBRL, USDTBRL, ...),
# então cobre a "perna" para Real com boa liquidez; as demais servem de fallback.
EXCHANGE_IDS = [
    e.strip() for e in os.environ.get("CCXT_EXCHANGES", "binance,kraken,okx").split(",") if e.strip()
]
CACHE_TTL = float(os.environ.get("CCXT_CACHE_TTL", "10"))

# Moedas sem par próprio nas exchanges, resolvidas por um equivalente.
# USD não é negociado direto (o sistema antigo usava BUSD, hoje extinto);
# stablecoins de dólar servem de proxy 1:1.
COIN_ALIASES = {
    "USD": ["USDT", "USDC"],
    "BUSD": ["USDT", "USDC"],
}

app = FastAPI(title="ccxt-quotes")

_exchanges: dict[str, ccxt.Exchange] = {}
_ticker_cache: dict[tuple[str, str], tuple[float, float]] = {}


def get_exchange(eid: str) -> ccxt.Exchange:
    ex = _exchanges.get(eid)
    if ex is None:
        ex = getattr(ccxt, eid)({"enableRateLimit": True})
        ex.load_markets()
        _exchanges[eid] = ex
    return ex


def fetch_last(ex: ccxt.Exchange, symbol: str):
    """Último preço de um símbolo, com cache curto. None se o par não existir."""
    if symbol not in ex.markets:
        return None
    key = (ex.id, symbol)
    now = time.time()
    cached = _ticker_cache.get(key)
    if cached and now - cached[1] < CACHE_TTL:
        return cached[0]
    ticker = ex.fetch_ticker(symbol)
    price = ticker.get("last") or ticker.get("close")
    if price:
        _ticker_cache[key] = (price, now)
    return price


def price_on(ex: ccxt.Exchange, base: str, quote: str):
    """Preço de base/quote numa exchange: direto ou roteado por USDT."""
    direct = fetch_last(ex, f"{base}/{quote}")
    if direct:
        return direct
    if base != "USDT" and quote != "USDT":
        base_usdt = fetch_last(ex, f"{base}/USDT")
        if base_usdt:
            usdt_quote = fetch_last(ex, f"USDT/{quote}")
            if usdt_quote:
                return base_usdt * usdt_quote
            quote_usdt = fetch_last(ex, f"{quote}/USDT")
            if quote_usdt:
                return base_usdt / quote_usdt
    return None


def _resolve(base: str, quote: str):
    """Resolve base/quote numa única exchange (direto ou roteado por USDT nela),
    tentando cada exchange e os equivalentes conhecidos (COIN_ALIASES). Retorna
    {price, source} ou None. NÃO faz ponte entre exchanges (isso fica no
    endpoint), pra não recorrer infinitamente."""
    if base == quote:
        return {"price": 1.0, "source": "identity"}
    base_candidates = [base] + COIN_ALIASES.get(base, [])
    quote_candidates = [quote] + COIN_ALIASES.get(quote, [])
    for eid in EXCHANGE_IDS:
        try:
            ex = get_exchange(eid)
            for b in base_candidates:
                for q in quote_candidates:
                    if b == q:
                        continue
                    value = price_on(ex, b, q)
                    if value:
                        via = "" if (b == base and q == quote) else f" (via {b}/{q})"
                        return {"price": float(value), "source": f"{eid}{via}"}
        except Exception:  # noqa: BLE001 - tenta a próxima exchange
            continue
    return None


@app.get("/price")
def price(base: str, quote: str = "BRL"):
    base = base.upper()
    quote = quote.upper()

    # 1) Resolução direta (mesma exchange, direto ou via USDT).
    direct = _resolve(base, quote)
    if direct:
        return {"base": base, "quote": quote, **direct}

    # 2) Ponte cross-exchange via USD: base/USD e USD/quote podem vir de
    #    exchanges DIFERENTES (ex.: EUR/USD na Kraken × USD/BRL via USDT/BRL na
    #    OKX). Resolve pares que não têm caminho numa única exchange — o caso do
    #    EUR->BRL com a Binance bloqueada no VPS dos EUA. USD é a ponte universal
    #    (quase todo ativo tem par em USD/USDT).
    if base != "USD" and quote != "USD":
        leg1 = _resolve(base, "USD")
        leg2 = _resolve("USD", quote)
        if leg1 and leg2:
            return {
                "base": base,
                "quote": quote,
                "price": leg1["price"] * leg2["price"],
                "source": f"cross-USD ({leg1['source']} x {leg2['source']})",
            }

    raise HTTPException(
        status_code=404,
        detail={"error": "price unavailable", "base": base, "quote": quote, "tried": EXCHANGE_IDS},
    )


class BalanceRequest(BaseModel):
    exchange: str
    apiKey: str
    secret: str


@app.post("/balance")
def balance(req: BalanceRequest):
    """Saldo de uma conta de exchange, via credenciais somente-leitura.

    Só é chamado pela rede interna do compose — as credenciais não trafegam
    para fora do host.
    """
    if not hasattr(ccxt, req.exchange):
        raise HTTPException(status_code=400, detail=f"exchange desconhecida: {req.exchange}")
    try:
        exchange = getattr(ccxt, req.exchange)(
            {"apiKey": req.apiKey, "secret": req.secret, "enableRateLimit": True}
        )
        totals = exchange.fetch_balance().get("total") or {}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"falha ao consultar {req.exchange}: {exc}")

    balances = {code: float(amount) for code, amount in totals.items() if amount and float(amount) > 0}
    return {"exchange": req.exchange, "balances": balances}


@app.get("/health")
def health():
    return {"ok": True, "exchanges": EXCHANGE_IDS}
