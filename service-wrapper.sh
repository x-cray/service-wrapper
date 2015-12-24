#!/bin/sh

ME=$(basename $0)

if [ $# -lt 4 ]; then
	echo "Usage: $ME <marathon-host:port> <consul-host:port> <prefix> <command>"
	exit 1
fi

MARATHON=$1
CONSUL=$2
CONSUL_KV_WAIT=60s
PREFIX=$3
shift 3
APP="$@"

restart() {
	echo "$ME: Restarting ourselves via Marathon"
	curl -s -X POST -H "Content-Type: application/json" http://$MARATHON/v2/apps/$PREFIX/restart
}

terminate_child() {
	echo "$ME: Sending SIGTERM to child process"
	kill -TERM $CHILD_PID
}

quit() {
	kill -KILL $WATCHER_PID
	exit $1
}

watch() {
	local LAST_INDEX=$1
	local HEADERS
	local CURRENT_INDEX
	while :
	do
		HEADERS=$(curl -sS -o /dev/null -D - http://$CONSUL/v1/kv/$PREFIX/?recurse\&wait=$CONSUL_KV_WAIT\&index=$LAST_INDEX)
		CURRENT_INDEX=$(echo "$HEADERS" | grep -i X-Consul-Index: | awk {'print $2'} | tr -d '[[:space:]]')

		# Trigger restart if Consul KV chnges detected
		if [ "$CURRENT_INDEX" != "$LAST_INDEX" ]; then
			restart
			LAST_INDEX=$CURRENT_INDEX
		fi
	done
}

# Forward SIGTERM to underlying process for graceful shutdown
trap 'terminate_child' TERM
trap 'kill -INT $CHILD_PID; quit 0' INT

# Get environment from Consul
RESPONSE=$(curl -sS -i http://$CONSUL/v1/kv/$PREFIX/?recurse)
HEADERS=$(echo "$RESPONSE" | awk '{if(length($0)<2)exit;print}')
INDEX=$(echo "$HEADERS" | grep -i X-Consul-Index: | awk '{print $2}' | tr -d '[[:space:]]')
BODY=$(echo "$RESPONSE" | awk '{if(body)print;if(length($0)<2)body=1}')
ENV=$(echo "$BODY" | jq -r '.[] | [.Key, .Value] | join(" ")' \
| sed "s|$PREFIX/||" \
| grep -v '^\s*$' \
| \
while read KEY VALUE; do
	printf "export $KEY=%s\n" "$(echo "$VALUE" | base64 -d)"
done)

echo "$ME: Adding new variables to the environment"
eval "$ENV"

echo "$ME: Running $APP"
$APP &
CHILD_PID=$!

echo "$ME: Running Consul watcher"
watch $INDEX &
WATCHER_PID=$!
echo "$ME: Watcher PID $WATCHER_PID"

echo "$ME: Waiting for child PID $CHILD_PID"
while :
do
	wait $CHILD_PID
	WAIT_STATUS=$?
	if [ "$WAIT_STATUS" -le 128 ]; then
		echo "$ME: Child process completed. Exiting with $WAIT_STATUS"
		quit $WAIT_STATUS
	fi
done
