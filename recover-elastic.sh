#!/bin/bash
# to recover failed insert attempts by logstash to elasticsearch
# by Turvas c 2017
#
# we create new inex, by adding suffix to expected index name
INDEX_SUFFIX=a
# some output formatting helpers
bold=$(tput bold)
normal=$(tput sgr0)
reverse=$(tput rev)
# change to match you elasticsearch logfiles location
LOGPATH=/log_data/elasticsearch/logs
FILEPATTERN=elasticsearch-2017-12-23*.log.gz
FILES=$LOGPATH/$FILEPATTERN
#log for this script activity
RECOVERYLOG=/tmp/recovery.log
#start iterating all pattern matching logfiles
for file in $FILES
do
 echo ${bold} Processing "${file}" ${normal}
 echo $(date) Start Processing "${file}" >> $RECOVERYLOG
 gunzip -c "${file}" > /tmp/workfile.log
 # extract only data
 grep -Po "source\[\K.*?(?=\]\}\])" /tmp/workfile.log > /tmp/workfile.json
 # file size
 FILESIZE=$(stat -c%s /tmp/workfile.json)
 if [[ $FILESIZE > 0 ]]
 then
        # insert odd lines needed for bulk import, this has to be 2 lines to get newline there
        sed 's/^{/\{"index": {}}\
{/' < /tmp/workfile.json > /tmp/workfile-prepared.json
        # calculate index name
        INDEX=$(echo "${file}" | sed -re 's|.*elasticsearch-([0-9]{4})-([0-9]{2})-([0-9]{2}).*|logstash-\1.\2.\3|')$INDEX_SUFFIX
        # get initial count of docs, except when empty index initially, then "error"
        INITIAL=$(curl -s -XGET http://localhost:9200/$INDEX/syslog/_count | sed -re 's|.*count":([0-9]+).*|\1|' | grep -v error)
        # if empty index then INITIAL would be empty
        if [[ -z $INITIAL ]]
        then
                INITIAL=0
        fi
        echo ${bold} Adding to index $INDEX, currently $INITIAL records ${normal}
        # insert silently, enable http response headers, needs to be binary due to newlines
        curl -i -o /tmp/elastic-response.txt -XPOST http://localhost:9200/$INDEX/syslog/_bulk -H "Content-Type: application/x-ndjson" --data-binary @/tmp/workfile-prepared.json
        FINAL=$(curl -s -XGET http://localhost:9200/$INDEX/syslog/_count | sed -re 's|.*count":([0-9]+).*|\1|')
        # if elastic is alive, then response is notempy, if dead then response is empty
        if [[ ! -z $FINAL ]]
        then
                echo ${bold} Added $((FINAL - INITIAL)) records, now total: $FINAL ${normal}
                echo $(date) Completed Processing, added $((FINAL - INITIAL)) records to $INDEX, now total: $FINAL >> $RECOVERYLOG
        else
                echo ${reverse} Elasticsearch is dead restarting it.. ${normal}
                echo $(date) Elasticsearch failed, restarting..  >> $RECOVERYLOG
                systemctl start elasticsearch
        fi
        top -bn 1 | head -20
        sleep 5
  fi
done
