import json,sys
def load(p):
    d=json.load(open(p)); ev=[]; snap=None; hb=[]
    for f in d["frames"]:
        if f.get("dir")!="in": continue
        if f.get("ch")==0 and "json" in f and f["json"].get("result",{}).get("terminals") is not None: snap=f["json"]["result"]
        for l in f.get("lines",[]):
            if l.get("method")=="event": ev.append((f["t"],l["params"]))
            else: hb.append((f["t"],l))
    return snap,ev,hb
s1,e1,h1=load("/tmp/cap/ev-ssh.json"); s2,e2,h2=load("/tmp/cap/ev-pipe.json")
print("snapshots seq ssh/pipe",s1["seq"],s2["seq"],"n terminals",len(s1["terminals"]),len(s2["terminals"]))
m={p["seq"]:(t,p) for t,p in e2}
same=diff=only=0; dts=[]
for t,p in e1:
    if p["seq"] in m:
        if json.dumps(p,sort_keys=True)==json.dumps(m[p["seq"]][1],sort_keys=True): same+=1
        else: diff+=1
        dts.append(round(t-m[p["seq"]][0],4))
    else: only+=1
print("events ssh",len(e1),"pipe",len(e2),"common identical",same,"common different",diff,"ssh-only",only)
print("arrival delta ssh-pipe (s) min/max",min(dts),max(dts))
print("heartbeats", h1, h2)
