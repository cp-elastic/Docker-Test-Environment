#!/bin/bash

set -euo pipefail

kibana_token=$(cat /config/kibana/kibana_token)

echo "=== CREATE Keystore ==="
if [ -f /config/kibana/kibana.keystore ]; then
    echo "Remove old kibana.keystore"
    rm /config/kibana/kibana.keystore
fi
/usr/share/kibana/bin/kibana-keystore create

echo "Setting elasticsearch.serviceAccountToken"
echo "$kibana_token" | /usr/share/kibana/bin/kibana-keystore add 'elasticsearch.serviceAccountToken' -x
echo "done!"
echo "moving keystore to shared config"
mv /usr/share/kibana/config/kibana.keystore /config/kibana/kibana.keystore