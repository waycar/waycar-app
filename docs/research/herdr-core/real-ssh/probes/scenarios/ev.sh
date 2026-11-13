cd ~/lab/probes; mkdir -p /tmp/cap
H=$HOME/.local/bin/herdr-core
SSH='ssh -T -o BatchMode=yes 127.0.0.1'
python3 hc_attach_probe_ssh.py --ssh "$SSH" --subscribe --do sleep:14 --drain 0.3 --capture /tmp/cap/ev-ssh --width 400 > /tmp/cap/ev-ssh.log 2>&1 &
python3 hc_attach_probe_ssh.py --hc $H --subscribe --do sleep:14 --drain 0.3 --capture /tmp/cap/ev-pipe --width 400 > /tmp/cap/ev-pipe.log 2>&1 &
sleep 1.5
echo "== launch reset"; ssh -T -o BatchMode=yes 127.0.0.1 'sh $HOME/lab/launch-lab-terminals.sh reset' 
sleep 3
echo "== work turn"; ssh -T -o BatchMode=yes 127.0.0.1 '~/.local/bin/herdr-core send alpha work'
wait
