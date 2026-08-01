#!/bin/sh
set -eu

python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
