#!/bin/bash
# Destructive test: run as root ONLY in a throwaway distro container.
# WAYCAR_NATIVE_BIN is the same musl binary/cache used by core-distros.yml.
# --user-phase is also useful on a development host, with a SCRATCH HOME,
# PATH containing Zellij, and ZELLIJ_SOCKET_DIR under /tmp/zjht-*.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
die() { echo "zellij-distro-check: $*" >&2; exit 1; }

if [ "${1:-}" != --user-phase ]; then
    [ "$(id -u)" = 0 ] || die 'run as root in a throwaway container'
    [ -x "${WAYCAR_NATIVE_BIN:-}" ] || die 'WAYCAR_NATIVE_BIN must name the native binary'
    if command -v apt-get >/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar procps python3 util-linux ${WAYCAR_CI_WITH_TMUX:+tmux} >/dev/null
    else
        dnf install -y -q --allowerasing curl ca-certificates tar procps-ng python3 util-linux shadow-utils ${WAYCAR_CI_WITH_TMUX:+tmux} >/dev/null
    fi
    ! command -v herdr >/dev/null || die 'not a Zellij-only Host'
    install -D -m755 "$WAYCAR_NATIVE_BIN" /opt/zjht/waycar
    zellij=$(python3 "$repo/scripts/ci/zellij-contract.py" --fetch /opt/zjht/zellij)
    [ -x "$zellij" ] || die 'contract fetch did not produce an executable zellij'
    id zjht >/dev/null 2>&1 || useradd -m -s /bin/bash zjht
    scratch=$(mktemp -d /tmp/zjht-distro.XXXXXX)
    chown zjht "$scratch"
    trap 'rm -rf "$scratch"' EXIT
    install -D -m755 "$zellij" "$scratch/.local/bin/zellij"
    chown -R zjht "$scratch"
    runuser -u zjht -- env -i HOME="$scratch" USER=zjht LOGNAME=zjht SHELL=/bin/bash TERM=xterm-256color \
        PATH=/usr/local/bin:/usr/bin:/bin WAYCAR_NATIVE_BIN=/opt/zjht/waycar \
        ZELLIJ_SOCKET_DIR="$scratch/sockets" WAYCAR_CI_WITH_TMUX="${WAYCAR_CI_WITH_TMUX:-}" \
        bash "$0" --user-phase
    echo 'PASS Zellij Host Tools distro smoke'
    exit
fi

case $HOME in /tmp/zjht-*) ;; *) die '--user-phase needs a scratch /tmp/zjht-* HOME' ;; esac
[ -n "${ZELLIJ_SOCKET_DIR:-}" ] || die 'set scratch ZELLIJ_SOCKET_DIR'
mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/package/bin"
cp -R "$repo/plugin/hooks" "$repo/plugin/herdr-plugin.toml" "$HOME/package/"
cp "$repo/plugin/bin/waycar-hook" "$HOME/package/bin/"
install -m755 "$WAYCAR_NATIVE_BIN" "$HOME/package/bin/waycar"
# No --tmux flag, even on the Zellij-only Host. The CLI is deliberately off PATH.
WAYCAR_PLUGIN_SOURCE="$HOME/package" WAYCAR_NO_PAIR=1 sh "$repo/plugin/install.sh" </dev/null
export PATH="$HOME/.local/bin:$PATH"
waycar status --json >"$HOME/status.json"
python3 - "$HOME/status.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
assert j['version']==1 and j['backends']['zellij']=='0.46.0',j
print('status --json:',j['backends'])
PY

python3 - "$repo" <<'PY'
import base64,hashlib,json,os,pathlib,pty,signal,subprocess,sys,time,urllib.request
repo=pathlib.Path(sys.argv[1]); home=pathlib.Path.home(); z=home/'.local/bin/zellij'
if not z.exists(): z=pathlib.Path(subprocess.check_output(['which','zellij'],text=True).strip())
d=home/'smoke';d.mkdir(); session='zjht-smoke'; sock=str(d/'tmux')
relay=subprocess.Popen(['python3',str(repo/'scripts/ci/relay-standin.py'),'--port-file',str(d/'port')])
def wait(f,label):
    until=time.monotonic()+30
    while time.monotonic()<until:
        if f(): return
        time.sleep(.1)
    raise AssertionError('timed out: '+label)
def zj(*args):return subprocess.check_output([str(z),*args],text=True,stderr=subprocess.DEVNULL)
def tm(*args):return subprocess.check_output(['tmux','-S',sock,'-f','/dev/null',*args],text=True).strip()
def doc(id):
    name=base64.urlsafe_b64encode(id.encode()).rstrip(b'=').decode()+'.json'
    return home/'.local/state/waycar/zellij'/name
def pushes(id):
    want=base64.urlsafe_b64encode(hashlib.sha256(bytes(range(32))+b'HERDR-NOTIFY-COLLAPSE:'+id.encode()).digest()[:16]).rstrip(b'=').decode()
    data=urllib.request.urlopen('http://127.0.0.1:'+ (d/'port').read_text()+'/requests').read().decode()
    return sum(json.loads(line).get('body',{}).get('collapse')==want for line in data.splitlines())
# The fake agent's own environment contains Zellij's pair, not just the hook's.
# Invoke the installed Claude commands (including hook-session), not hand-built hooks.
agent=d/'agent.py'
agent.write_text('''import json,os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);root.mkdir(exist_ok=True)
(root/'env.json').write_text(json.dumps(dict(os.environ)))
settings=json.load(open(pathlib.Path.home()/'.claude/settings.json'))
n=0
while True:
 p=root/str(n)
 if not p.exists():time.sleep(.05);continue
 event=p.read_text();body={'session_id':'zjht-session','transcript_path':'/tmp/zjht-transcript.jsonl','source':'startup'}
 env=dict(os.environ,CLAUDECODE='1',CLAUDE_PID=str(os.getpid()))
 for group in settings['hooks'][event]:
  for hook in group['hooks']:
   if '/bin/waycar' in hook.get('command',''):
    subprocess.run(hook['command'],shell=True,input=json.dumps(body),text=True,env=env,check=True)
 (root/('ack'+str(n))).write_text('ok');n+=1
''')
def fire(root,event):
    n=len(list(root.glob('ack*')));(root/str(n)).write_text(event)
    wait(lambda:(root/('ack'+str(n))).exists(),event)
def check_agent(root,id):
    fire(root,'SessionStart');wait(lambda:doc(id).exists(),'session document')
    fire(root,'UserPromptSubmit');assert json.loads(doc(id).read_text())['status']=='working'
    fire(root,'PermissionRequest');wait(lambda:pushes(id)==1,'Blocked push '+id)
    fire(root,'PostToolUse');fire(root,'Stop');wait(lambda:pushes(id)==2,'Done push '+id)
    j=json.loads(doc(id).read_text());assert j['pane']==id and j['status']=='done' and j['session']=='zjht-session',j
    print('document:',json.dumps(j));print('relay: 2 pushes for',id)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
try:
    wait(lambda:(d/'port').exists(),'relay')
    config=home/'.config/waycar';config.mkdir(parents=True,exist_ok=True)
    (config/'notify.json').write_text(json.dumps({'relay_url':'http://127.0.0.1:'+(d/'port').read_text(),'debounce_ms':0,'retry_delay_ms':0}))
    (config/'notifications.json').write_text(json.dumps({'v':1,'devices':[{'token':'a1'*32,'key':base64.urlsafe_b64encode(bytes(range(32))).rstrip(b'=').decode(),'env':'sandbox','notify':{'blocked':True,'done':True}}]}))
    root=d/'zagent';root.mkdir()
    start=[str(z),'attach','-b',session,'--','python3',str(agent),str(root)]
    if os.environ.get('WAYCAR_CI_WITH_TMUX')=='1':
        import shlex
        tm('new-session','-d','-s','outer','-x','120','-y','40',shlex.join(start)+'; sleep 120')
    else: subprocess.run(start,check=True,stdout=subprocess.DEVNULL)
    wait(lambda:(root/'env.json').exists(),'Zellij fake agent')
    own=json.loads((root/'env.json').read_text());id='zellij:'+session+'/terminal_'+own['ZELLIJ_PANE_ID']
    listing=subprocess.check_output([str(z),'ls','-n'],env=own,text=True)
    assert any(line.startswith(session+' [Created ') and line.rstrip().endswith(' (current)') for line in listing.splitlines()),listing
    print('in-pane listing:',listing.strip())
    check_agent(root,id)
    before=doc(id).read_bytes()
    hook=str(home/'.local/share/waycar/plugin/bin/waycar-hook')
    # An outside parent has a real PTY and the pair in its OWN environment.
    # Its missing Zellij ancestor must reject the hook, not merely an env mismatch.
    env=dict(os.environ,ZELLIJ_PANE_ID=own['ZELLIJ_PANE_ID'],ZELLIJ_SESSION_NAME=session,CLAUDECODE='1')
    pid,fd=pty.fork()
    if pid==0: os.execvpe('/bin/sh',['sh','-c','"$1" claude working; :','sh',hook],env)
    _,code=os.waitpid(pid,0);os.close(fd);assert code==0
    assert doc(id).read_bytes()==before,'wrong tty changed the document'
    print('wrong-tty / inherited-env hook: unchanged')
    if os.environ.get('WAYCAR_CI_WITH_TMUX')=='1':
        assert own.get('TMUX_PANE'),'Zellij did not inherit outer tmux pane'
        # Start a fresh tmux server FROM a Zellij pane; its inner pane has a
        # new tty but inherits Zellij's pair. tmux must win, leaving the outer
        # Zellij document absent.
        inner=d/'tagent';inner.mkdir()
        import shlex
        command=['tmux','-S',sock+'-inner','-f','/dev/null','new-session','-d','-s','inner','-x','120','-y','40',shlex.join(['python3',str(agent),str(inner)])]
        zj('-s',session,'action','new-pane','--','/bin/sh','-c',shlex.join(command)+'; sleep 120')
        wait(lambda:(inner/'env.json').exists(),'tmux inside Zellij')
        ienv=json.loads((inner/'env.json').read_text());tid='tmux:'+ienv['TMUX_PANE']
        fire(inner,'UserPromptSubmit');fire(inner,'PermissionRequest');wait(lambda:pushes(tid)==1,'inner tmux Blocked')
        fire(inner,'PostToolUse');fire(inner,'Stop');wait(lambda:pushes(tid)==2,'inner tmux Done')
        outer='zellij:'+session+'/terminal_'+ienv['ZELLIJ_PANE_ID'];assert not doc(outer).exists()
        print('nested routing: Zellij-in-tmux and tmux-in-Zellij use innermost pane')
    fire(root,'SessionEnd');assert not doc(id).exists(),'release kept document'
finally:
    subprocess.run([str(z),'kill-session',session],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for socket in (sock,sock+'-inner'):
        subprocess.run(['tmux','-S',socket,'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) if pathlib.Path(socket).exists() else None
    relay.terminate();relay.wait(timeout=10)
print('PASS Zellij documents, ownership, sessions, release and Blocked/Done pushes')
PY
