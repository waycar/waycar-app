import Foundation

/// Recordings from herdr-core 0.1.14 (`hc`, linux x86_64) over `hc connect`
/// pipes that carry the same bytes as an SSH exec channel (research
/// `docs/research/herdr-core/`, probe `hc_attach_probe.py`), in a scratch
/// session (`HC_SESSION`, own `XDG_*` and HOME), working directory neutral.
/// Binary captures are base64; JSON lines are exact. Times, ids, pids and
/// paths are whatever the core printed.
enum CoreTranscripts {
    /// The plain line core answers `hello {"framed":true}` with
    /// (`hc_attach_probe.py --subscribe`), its 32 method names cut to four.
    static let helloReply =
        #"{"id":0,"jsonrpc":"2.0","result":{"core":{"id":"b16ea0348871a1e21dd8773e29771545","name":"6a09d8670141"},"features":["framed","attach","events","status","shell"],"framed":true,"generation":1,"methods":["hello","server.status","events.subscribe","terminal.keys"],"version":"0.1.14"}}"#

    /// Core to client, byte for byte, after the plain `hello` reply line:
    /// `hc_attach_probe.py --attach wire1 --do sleep:1 --do 'type:x\r' --do sleep:1 --do close`
    /// against `sh -c 'echo hi; exec cat'` (`attach-wire-minimal.bin`). Four
    /// frames: DATA ch 0 (583 B, the `terminal.attach` reply), DATA ch 1 (228 B,
    /// first paint), DATA ch 1 (`x\r\nx\r\n`) and CLOSE ch 1.
    static let wireMinimalFromCore = Data(
        base64Encoded:
            "AAAAAABHAgAAeyJpZCI6MSwianNvbnJwYyI6IjIuMCIsInJlc3VsdCI6eyJjaGFubmVsIjoxLCJ0ZXJtaW5hbCI6eyJhZGRy" +
            "ZXNzIjoidDE4IiwiYXJndiI6WyJzaCIsIi1jIiwiZWNobyBoaTsgZXhlYyBjYXQiXSwiY29scyI6NTIsImNyZWF0ZWRfbXMi" +
            "OjE3OTMzMDkwODY5MDYsImN3ZCI6Ii90bXAvaGNuYS9wcm9qIiwiZGllX3dpdGhfcGFyZW50IjpmYWxzZSwiZXhpdF9jb2Rl" +
            "IjpudWxsLCJmaW5pc2hlZF9tcyI6bnVsbCwiZm9yZWdyb3VuZCI6eyJhcmd2IjpbImNhdCJdLCJjd2QiOiIvdG1wL2hjbmEv" +
            "cHJvaiIsIm5hbWUiOiJjYXQiLCJwaWQiOjI1MzIyODZ9LCJpZGVudGl0eSI6Imdob3N0dHkiLCJrZWVwIjpmYWxzZSwibGFi" +
            "ZWxzIjp7fSwibmFtZSI6IndpcmUxIiwibm90aWZ5Ijp0cnVlLCJwYXJlbnQiOm51bGwsInBpZCI6MjUzMjI4NiwicmVhc29u" +
            "IjpudWxsLCJyZXBvcnRlZCI6ZmFsc2UsInJtIjpmYWxzZSwicm93cyI6MjgsInNjcmVlbiI6ImV4YWN0Iiwic2lnbmFsIjpu" +
            "dWxsLCJzdGF0ZSI6ImxpdmUiLCJzdGF0dXMiOm51bGwsInN0YXR1c19tcyI6bnVsbCwidGVtcGxhdGUiOm51bGwsInRpdGxl" +
            "IjoiIiwidHVybiI6MH19fQEAAAAA5AAAABtbIXAbWz8yMDI2bBtbPzlsG1s/MTAwMGwbWz8xMDAxbBtbPzEwMDJsG1s/MTAw" +
            "M2wbWz8xMDA0bBtbPzEwMDVsG1s/MTAwNmwbWz8xMDE1bBtbPzEwMTZsG1s/MjAwNGwbWz8xbBtbPzY2bBtbPzIwMzFsG1s/" +
            "MjA0OGwbWz0wOzF1G1s/MTA0OWwbWz8xMDQ3bBtbPzQ3bBtbSBtbMkobWzNnG1s5RxtIG1sxN0cbSBtbMjVHG0gbWzMzRxtI" +
            "G1s0MUcbSBtbNDlHG0gbW0hoaRtbMjsxSBtbMG0bWz85MDAxbAEAAAAABgAAAHgNCngNCgEAAAACAAAAAA=="
        ) ?? Data()

    /// Client to core, byte for byte (`attach-wire-minimal.out.bin`), same run:
    /// the plain 75-byte `hello` line, then DATA ch 0 (`terminal.attach`, 145 B),
    /// CREDIT ch 1 (228), DATA ch 1 (`x\r`), CREDIT ch 1 (6), RESIZE ch 1
    /// (40x20), CLOSE ch 1.
    static let wireMinimalFromClient = Data(
        base64Encoded:
            "eyJqc29ucnBjIjogIjIuMCIsICJpZCI6IDAsICJtZXRob2QiOiAiaGVsbG8iLCAicGFyYW1zIjogeyJmcmFtZWQiOiB0cnVl" +
            "fX0KAAAAAACRAAAAeyJqc29ucnBjIjogIjIuMCIsICJpZCI6IDEsICJtZXRob2QiOiAidGVybWluYWwuYXR0YWNoIiwgInBh" +
            "cmFtcyI6IHsidGVybWluYWwiOiAid2lyZTEiLCAiY29scyI6IDUyLCAicm93cyI6IDI4LCAib2JzZXJ2ZSI6IGZhbHNlLCAi" +
            "aGlzdG9yeSI6IDB9fQEAAAABBAAAAOQAAAABAAAAAAIAAAB4DQEAAAABBAAAAAYAAAABAAAAAwQAAAAoABQAAQAAAAIAAAAA"
        ) ?? Data()

    /// Length of the plain `hello` line at the start of ``wireMinimalFromClient``.
    static let wireMinimalHelloLineBytes = 75

    /// One event notification per DATA frame on the events channel of
    /// `hc_attach_probe.py --subscribe --do sleep:20` (`attach-events-framed.json`;
    /// a few DATA frames carry several lines). The terminal is `t1d`: a `sh`
    /// script printing OSC 0 and OSC 7501 (working, idle, a child record, a
    /// clear), then a kept terminal killed with `kill -9` (`lost`, then
    /// `restarted` 2.3 s later), `hc kill` (`finished`), `hc rm` (`removed`),
    /// then `t1f` created, `foreground` twice and finished, `t1g` the same.
    /// The snapshot before them was `seq` 103 with other terminals; the first
    /// event here is `seq` 104. Heartbeats at 15 s and 30 s sit between them.
    static let eventFrames: [String] = [
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"address":"t1d","argv":["sh","-c","r(){ printf '\\033]7501;%s\\033\\\\' \"$1\"; }\nprintf '\\033]0;mytitle\\007'; r state=working:app=fake; sleep 1.5; r state=idle:app=fake; r 'state=working:id=sub1:app=fake'; sleep 0.5; r 'state=clear:id=sub1'; sleep 3000"],"cols":200,"created_ms":1793309148244,"cwd":"/tmp/hcna/proj","die_with_parent":false,"exit_code":null,"finished_ms":null,"identity":"ghostty","keep":false,"labels":{"a":"b"},"name":"ev1","notify":true,"parent":null,"pid":2533146,"reason":null,"reported":false,"rm":false,"rows":120,"screen":"exact","signal":null,"state":"live","status":null,"status_ms":null,"template":null,"title":"","turn":0},"seq":104,"terminal":"t1d","type":"created"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":{"app":"fake","state":"working"}},"seq":105,"terminal":"t1d","type":"status"}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"title":"mytitle"},"seq":106,"terminal":"t1d","type":"title"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"argv":["sh","-c","r(){ printf '\\033]7501;%s\\033\\\\' \"$1\"; }\nprintf '\\033]0;mytitle\\007'; r state=working:app=fake; sleep 1.5; r state=idle:app=fake; r 'state=working:id=sub1:app=fake'; sleep 0.5; r 'state=clear:id=sub1'; sleep 3000"],"cwd":"/tmp/hcna/proj","name":"sh","pid":2533146},"seq":107,"terminal":"t1d","type":"foreground"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":{"app":"fake","state":"idle"}},"seq":108,"terminal":"t1d","type":"status"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"state":"idle","turn":1},"seq":109,"terminal":"t1d","type":"turn"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{"sub1":{"app":"fake","state":"working"}},"reported":true,"status":{"app":"fake","state":"idle"}},"seq":110,"terminal":"t1d","type":"status"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":{"app":"fake","state":"idle"}},"seq":111,"terminal":"t1d","type":"status"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"cols":52,"rows":28},"seq":112,"terminal":"t1d","type":"size"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"cols":200,"rows":120},"seq":113,"terminal":"t1d","type":"size"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{"a":"b","x":"y"}},"seq":114,"terminal":"t1d","type":"labels"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"keep":true},"seq":115,"terminal":"t1d","type":"keep"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":null},"seq":116,"terminal":"t1d","type":"status"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"exit_code":null,"finished_ms":null,"reason":"signaled","signal":9},"seq":117,"terminal":"t1d","type":"lost"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"address":"t1d","argv":["/bin/sh"],"cols":200,"created_ms":1793309148244,"cwd":"/tmp/hcna/proj","die_with_parent":false,"exit_code":null,"finished_ms":null,"identity":"ghostty","keep":true,"labels":{"a":"b","x":"y"},"name":"ev1","notify":true,"parent":null,"pid":2533283,"reason":null,"reported":false,"rm":false,"rows":120,"screen":"exact","signal":null,"state":"live","status":null,"status_ms":1793309154140,"template":null,"title":"","turn":1},"seq":118,"terminal":"t1d","type":"restarted"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"argv":["/bin/sh"],"cwd":"/tmp/hcna/proj","name":"sh","pid":2533283},"seq":119,"terminal":"t1d","type":"foreground"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"keep":false},"seq":120,"terminal":"t1d","type":"keep"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"exit_code":null,"finished_ms":1793309158946,"reason":"killed","signal":1},"seq":121,"terminal":"t1d","type":"finished"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{},"seq":122,"terminal":"t1d","type":"removed"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"address":"t1f","argv":["sh"],"cols":200,"created_ms":1793309160153,"cwd":"/tmp/hcna/proj","die_with_parent":false,"exit_code":null,"finished_ms":null,"identity":"ghostty","keep":false,"labels":{},"name":"sh1","notify":true,"parent":null,"pid":2533389,"reason":null,"reported":false,"rm":false,"rows":120,"screen":"exact","signal":null,"state":"live","status":null,"status_ms":null,"template":null,"title":"","turn":0},"seq":123,"terminal":"t1f","type":"created"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"argv":["sh"],"cwd":"/tmp/hcna/proj","name":"sh","pid":2533389},"seq":124,"terminal":"t1f","type":"foreground"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"argv":["sleep","3"],"cwd":"/tmp/hcna/proj","name":"sleep","pid":2533414},"seq":125,"terminal":"t1f","type":"foreground"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":125}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"exit_code":5,"finished_ms":1793309164169,"reason":"exited","signal":null},"seq":126,"terminal":"t1f","type":"finished"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"address":"t1g","argv":["sleep","1"],"cols":200,"created_ms":1793309165168,"cwd":"/tmp/hcna/proj","die_with_parent":false,"exit_code":null,"finished_ms":null,"identity":"ghostty","keep":false,"labels":{},"name":"tmp","notify":true,"parent":null,"pid":2533490,"reason":null,"reported":false,"rm":false,"rows":120,"screen":"exact","signal":null,"state":"live","status":null,"status_ms":null,"template":null,"title":"","turn":0},"seq":127,"terminal":"t1g","type":"created"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"argv":["sleep","1"],"cwd":"/tmp/hcna/proj","name":"sleep","pid":2533490},"seq":128,"terminal":"t1g","type":"foreground"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"exit_code":0,"finished_ms":1793309166173,"reason":"exited","signal":null},"seq":129,"terminal":"t1g","type":"finished"}}"#
        ].joined(separator: "\n") + "\n",
        [
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":129}}"#
        ].joined(separator: "\n") + "\n",
    ]
}
