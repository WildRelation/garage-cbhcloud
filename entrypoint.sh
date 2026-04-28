#!/bin/sh
set -e
mkdir -p /data/meta /data/data
exec garage "$@"
