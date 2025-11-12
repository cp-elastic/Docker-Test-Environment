## About
**Version 8.19.7**<br>
This is a project to have an environment for consultants to demo/test/train on that is easy and fast to set up. <br>
It is tested and working on a single **e2-standard-4** running Debian with **500GB** disk.
<br>
<br>
This environment features 3 "personas" that can be used to demo different aspects of the Elastic Stack. <br>
**NOTE:** Components are modular and can be started individually or as a group. <br>
<br>
All personas have (stack):
* 3 node Elasticsearch cluster (all roles)
* Kibana
* Automated TLS

The Security persona has:
* Demo Node.JS app with simulated traffic
* OpenCanary for tripwire / honeypot
* Suricata, Packetbeat, Auditbeat, Zeek
  * Monitoring <b>all</b> host network traffic as if it were locally installed
* Metricbeat
* Heartbeat
* Filebeat

The AI persona has:
* Automated import of ELSER (Elasticsearch Learned Sparse EncodeR)
* Includes test data that will be automatically imported and parsed by ELSER
* Enterprise Search
* More features on the way!


**NOTE:** *This will not work in WSL (Windows Subsystem for Linux) due to limitations of the product*
## Quickstart
Requires openssl, docker, docker-compose or docker compose plugin, wget<br>
Firewall:<br>
* Allow SSH in, if you want
* Allow 5601/tcp in for Kibana
* Allow 3000/tcp in for demo node.js app
<br>
<br>
Then do:

```
git clone https://github.com/elastic-egs/docker-test-environment.git
cd docker-test-environment
# To start individual components
bash stack-tool.sh start (all|stack|beats|apps|fleet|agent|enterprisesearch)
# OR to start personas
bash stack-tool.sh start (security|ai|stack)
bash stack-tool.sh stop # To stop containers
bash stack-tool.sh clean # To clean up containers and environemnt
```
Benchmark with Rally:
```
docker run --network="docker-test-environment_stack" elastic/rally race --track=nyc_taxis --pipeline=benchmark-only --target-hosts=https://elasticsearch01:9200,https://elasticsearch02:9200,https://elasticsearch03:9200 --client-options="use_ssl:true,verify_certs:false,basic_auth_user:'elastic',basic_auth_password:'$ELASTIC_PASSWORD'"
```

## Wishlist
Add TheHive: https://docs.strangebee.com/thehive/setup/installation/docker/#quick-start<br>
Add Cortex: https://docs.thehive-project.org/cortex/installation-and-configuration/#run-with-docker<br>
Add Tines<br>
Add more AI features

