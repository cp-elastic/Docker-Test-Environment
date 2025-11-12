
#!/bin/bash

set -euo pipefail

cacert=/usr/share/logstash/config/ca/ca.crt
# Wait for ca file to exist before we continue. If the ca file doesn't exist
# then something went wrong.
while [ ! -f $cacert ]
do
  echo "CA cert missing!"
  sleep 2
done
echo "Found CA cert!"

es_url=https://elasticsearch01:9200
# Wait for Elasticsearch to start up before doing anything.
while [[ "$(curl -u "elastic:${ELASTIC_PASSWORD}" --cacert $cacert -s -o /dev/null -w '%{http_code}' $es_url)" != "200" ]]; do 
    echo "Elasticsearch isn't ready `curl -u "elastic:${ELASTIC_PASSWORD}" -k -s --cacert $cacert $es_url`"
    sleep 5
done
echo "Elasticsearch is ready!" 

# Set the password for the logstash user.
# REF: https://www.elastic.co/guide/en/x-pack/6.0/setting-up-authentication.html#set-built-in-user-passwords
# until curl -u "elastic:${ELASTIC_PASSWORD}" --cacert $cacert -s -H 'Content-Type:application/json' \
#      -XPUT $es_url/_xpack/security/user/logstash_system/_password \
#      -d "{\"password\": \"${ELASTIC_PASSWORD}\"}"
# do
#     sleep 2
#     echo Retrying...
# done


# echo "=== CREATE Keystore ==="
if [ -f /config/logstash/logstash.keystore ]; then
    echo "Remove old logstash.keystore"
    rm /config/logstash/logstash.keystore
fi
# echo "y" | /usr/share/logstash/bin/logstash-keystore create
# echo "Setting ELASTIC_PASSWORD..."
# echo "$ELASTIC_PASSWORD" | /usr/share/logstash/bin/logstash-keystore add 'ES_PWD' -x
# mv /usr/share/logstash/config/logstash.keystore /config/logstash/logstash.keystore
# chown 1000 /config/logstash/logstash.keystore
chown 1000 /config/logstash/logstash.yml

echo "Set up Logstash-System user"
until curl --cacert $cacert -s -u "elastic:${ELASTIC_PASSWORD}" -H 'Content-Type:application/json' \
     -XPUT $es_url/_security/user/logstash_system/_password \
     -d "{\"password\": \"${ELASTIC_PASSWORD}\"}"
do
    sleep 2
    echo Retrying...
done
echo "Done!"
