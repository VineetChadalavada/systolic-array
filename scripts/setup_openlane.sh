#!/usr/bin/env bash
# One-time setup: OpenLane 2 in a Python virtual environment.  The flow itself
# runs inside the OpenLane Docker image (--dockerized), which needs Docker.
set -e
python3 -m venv "$HOME/.venv-openlane" 2>/dev/null || { sudo -n apt-get install -y python3-venv && python3 -m venv "$HOME/.venv-openlane"; }
source "$HOME/.venv-openlane/bin/activate"
pip install -q --upgrade pip
pip install -q openlane
openlane --version
docker version --format '{{.Server.Version}}'
