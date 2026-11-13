cd ~/lab/probes; mkdir -p /tmp/cap
H=$HOME/.local/bin/herdr-core
SSH='ssh -T -o BatchMode=yes 127.0.0.1'
ARGS='--attach t1 --observe --cols 52 --rows 28 --do call:terminal.get:{"terminal":"t1"} --do sleep:1 --do close --do sleep:0.3 --drain 0.3'
for i in 1 2; do
python3 hc_attach_probe_ssh.py --hc $H $ARGS --capture /tmp/cap/pipe$i > /tmp/cap/pipe$i.log 2>&1
python3 hc_attach_probe_ssh.py --ssh "$SSH" $ARGS --capture /tmp/cap/ssh$i > /tmp/cap/ssh$i.log 2>&1
done
cat /tmp/cap/ssh1.log | cut -c1-300
echo ====; for f in pipe1 pipe2 ssh1 ssh2; do echo $f hello=$(sha256sum < /tmp/cap/$f.hello.bin | cut -c1-12) bin=$(sha256sum < /tmp/cap/$f.bin | cut -c1-12) out=$(sha256sum < /tmp/cap/$f.out.bin | cut -c1-12) sz=$(stat -c %s /tmp/cap/$f.bin) chunks=$(cat /tmp/cap/$f.chunks.json); done
