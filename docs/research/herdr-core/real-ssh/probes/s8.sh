# 8: MaxSessions. One ssh connection (ControlMaster), 12 simultaneous `ssh -T` exec channels.
rm -f /tmp/cm.sock
ssh -M -S /tmp/cm.sock -o ControlPersist=60 -o BatchMode=yes -fN 127.0.0.1
sleep 0.5
ok=0; bad=0
for i in $(seq 1 12); do
  ( ssh -S /tmp/cm.sock -T -o BatchMode=yes 127.0.0.1 'sleep 6; echo done' >/tmp/cm.out.$i 2>/tmp/cm.err.$i; echo "chan $i rc=$?" >> /tmp/cm.rc ) &
  sleep 0.1
done
sleep 2
echo "--- sshd's view while they sleep: sshd children of the ssh connection"
ps -eo pid,args | grep -E "[s]shd: waycar" | head -20
wait
sort -V /tmp/cm.rc
echo "--- errors the clients saw (distinct):"; cat /tmp/cm.err.* | sort | uniq -c
echo "--- outputs:"; cat /tmp/cm.out.* | sort | uniq -c
ssh -S /tmp/cm.sock -O exit 127.0.0.1 2>&1
rm -f /tmp/cm.rc /tmp/cm.out.* /tmp/cm.err.*
