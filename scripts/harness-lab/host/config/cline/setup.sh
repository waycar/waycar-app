#!/bin/sh
# Cline stores its provider in ~/.cline/data/settings; `cline auth` writes it.
set -eu
cline auth -p openai -k waycar-lab-dummy-key -m mock-model -b http://mock:8080/v1
