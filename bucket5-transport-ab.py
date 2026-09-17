#!/usr/bin/env python3
import argparse, csv, datetime as dt, json, os, re, subprocess, time
from pathlib import Path

DEFAULT_CONFIG=Path('/etc/anytls-tunnel/bucket5-transports-canary.json')
DEFAULT_PROBE='/usr/local/sbin/anytls-bucket5-transport-probe'
OUTROOT=Path('/var/lib/anytls-tunnel/transport-ab')

def load_config(path):
    with open(path) as f: return json.load(f)

def failure_stage(output):
    stages=re.findall(r'^STAGE=([^\s]+)', output, flags=re.M)
    return stages[-1] if stages else 'unknown'

def main():
    ap=argparse.ArgumentParser(description='Repeated isolated transport A/B probe runner')
    ap.add_argument('node')
    ap.add_argument('--attempts',type=int,default=20)
    ap.add_argument('--interval',type=int,default=120,help='seconds between complete carrier rounds')
    ap.add_argument('--carriers',default='',help='comma-separated; default all configured carriers')
    ap.add_argument('--config',default=str(DEFAULT_CONFIG))
    ap.add_argument('--probe',default=DEFAULT_PROBE)
    args=ap.parse_args()
    if os.geteuid()!=0: raise SystemExit('run as root')
    if not re.fullmatch(r'F[1-5]',args.node): raise SystemExit('node must be F1..F5')
    if args.attempts<1 or args.attempts>1000: raise SystemExit('attempts must be 1..1000')
    if args.interval<0: raise SystemExit('interval must be >=0')
    cfg=load_config(args.config)
    node=(cfg.get('nodes') or {}).get(args.node) or {}
    configured=list((node.get('carriers') or {}).keys())
    carriers=[x for x in args.carriers.split(',') if x] if args.carriers else configured
    if not carriers or any(x not in configured for x in carriers): raise SystemExit('invalid/no carriers')

    stamp=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    outdir=OUTROOT/f'{args.node}-{stamp}'
    outdir.mkdir(parents=True,exist_ok=False); os.chmod(outdir,0o700)
    csvp=outdir/'results.csv'
    fields=['timestamp_utc','node','carrier','round','rc','success','elapsed_sec','failure_stage']
    rows=[]
    with csvp.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); f.flush()
        for rnd in range(1,args.attempts+1):
            for carrier in carriers:
                ts=dt.datetime.now(dt.timezone.utc).isoformat()
                start=time.monotonic()
                env=dict(os.environ); env['BUCKET5_TRANSPORT_CONFIG']=args.config
                p=subprocess.run([args.probe,args.node,carrier],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
                elapsed=round(time.monotonic()-start,3)
                stage=failure_stage(p.stdout)
                row={'timestamp_utc':ts,'node':args.node,'carrier':carrier,'round':rnd,'rc':p.returncode,
                     'success':1 if p.returncode==0 else 0,'elapsed_sec':elapsed,'failure_stage':stage}
                rows.append(row); w.writerow(row); f.flush()
                (outdir/f'round-{rnd:03d}-{carrier}.log').write_text(p.stdout)
                print(f"round={rnd} carrier={carrier} {'PASS' if p.returncode==0 else 'FAIL'} stage={stage} elapsed={elapsed}s",flush=True)
            if rnd != args.attempts and args.interval:
                time.sleep(args.interval)

    summary={}
    for carrier in carriers:
        rr=[r for r in rows if r['carrier']==carrier]
        ok=sum(int(r['success']) for r in rr)
        summary[carrier]={
            'attempts':len(rr),'success':ok,'failure':len(rr)-ok,
            'success_rate':round(ok/len(rr),4) if rr else 0,
            'failure_stages':{}
        }
        for r in rr:
            if not r['success']:
                fs=r['failure_stage']; summary[carrier]['failure_stages'][fs]=summary[carrier]['failure_stages'].get(fs,0)+1
    (outdir/'summary.json').write_text(json.dumps(summary,indent=2,sort_keys=True))
    os.chmod(csvp,0o600); os.chmod(outdir/'summary.json',0o600)
    print(json.dumps(summary,indent=2,sort_keys=True))
    print(f'OUTPUT_DIR={outdir}')

if __name__=='__main__': main()
