#!/usr/bin/env bash
# Read-only, redacted 3x-ui / Xray inventory. NEVER emits UUIDs, keys, client emails or passwords.
# Reads the active config and, when SQLite is used, the saved Xray template.
set -Eeuo pipefail
echo "=== TCP :443 owner ==="
ss -Hlnpt '( sport = :443 )' | sed -E 's/pid=[0-9]+/pid=REDACTED/g'
echo "=== Active X-UI ==="
systemctl is-active x-ui || true
echo "=== Isolated HA gateway ==="
systemctl is-active dual-ha-v2-gateway dual-ha-v2-health 2>/dev/null || true
echo "=== Actual HAProxy SOCKS egress ==="
if [[ -r /run/dual-ha-v2/health.json ]]; then
 python3 - <<'PY'
import json
with open("/run/dual-ha-v2/health.json") as f: d=json.load(f)
for name,path in (d.get("paths") or {}).items():
  print(name, "available=",path.get("available"),"https_pass=",str(path.get("passed_probes"))+"/3")
PY
else
 echo "Gateway health file not found"
fi
echo "=== Xray core version (non-sensitive) ==="
if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
  /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -n 1 || true
fi
echo "=== Redacted active and stored Xray settings ==="
python3 - <<'PY'
import json, os, sqlite3, pathlib
from urllib.parse import quote

def safe_tag(tag):
    # Inbound/outbound tags are needed for routing, but never print credential-like tags.
    if not isinstance(tag,str): return "(none)"
    if not tag or len(tag)>80 or any(x in tag.lower() for x in ("secret","token","key=","uuid","password")):
        return "(redacted)"
    return tag

def report(cfg,source):
    if not isinstance(cfg,dict): return
    print("CONFIG:",source)
    for ib in cfg.get("inbounds",[]) or []:
        st=ib.get("streamSettings") or {}
        print("  INBOUND", "tag=",safe_tag(ib.get("tag")),
              "port=",ib.get("port"),"protocol=",ib.get("protocol"),
              "security=",st.get("security"),
              "clients=",len((ib.get("settings") or {}).get("clients") or []),
              "clients_with_email=",sum(bool(u.get("email")) for u in ((ib.get("settings") or {}).get("clients") or []) if isinstance(u,dict)))
    obs=cfg.get("outbounds") or []
    print("  OUTBOUNDS_COUNT:",len(obs))
    for idx,ob in enumerate(obs):
        print("  OUTBOUND",idx,"tag=",safe_tag(ob.get("tag")),
              "protocol=",ob.get("protocol"))
    routing=cfg.get("routing") or {}
    rules=routing.get("rules") or []
    print("  ROUTING_RULES_COUNT:",len(rules))
    for i,rule in enumerate(rules):
        rtype=rule.get("type")
        print("  RULE",i,"type=",rtype,
              "inboundTag=", [safe_tag(t) for t in (rule.get("inboundTag") or [])],
              "outboundTag=",safe_tag(rule.get("outboundTag")),
              "balancerTag=",safe_tag(rule.get("balancerTag")),
              "network=",rule.get("network"),
              "sourceIP_PRESENT=",bool(rule.get("sourceIP") or rule.get("source")),
              "user_MATCH_PRESENT=",bool(rule.get("user")),
              "other_match_keys=",
              sorted(k for k in rule if k not in
                     {"type","inboundTag","outboundTag","balancerTag","network",
                      "sourceIP","source","user","ruleTag"}))
    print("  BALANCERS_COUNT:",len(routing.get("balancers") or []))
    print("  API_PRESENT:",bool(cfg.get("api")))
    print("  STATS_PRESENT:",bool(cfg.get("stats")))
    print("  POLICY_PRESENT:",bool(cfg.get("policy")))

paths=["/usr/local/x-ui/bin/config.json",
       "/usr/local/x-ui/bin/xray-config.json",
       "/etc/xray/config.json",
       "/usr/local/etc/xray/config.json"]
found=False
for path in paths:
    if not os.path.isfile(path): continue
    try:
        with open(path) as fp: cfg=json.load(fp)
        report(cfg,path);found=True
    except (ValueError,OSError,TypeError) as e:
        print("  Config path exists but could not parse:",path,type(e).__name__)
if not found: print("No known generated Xray JSON file found.")

# Open SQLite in read-only mode. No temporary DB creation, no schema changes.
db_folder=os.environ.get("XUI_DB_FOLDER","/etc/x-ui")
db_path=pathlib.Path(db_folder)/"x-ui.db"
if os.environ.get("XUI_DB_TYPE","sqlite").lower() in ("postgres","postgresql","pg"):
    print("DATABASE: PostgreSQL configured; use UI to inspect saved template.")
elif db_path.exists():
    try:
        uri="file:"+quote(str(db_path))+"?mode=ro"
        con=sqlite3.connect(uri,uri=True,timeout=3)
        con.execute("PRAGMA query_only=ON")
        table_names={row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "settings" in table_names:
            rows=con.execute("SELECT key, value FROM settings WHERE key IN ('xrayTemplateConfig','jsonConfig')").fetchall()
            for key,value in rows:
                try:
                    obj=json.loads(value)
                    if isinstance(obj,dict) and "xrayTemplateConfig" in obj and isinstance(obj["xrayTemplateConfig"],str):
                        obj=json.loads(obj["xrayTemplateConfig"])
                    report(obj,"3x-ui DB template("+key+")")
                except (ValueError,TypeError):
                    print("Stored template exists but could not parse:",key)
        if "inbounds" in table_names:
            cols={row[1] for row in con.execute("PRAGMA table_info(inbounds)")}
            requested=["port","protocol","tag","enable"]
            cols0=[col for col in requested if col in cols]
            if cols0:
                rows=con.execute("SELECT "+",".join(cols0)+" FROM inbounds ORDER BY id").fetchall()
                print("PANEL_INBOUND_ROWS:",len(rows))
                for row in rows:
                    x=dict(zip(cols0,row))
                    print("  PANEL_INBOUND", "port=",x.get("port"),"protocol=",x.get("protocol"),
                          "tag=",safe_tag(x.get("tag")),"enabled=",x.get("enable"))
        con.close()
    except (sqlite3.Error,OSError) as e:
        print("SQLite read-only inventory failed:",type(e).__name__)
else:
    print("No SQLite DB at default location; this can be normal for Docker/PostgreSQL.")
print("Audit complete: NO change to x-ui, routing, SQL or active ports.")
PY
