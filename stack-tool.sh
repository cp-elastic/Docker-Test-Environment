#!/bin/bash

# Static variables
confDir="config"
envFile=".env"

# root check
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Load vars from .env
while read -r i; do
    if [[ "$i" =~ ^[^=]*=.*$ ]]; then
      key=$( echo "$i" | cut -d '=' -f 1 )
      value=$( echo "$i" | cut -d '=' -f 2-10 )
      export "$key"="$value"
      echo "=== exported $key with value $value ==="
    fi
done < $envFile

start_stack() {
  # Set elastic password in .env if not already set
  if [ -z "$ELASTIC_PASSWORD" ]; then
      echo '=== Generate Elastic Password ==='
      PW=$(openssl rand -hex 32;)
      ELASTIC_PASSWORD="${PW}"
      echo -e "\nELASTIC_PASSWORD=${PW}" >> $envFile
  else   
      echo "=== Password Found! ==="
  fi
  export ELASTIC_PASSWORD

  # Elastic will whine without this
  echo '=== Set host mem max ===' 
  sysctl -w vm.max_map_count=262144
  sysctl -w vm.swappiness=1

  # chown keystores and config yml files
  echo '=== chown all the things ==='
  find "$confDir" -type f -name "*.keystore" -exec chmod 664 {} \;
  find "$confDir" -type f -name "*.yml" -exec chmod 664 {} \;

  # start elasticsearch bootstrap and 3 node cluster
  echo '=== Setting up the environment ==='
  chown 1000 -R config/elasticsearch

  $composeCommand -f docker-compose.yml -f docker-compose.setup.yml up setup_elasticsearch
  # remove orphaned setup containers
  echo '=== Removing Elasticsearch Setup Container ==='
  # shellcheck disable=SC2046
  docker container rm -f $(docker container ls -a | grep "setup_elasticsearch" | cut -d ' ' -f 1) >> /dev/null

  $composeCommand -f docker-compose.yml up -d elasticsearch01 elasticsearch02 elasticsearch03
  until [[ $connTest == *green* ]]; do
      connTest=$(curl -k -s https://elastic:"$ELASTIC_PASSWORD"@localhost:9200/_cat/health)
      echo "$connTest"
      echo "Waiting for Elasticsearch to turn green..."
      sleep 5
  done

  # get UUID for monitoring
  # UUID=$(curl --cacert ./$confDir/ssl/ca/ca.crt -s https://elastic:"$ELASTIC_PASSWORD"@localhost:9200 | grep "uuid" | cut -d \" -f 4)
  # export UUID

  # start kibana setup
  chown 1000 -R config/kibana
  $composeCommand -f docker-compose.yml -f docker-compose.setup.yml up setup_kibana

  echo '=== Removing Kibana Setup Container ==='
  # shellcheck disable=SC2046
  docker container rm -f $(docker container ls -a | grep "setup_kibana" | cut -d ' ' -f 1) >>/dev/null

  # start Kibana
  $composeCommand -f docker-compose.yml up -d kibana
}

start_fleet() {

  if [ -z "$fleetLocalID" ]; then
    # Create Fleet Server Token
    curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/service_tokens
    echo -e '\n'

    # Setup Default Fleet Server Instance
    echo "=== Setting Fleet Server values ==="
    curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/settings -d '
    {
      "fleet_server_hosts": [
        "https://fleet-server:8220"
      ]
    }'
    echo -e '\n'

    # POST New Fleet Server with Localhost
    fleetLocalID=$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/fleet_server_hosts -d '
    {
      "name": "Localhost",
      "host_urls": [
        "https://127.0.0.1:8220"
      ],
      "is_default": false
    }'| cut -d \" -f 6)
    echo -e "\nfleetLocalID=${fleetLocalID}" >> $envFile
  else
    echo "=== Fleet Server already configured ==="
  fi

  if [ -z "$certFP" ]; then
    # Setup Default Elasticsearch Output
    curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/outputs/fleet-default-output -d '
    {
      "hosts": [
        "https://elasticsearch01:9200"
      ]
    }'
    echo -e '\n'

    # Get CA cert fingerprint and set as trusted + certificate verification
    certFP=$(openssl x509 -in config/ssl/ca/ca.crt --noout -fingerprint -sha256 | cut -d = -f 2 | sed 's/://g')
    echo -e "\ncertFP=${certFP}" >> $envFile

    curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/outputs/fleet-default-output -d "
    {
      \"ca_trusted_fingerprint\": \"$certFP\",
      \"config_yaml\": \"ssl.verification_mode: certificate\"
    }"
    echo -e '\n'

    # POST New ES Destination with Localhost
    esLocalID=$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/outputs -d "
    {
      \"name\": \"Localhost\",
      \"type\": \"elasticsearch\",
      \"hosts\": [\"https://127.0.0.1:9200\"],
      \"is_default\": \"false\",
      \"is_default_monitoring\": \"false\",
      \"ca_trusted_fingerprint\": \"$certFP\",
      \"config_yaml\": \"ssl.verification_mode: certificate\"
    }" | cut -d \" -f 6)
    echo -e "\nesLocalID=${esLocalID}" >> $envFile
  else
    echo "=== Elasticsearch output already configured ==="
  fi

  # Generate "fleet-server-policy"
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/agent_policies?sys_monitoring=true -d '
  {
    "id":"fleet-server-policy",
    "name":"Fleet Server Policy",
    "description":"Fleet Server policy generated by Kibana",
    "namespace":"default",
    "has_fleet_server":true,
    "monitoring_enabled":["logs","metrics"],
    "is_default_fleet_server":true
  }'
  echo -e '\n'

  # Create endpoint policy
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/agent_policies?sys_monitoring=true -d "
  {
    \"id\":\"endpoints\",
    \"name\":\"Endpoints\",
    \"description\":\"Default Endpoint Policy\",
    \"namespace\":\"default\",
    \"monitoring_enabled\":[\"logs\",\"metrics\"],
    \"data_output_id\": \"$esLocalID\",
    \"monitoring_output_id\": \"$esLocalID\",
    \"fleet_server_host_id\": \"$fleetLocalID\"
  }"
  echo -e '\n'

  # Start Fleet Server
  $composeCommand -f docker-compose.yml up -d fleet-server
}

start_beats() {
  # Do Beats setup
  $composeCommand -f docker-compose.yml -f docker-compose.setup.yml up setup_auditbeat setup_filebeat setup_metricbeat setup_packetbeat setup_heartbeat
   
  # remove orphaned setup containers
  echo '=== Removing Setup Containers ==='
  # shellcheck disable=SC2046
  docker container rm -f $(docker container ls -a | grep "setup_.*beat" | cut -d ' ' -f 1)
  
  # Start Beats
  echo '=== Starting Beats ==='
  find "$confDir" -type f -name "*.keystore" -exec chmod 664 {} \;
  find "$confDir" -type f -name "*.yml" -exec chmod 664 {} \;
  $composeCommand -f docker-compose.yml up -d filebeat metricbeat heartbeat auditbeat packetbeat
}

start_agent () {
  # get fleet enpoint policy enrollment key
  endpointEnrollKey=$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XGET "${kibanaHeaders[@]}" https://127.0.0.1:5601/api/fleet/enrollment_api_keys | grep -Eo "\"api_key\":\"[^\"]*\",\"name\":\"[^\"]*\",\"policy_id\":\"endpoints\"" | head -n1 | cut -d \" -f 4)

  # copy generated CA to localhost
  cp -f config/ssl/ca/ca.crt /etc/ssl/certs/ca.crt

  # setup agent on localhost + enroll to policy
  if [ ! -f "elastic-agent-${TAG}-linux-x86_64.tar.gz" ]; then
    echo "Downloading Elastic Agent..."
    curl -sL -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-"$TAG"-linux-x86_64.tar.gz >> /dev/null
  else
    echo "Elastic Agent already downloaded..."
  fi
  if [ ! -d "elastic-agent-${TAG}-linux-x86_64" ]; then
  echo "Unzipping Elastic Agent..."
  tar xzvf elastic-agent-"$TAG"-linux-x86_64.tar.gz >> /dev/null
  else
    echo "Elastic Agent already unzipped..."
  fi
  ./elastic-agent-"$TAG"-linux-x86_64/elastic-agent install -i --url=https://127.0.0.1:8220 --enrollment-token="$endpointEnrollKey" --force
}

start_apps () {
  # build demo app container from dockerfile
  echo '=== Build demo app container ==='
  cd ./apps/nodejs-demoapp/build || exit
  docker build . --tag nodejs:local
  cd ../../..

  echo '=== Starting Apps ==='
  $composeCommand -f docker-compose.yml up -d nsm-zeek nsm-suricata app-nodejs app-traffic-gen opencanary
}

start_logstash () {
  echo '=== Starting Setup Logstash ==='
  # Start Logstash
  $composeCommand -f docker-compose.yml -f docker-compose.setup.yml up -d setup_logstash

  echo '=== Removing Setup Logstash ==='
  # shellcheck disable=SC2046
  docker container rm -f $(docker container ls -a | grep "setup_logstash" | cut -d ' ' -f 1)

  echo '=== Starting Logstash ==='
  $composeCommand -f docker-compose.yml up -d logstash

}

setup_elser () {

  # wait for kibana to be ready
  until [[ "$(curl -XGET -k -s -u elastic:"$ELASTIC_PASSWORD"  https://127.0.0.1:5601/api/status -w "%{http_code}" -o /dev/null)" = "200" ]]; do
    echo "Waiting for Kibana..."
    sleep 5
  done
  echo "Kibana is ready!"
  echo -e '\n'

  # download model
  echo '=== Downloading ELSER Model ==='
  case "$TAG" in
    8.9.0)
      curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPUT https://127.0.0.1:5601/internal/ml/trained_models/.elser_model_1 -d '{"input":{"field_names":["text_field"]}}'
      echo -e '\n'
      echo -e '=== Deploying ELSER Model ==='
      elserDeploy=$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPOST 'https://127.0.0.1:5601/internal/ml/trained_models/.elser_model_1/deployment/_start?number_of_allocations=1&threads_per_allocation=4&priority=normal&deployment_id=.elser_model_1')
      if [[ "$elserDeploy" == *"existing deployment with the same id"* ]]; then
        echo "ELSER model already deployed..."
      else
          until [[ "$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPOST 'https://127.0.0.1:5601/internal/ml/trained_models/.elser_model_1/deployment/_start?number_of_allocations=1&threads_per_allocation=4&priority=normal&deployment_id=.elser_model_1' -w "%{http_code}" -o /dev/null)" = "200" ]]; do
          sleep 5
          echo "Waiting for model to download..."
          done
      fi
      echo -e '\n'
    ;;
    8.8.2)
      curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPUT https://127.0.0.1:5601/api/ml/trained_models/.elser_model_1 -d '{"input":{"field_names":["text_field"]}}'
      echo -e '=== Deploying ELSER Model ==='
      elserDeploy=$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPOST 'https://127.0.0.1:5601/api/ml/trained_models/.elser_model_1/deployment/_start?number_of_allocations=1&threads_per_allocation=1&priority=normal&deployment_id=.elser_model_1')
      if [[ "$elserDeploy" == *"existing deployment with the same id"* ]]; then
        echo "ELSER model already deployed..."
      else
          until [[ "$(curl -k -s -u "elastic:${ELASTIC_PASSWORD}" "${kibanaHeaders[@]}" -XPOST 'https://127.0.0.1:5601/api/ml/trained_models/.elser_model_1/deployment/_start?number_of_allocations=1&threads_per_allocation=1&priority=normal&deployment_id=.elser_model_1' -w "%{http_code}" -o /dev/null)" = "200" ]]; do
          sleep 5
          echo "Waiting for model to download..."
          done
      fi
      echo -e '\n'
    ;;
    *)
      echo "Automated download of ELSER model not available for this version of Kibana, please try manually!"
    ;;
  esac
  echo -e '\n'

  # create index pipeline with processor
  echo '=== Creating ELSER Index Pipeline ==='
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT https://127.0.0.1:9200/_ingest/pipeline/elser-v1 -H 'Content-Type: application/json' -d '
  {
    "processors": [
      {
        "rename": {
          "field": "message",
          "target_field": "text_field"
        }
      },
      {
        "inference": {
          "model_id": ".elser_model_1",
          "target_field": "ml",
          "field_map": { 
            "text": "text_field"
          },
          "inference_config": {
            "text_expansion": { 
              "results_field": "tokens"
            }
          }
        }
      }
    ]
  }'

  echo -e '\n'

  # create test-data index mapping
  echo '=== Creating Test-Data Index Mapping ==='
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT https://127.0.0.1:9200/test-data -H 'Content-Type: application/json' -d '
  {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "auto_expand_replicas": "0-1"
      }
    },
    "mappings": {
      "properties": {
        "message": { 
          "type": "text" 
        }
      }
    }
  }'

  echo -e '\n'
  
  # create ELSER index mapping
  echo '=== Creating ELSER Index Mapping ==='
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPUT https://127.0.0.1:9200/elser-index -H 'Content-Type: application/json' -d '
  {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "auto_expand_replicas": "0-1",
        "default_pipeline": "elser-v1"
      }
    },
    "mappings": {
      "properties": {
        "ml.tokens": { 
          "type": "rank_features" 
        },
        "text": { 
          "type": "text" 
        }
      }
    }
  }'

  echo -e '\n'
  
  # download test data
  echo '=== Downloading Test Data ==='
  if [ ! -f "resources/msmarco-passagetest2019-unique.tsv" ]; then
    echo "Downloading data..."
    wget https://raw.githubusercontent.com/elastic/stack-docs/main/docs/en/stack/ml/nlp/data/msmarco-passagetest2019-unique.tsv -O resources/msmarco-passagetest2019-unique.tsv
  else
    echo "Data already downloaded..."
  fi

  echo -e '\n'

  # # Index TSV through ingest pipeline
  # echo '=== Indexing Test Data ==='
  # numLine=$(wc -l resources/msmarco-passagetest2019-unique.tsv | cut -d ' ' -f 1)
  # curLine=1
  # while read -r line; do
  #   echo -e "\nIndexing line $curLine of $numLine"
  #   cleanLine=$(echo "$line" | sed 's/\t/,/g' | sed 's/\r//' )
  #   # echo $cleanLine
  #   curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST https://127.0.0.1:9200/elser-index/_doc?pipeline=elser-v1 -H 'Content-Type: application/json' -d "
  #   {
  #       \"message\": \"${cleanLine}\"
  #   }"
  #   curLine=$((curLine+1))
  # done < resources/msmarco-passagetest2019-unique.tsv

  # convert TSV to ndjson
   echo '=== Load Test Data ==='
  if [ ! -f "resources/msmarco-passagetest2019-unique.ndjson" ]; then
    echo "Converting data..."
    # shellcheck disable=SC2002
    # shellcheck disable=SC1003
    cat resources/msmarco-passagetest2019-unique.tsv | tr -d '\\' | sed 's/.*\t//g' | sed 's/^/{"index":{"_index":"test-data"}}\n{"message":"/g' | sed 's/\r/"}/g' >> resources/msmarco-passagetest2019-unique.ndjson
    echo "Data converted!"
  else
    echo "Data already converted..."
  fi

  echo -e '\n'

  # Bulk index new ndjson file
  echo "Loading test data..."
  curl -k -s -u "elastic:${ELASTIC_PASSWORD}" -XPOST https://127.0.0.1:9200/_bulk -H 'Content-Type: application/x-ndjson' --data-binary '@resources/msmarco-passagetest2019-unique.ndjson' >> /dev/null

  echo "Test data loaded!"

  # reindex through ELSER pipeline, pipeline is defined in the index settings
  echo "Start reindex through ELSER pipeline"
  curl -k -u "elastic:${ELASTIC_PASSWORD}" -XPOST https://127.0.0.1:9200/_reindex?wait_for_completion=false  -H 'Content-Type: application/json' -d '
  {
    "source": {
      "index": "test-data",
      "size": 100
    },
    "dest": {
      "index": "elser-index"
    }
  }'
}

start_enterprisesearch () {
  $composeCommand -f docker-compose.yml up -d enterprisesearch
}

clean_stack() {
  # recreate .env file
  echo "TAG=$TAG" > $envFile

  # REMOVE EXISTING CONTAINERS
  # shellcheck disable=SC2046
  docker container rm -f $(docker container ls -aq)

  # REMOVE EXISTING VOLUMES
  # shellcheck disable=SC2046
  docker volume rm -f $(docker volume ls -q)

  # REMOVE EXISTING NETWORKS
  # shellcheck disable=SC2046
  docker network rm $(docker network ls -q)

  # REMOVE EXISTING IMAGES
  # shellcheck disable=SC2046
  #docker image rm -f $(docker image ls -q)

  find "$confDir" -type f -name "*.keystore" -exec rm -f {} \;
  find "$confDir" -type f -name "*.crt" -exec rm -f {} \;
  find "$confDir" -type f -name "*.key" -exec rm -f {} \;
  find "$confDir" -type f -name "*.zip" -exec rm -f {} \;
  find "$confDir" -type f -name "*token*" -exec rm -f {} \;

  # uninstall Elastic Agent
  /opt/Elastic/Agent/elastic-agent uninstall -f || exit
  exit
}

# main function

# define Kibana headers
kibanaHeaders=(
    -H "kbn-verson: $TAG"
    -H "kbn-xsrf: kibana"
    -H 'Content-Type: application/json'
    -H "Elastic-Api-Version: 2023-10-31"
)

# Get docker compose version
composeCommand="$(which docker-compose || which docker)"
if [[ "$composeCommand" =~ .*docker$ ]]; then
    composeCommand+=" compose"
fi

# Get options if present
case $1 in
  start)
    case $2 in
      stack)
        start_stack
        ;;
      beats)
        start_beats
        ;;
      logstash)
        start_logstash
        ;;
      apps)
        start_apps
        ;;
      agent)
        start_agent
        ;;
      fleet)
        start_fleet
        ;;
      enterprisesearch)
        start_enterprisesearch
        ;;
      ai)
        start_stack
        start_enterprisesearch
        setup_elser
        ;;
      security)
        start_stack
        start_beats
        start_fleet
        start_apps
        start_agent
        ;;
      all)
        start_stack
        start_enterprisesearch
        setup_elser
        start_beats
        start_fleet
        start_apps
        start_agent
        ;;
      *)
        echo "To start components, use:"
        echo "Usage: $0 start (all|beats|logstash|apps|agent|fleet|enterprisesearch)"
        echo "OR To start personas, use:"
        echo "Usage: $0 start (stack|security|ai)"
        exit 1
        ;;
    esac
    ;;
  stop)
    $composeCommand -f docker-compose.yml down -v
    ;;
  clean)
    clean_stack
    ;;
  *)
    echo "Usage: $0 {start|stop|clean}"
    exit 1
    ;;
esac

  # done
  echo -e "\nSetup completed successfully!\n"
  echo -e "\nYour 'elastic' user password is: $ELASTIC_PASSWORD\n"