import json
import os
import time
from datetime import datetime, timezone, timedelta

import redis
from pymongo import MongoClient, ReturnDocument


MONGO_URI = os.environ.get("MONGO_URI") or os.environ.get("MONGODB_URI")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis")
CHECK_INTERVAL = int(os.environ.get("MONITOR_INTERVAL", "30"))
HOST_DOWN_AFTER = int(os.environ.get("MONITOR_HOST_DOWN_AFTER", "180"))
EMAIL_TO = [item.strip() for item in os.environ.get("MONITOR_EMAIL_TO", "").split(",") if item.strip()]


def utcnow():
    return datetime.now(timezone.utc)


def get_db():
    if not MONGO_URI:
        raise RuntimeError("MONGO_URI/MONGODB_URI nao configurado")
    return MongoClient(MONGO_URI).get_default_database()


def open_incident(db, key, target, severity, summary):
    now = utcnow()
    incident = db.monitor_incidents.find_one_and_update(
        {"key": key, "target": target, "status": "open"},
        {
            "$set": {"severity": severity, "summary": summary, "updatedAt": now},
            "$setOnInsert": {"openedAt": now},
            "$inc": {"count": 1},
        },
        upsert=True,
        return_document=ReturnDocument.AFTER,
    )
    return incident


def resolve_incident(db, key, target):
    now = utcnow()
    db.monitor_incidents.update_many(
        {"key": key, "target": target, "status": "open"},
        {"$set": {"status": "resolved", "resolvedAt": now, "updatedAt": now}},
    )


def enqueue_email(redis_client, subject, variables):
    if not EMAIL_TO:
        return
    for recipient in EMAIL_TO:
        redis_client.lpush(
            "email:send",
            json.dumps(
                {
                    "to": recipient,
                    "subject": subject,
                    "template": "monitor-alert",
                    "variables": variables,
                }
            ),
        )


def check_hosts(db, redis_client):
    now = utcnow()
    cutoff = now - timedelta(seconds=HOST_DOWN_AFTER)
    hosts = list(db.monitor_hosts.find({}))

    for host in hosts:
        name = host.get("name")
        last_seen = host.get("lastSeen")
        if last_seen and last_seen.tzinfo is None:
            last_seen = last_seen.replace(tzinfo=timezone.utc)

        if not last_seen or last_seen < cutoff:
            db.monitor_hosts.update_one({"_id": host["_id"]}, {"$set": {"status": "down", "updatedAt": now}})
            incident = open_incident(
                db,
                "host.down",
                name,
                "critical",
                f"Host {name} sem heartbeat desde {last_seen.isoformat() if last_seen else 'nunca'}",
            )
            if incident and incident.get("count") == 1:
                enqueue_email(
                    redis_client,
                    f"[Monitor] Host down: {name}",
                    {
                        "title": f"Host down: {name}",
                        "severity": "critical",
                        "summary": incident["summary"],
                    },
                )
        else:
            db.monitor_hosts.update_one({"_id": host["_id"]}, {"$set": {"status": "ok", "updatedAt": now}})
            resolve_incident(db, "host.down", name)


def main():
    db = get_db()
    redis_client = redis.Redis.from_url(REDIS_URL)
    print("monitor-worker iniciado")
    print(f"intervalo={CHECK_INTERVAL}s host_down_after={HOST_DOWN_AFTER}s")

    while True:
        try:
            check_hosts(db, redis_client)
        except Exception as exc:
            print(f"erro no ciclo de monitoramento: {exc}")
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()