import json
d=json.load(open("/tmp/cap/ev-ssh.json"))
evs=[]
for f in d["frames"]:
    if f.get("dir")=="in":
        for l in f.get("lines",[]):
            if l.get("method")=="event": evs.append((f["t"],l["params"]))
t0=None
for t,p in evs:
    if p["terminal"]=="t10" and p["type"]=="status" and p["data"].get("status",{}) and p["data"]["status"].get("state")=="working" and t0 is None:
        t0=t
for t,p in evs:
    if p["terminal"]=="t10" and t0 is not None and t>=t0-0.05:
        dd=dict(p["data"]); 
        print("%7.3f seq=%s %-10s %s" % (t-t0,p["seq"],p["type"],json.dumps(dd,separators=(",",":"))[:150]))
