cd ~/lab/probes; H=$HOME/.local/bin/herdr-core
$H kill flood >/dev/null 2>&1; sleep .2; $H rm flood >/dev/null 2>&1
$H run --bg --no-parent --name flood --cwd /home/waycar/work -- sh -c 'while :; do printf "%0200d\n" 1; done' >/dev/null
sleep 1
for m in pipe ssh; do
  if [ $m = pipe ]; then A="--hc $H"; else A='--ssh "ssh -T -o BatchMode=yes 127.0.0.1"'; fi
  eval python3 hc_attach_probe_ssh.py $A --attach flood --observe --no-credit --do sleep:2 --drain 0.1 --capture /tmp/cap/flood-$m >/tmp/cap/flood-$m.log 2>&1
done
python3 - <<'PY'
import json
for m in ("pipe","ssh"):
    d=json.load(open("/tmp/cap/flood-%s.json"%m))
    fr=[f for f in d["frames"] if f.get("dir")=="in" and f.get("ch")==1 and f["kind"]=="DATA"]
    ls=[f["len"] for f in fr]
    print(m,"DATA frames",len(ls),"total bytes",sum(ls),"first lens",ls[:6],"last",ls[-2:])
PY
$H kill flood >/dev/null
