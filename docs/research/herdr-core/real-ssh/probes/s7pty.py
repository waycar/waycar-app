import sys, time, subprocess, os
sys.path.insert(0, ".")
from ptyssh import *
os.chdir(os.path.expanduser("~"))
def setnoise(which):
    subprocess.run("cp .bashrc.orig .bashrc; cp .profile.orig .profile", shell=True)
    if "profile" in which or which == "all": subprocess.run("sed -i '1i echo NOISE-PROFILE' .profile", shell=True)
    if "top" in which or which == "all": subprocess.run("sed -i '1i echo NOISE-BASHRC-TOP' .bashrc", shell=True)
    if "after" in which or which == "all":
        subprocess.run("n=$(grep -n '^esac' .bashrc | head -1 | cut -d: -f1); sed -i \"${n}a echo NOISE-BASHRC-AFTER-GUARD\" .bashrc", shell=True)
for which in ["none", "all"]:
    setnoise(which)
    print("\n### rc noise = %s" % which)
    s = PtySSH(SSH + [attach_line("alpha")], 80, 24); time.sleep(1.0)
    print("  ssh -tt <attach line>: first bytes: %s" % esc(s.data()[:120], 200))
    s.close_master(); s.wait_exit(3)
    s = PtySSH(["ssh", "-tt", "-o", "BatchMode=yes", "127.0.0.1"], 80, 24); time.sleep(1.0); s.write(b"echo X\rexit\r"); s.wait_exit(5)
    d = s.data().decode(errors="replace")
    print("  ssh -tt host (interactive login shell): NOISE-PROFILE=%s NOISE-BASHRC-TOP=%s NOISE-BASHRC-AFTER-GUARD=%s MOTD-text=%s 'Welcome to Ubuntu'=%s" % (
        "NOISE-PROFILE" in d, "NOISE-BASHRC-TOP" in d, "NOISE-BASHRC-AFTER-GUARD" in d, "core lab: a throwaway" in d, "Welcome to Ubuntu" in d))
setnoise("none")
