#!/bin/bash

[ "$DEBUG" = "1" ] && set -x

GALERA_CONFIG=${GALERA_CONFIG:-"/etc/mysql/conf.d/galera.cnf"}
DATA_DIR=${DATA_DIR:-"/var/lib/mysql"}
HOSTNAME=$(hostname)
# Pod hostname in k8s StatefulSet is formatted as: "statefulset_name-index"
CLUSTER_NAME=${CLUSTER_NAME:-${HOSTNAME%%-*}}

# Copy default config file
if ! [ -f "${GALERA_CONFIG}" ]; then
	mkdir -p $(dirname "${GALERA_CONFIG}")
	cp /opt/galera/galera.cnf "${GALERA_CONFIG}"
fi

function str_join {
	local IFS="$1"; shift; echo "$*";
}

# Peer-finder pipes the sorted list of peer hosts
while read -ra LINE; do
	if [[ "${LINE}" == *"${HOSTNAME}"* ]]; then
		NODE_ADDRESS=$LINE
	else
		PEERS=("${PEERS[@]}" $LINE)
	fi
done

if [ "${#PEERS[@]}" = 0 ]; then
	echo "[INFO] Starting new Galera cluster"
	WSREP_CLUSTER_ADDRESS=""
	
	# TODO Find a better solution to automatically restore after a full cluster crash
	# Force start even if some latest TX are lost before a crash
	# otherwise the first container just cannot start.
	if [ "$SAFE_TO_BOOTSTRAP" = "1" ] && [ -f "$DATA_DIR/ibdata1" ] && [ -f "$DATA_DIR/grastate.dat" ]; then
		echo "[WARNING] Forcing safe_to_bootstrap on this node!"
		sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/g' "$DATA_DIR/grastate.dat"
	fi
else
	echo "[INFO] Joining Galera cluster: $WSREP_CLUSTER_ADDRESS"
	WSREP_CLUSTER_ADDRESS=$(str_join , "${PEERS[@]}")
fi

sed -i -e "s|^wsrep_node_address[[:space:]]*=.*$|wsrep_node_address=${NODE_ADDRESS}|" "${GALERA_CONFIG}"
sed -i -e "s|^wsrep_cluster_name[[:space:]]*=.*$|wsrep_cluster_name=${CLUSTER_NAME}|" "${GALERA_CONFIG}"
sed -i -e "s|^wsrep_cluster_address[[:space:]]*=.*$|wsrep_cluster_address=gcomm://${WSREP_CLUSTER_ADDRESS}|" "${GALERA_CONFIG}"

# don't need a restart, we're just writing the conf in case there's an
# unexpected restart on the node.
