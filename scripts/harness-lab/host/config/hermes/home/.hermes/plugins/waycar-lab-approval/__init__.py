"""Harness lab only: make hermes ask before a terminal command.

Hermes asks only for dangerous commands, and the mock's `echo` is not one
(docs/research/harnesses/hermes.md §1). A `pre_tool_call` hook that answers
`{"action": "approve"}` escalates the call to the human approval gate. The
e2e suite turns this on per launch with WAYCAR_LAB_HERMES_ASK=1
(HarnessLabProfile), so every other hermes run in the lab is unchanged.
"""

import os


def _ask(tool_name=None, **_kwargs):
    if tool_name == "terminal" and os.environ.get("WAYCAR_LAB_HERMES_ASK") == "1":
        return {"action": "approve", "message": "waycar harness lab: approve this command"}
    return None


def register(ctx):
    ctx.register_hook("pre_tool_call", _ask)
