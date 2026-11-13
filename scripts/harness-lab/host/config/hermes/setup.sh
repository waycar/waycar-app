#!/bin/sh
# Hermes keeps a large generated ~/.hermes/config.yaml; set only the keys the
# lab needs with its own CLI: the mock as a custom OpenAI-compatible provider,
# no update checks, and no borrowing of other harnesses' logins.
set -eu
hermes config set model.provider custom
hermes config set model.base_url http://mock:8080/v1
hermes config set model.default mock-model
hermes config set model.api_key waycar-lab-dummy-key
hermes config set updates.check false
hermes config set auth.adopt_external_logins false
# User plugins are opt-in. waycar-lab-approval (home/.hermes/plugins/) makes a
# launch with WAYCAR_LAB_HERMES_ASK=1 ask before a terminal command.
hermes plugins enable waycar-lab-approval
