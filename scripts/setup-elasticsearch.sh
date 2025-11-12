#!/bin/bash

if [ -f /config/elasticsearch/elasticsearch.keystore ]; then
    echo "Keystore already exists. If you want to re-run please delete ./config/elasticsearch/elasticsearch.keystore"
elif [[ -n "$ELASTIC_PASSWORD" ]]; then
    echo "=== CREATE Keystore ==="
    echo "Elastic password is: $ELASTIC_PASSWORD"
    if [ -f /config/elasticsearch/elasticsearch.keystore ]; then
        echo "Remove old elasticsearch.keystore"
        rm /config/elasticsearch/elasticsearch.keystore
    fi
    [[ -f /usr/share/elasticsearch/config/elasticsearch.keystore ]] || (/usr/share/elasticsearch/bin/elasticsearch-keystore create)
    echo "Setting bootstrap.password..."
    (echo "$ELASTIC_PASSWORD" | /usr/share/elasticsearch/bin/elasticsearch-keystore add -x 'bootstrap.password')
    mv /usr/share/elasticsearch/config/elasticsearch.keystore /config/elasticsearch/elasticsearch.keystore
else
    echo "No Elastic Password Set, exiting!"
fi

if [ -f /config/ssl/docker-cluster-ca.zip ]; then
    echo "cluster-ca.zip already exists. If you want to re-run please delete ./config/ssl/docker-cluster-ca.zip "
else
    echo "=== CREATE SSL CERTS ==="
    echo "Creating docker-cluster-ca.zip..."
    /usr/share/elasticsearch/bin/elasticsearch-certutil ca --pem --out /config/ssl/docker-cluster-ca.zip
    # check if ca directory exists, if does, remove then unzip new files
    if [ -d /config/ssl/ca ]; then
        echo "CA directory exists, removing..."
        rm -rf /config/ssl/ca
    fi
    echo "Unzip ca files..."
    unzip /config/ssl/docker-cluster-ca.zip -d /config/ssl
    cat /config/ssl/ca/ca.crt | openssl x509 -noout -fingerprint -sha256 | cut -d "=" -f 2 | tr -d : > /config/ssl/ca/ca-fingerprint
    echo "Create cluster certs zipfile..."
    if [ -f /config/ssl/rendered-instances.yml ]; then
      rm -f /config/ssl/rendered-instances.yml
    fi
    (echo "cat <<EOF >/config/ssl/rendered-instances.yml"; cat /config/ssl/instances.yml; echo "EOF";) | bash < /dev/stdin 
    /usr/share/elasticsearch/bin/elasticsearch-certutil cert --silent --pem --in /config/ssl/rendered-instances.yml --out /config/ssl/docker-cluster.zip --ca-cert /config/ssl/ca/ca.crt --ca-key /config/ssl/ca/ca.key
    if [ -d /config/ssl/docker-cluster ]; then
        rm -rf /config/ssl/docker-cluster
    fi
    echo "Unzipping cluster certs zipfile..."
    unzip /config/ssl/docker-cluster.zip -d /config/ssl/docker-cluster
fi

 if [ -f /config/elasticsearch/service_tokens ]; then
     echo "Service tokens already exist. If you want to re-run please delete ./config/elasticsearch/service_tokens"
 else
     echo "Create Kibana service token"
     kibana_token=$(/usr/share/elasticsearch/bin/elasticsearch-service-tokens create elastic/kibana kibana-token | cut -d ' ' -f 4)
     echo "$kibana_token" > /config/kibana/kibana_token
     echo "Done!"
     echo "Move service tokens file to config directory, chown 1000"
     mv -f /usr/share/elasticsearch/config/service_tokens /config/elasticsearch/service_tokens
     chown 1000 /config/elasticsearch/service_tokens
 fi