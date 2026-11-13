import json,collections
d=json.load(open("/tmp/cap/ev-ssh.json"))
evs=[]
for f in d["frames"]:
    if f.get("dir")=="in":
        for l in f.get("lines",[]):
            if l.get("method")=="event": evs.append((f["t"],l["params"]))
c=collections.Counter(p["type"] for t,p in evs); print(dict(c))
for t,p in evs:
    if p["terminal"] in("t12","t15") and t<8:
        dd=p["data"]
        if p["type"]=="created": dd={k:dd[k] for k in("address","name","labels","cwd","cols","rows","state","argv")}
        print("%6.3f seq=%s %s %-10s %s"%(t,p["seq"],p["terminal"],p["type"],json.dumps(dd,separators=(",",":"))[:220]))
