#!/bin/bash

set -euo pipefail

beat=$1

echo "=== Setting up ${beat^}... ==="
echo "Waiting for Kibana"
until [[ "$(curl -XGET -s -u elastic:"$ELASTIC_PASSWORD" https://"$KIBANA_HOST":5601/api/status --cacert /usr/share/"$beat"/certs/ca/ca.crt -w "%{http_code}" -o /dev/null)" = "200" ]]; do
	sleep 5
done
echo "Kibana is ready!"

if [ -f "/config/$beat/$beat.keystore" ]; then
	echo "$beat keystore already exists. If you want to re-run please delete ./config/$beat/$beat.keystore"
else
	chmod go-w "/usr/share/$beat/$beat.yml"
	cd "/usr/share/$beat"
	echo "Creating keystore..."
	eval "${beat} --strict.perms=false keystore create --force"
	chmod go-w /usr/share/$beat/$beat.yml
	echo "adding ES_PASSWORD to keystore..."
	echo "$ELASTIC_PASSWORD" | ${beat} --strict.perms=false keystore add ES_PWD --stdin > /dev/null
	eval "${beat} --strict.perms=false keystore list"
	echo "Copy keystore to ./config dir"
	cp "/usr/share/$beat/data/$beat.keystore" "/config/$beat/$beat.keystore"
	chown 1000 "/config/$beat/$beat.keystore"
	chown 1000 "/config/$beat/$beat.yml"
fi

echo "Check if setup complete..."
if [[ "$(curl -XGET -s -u elastic:"$ELASTIC_PASSWORD" "$ELASTICSEARCH_HOSTS"/_data_stream/"$beat"-"$TAG" --cacert /usr/share/"$beat"/certs/ca/ca.crt -w "%{http_code}" -o /dev/null)" != "200" ]]; then
	if [ "$beat" != apm-server ]; then
	echo "Setting up dashboards..."
	eval "${beat} --strict.perms=false setup -v"
	fi
fi

echo "=== ${beat^} setup done! ==="
