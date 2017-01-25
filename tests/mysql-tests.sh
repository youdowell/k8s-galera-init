#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"

NAMESPACE="mysql-test"
label="app=mysql"

FAILED="`tput setaf 1`FAILED`tput sgr0`"
PASSED="`tput setaf 2`PASSED`tput sgr0`"
TIMEOUT=120s

# --------------------------------------
# K8S RESOURCES
# --------------------------------------
create() {
	kubectl create namespace ${NAMESPACE} --dry-run -o yaml | kubectl apply -f - 
}

start() {
	kubectl --namespace ${NAMESPACE} apply --recursive --timeout=$TIMEOUT  -f "$DIR/example"
}

stop() {
	kubectl --namespace ${NAMESPACE} delete svc,statefulset -l "$label"
	echo -n "Waiting until all pods are stopped ["
	timeout=$((SECONDS + 120))
	while [ $SECONDS -lt $timeout ]; do
		pods=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --no-headers 2>/dev/null)
		[ -z "$pods" ] && echo "OK]" && break
		sleep 2
		echo -n "."
	done
}

delete() {
	kubectl --namespace ${NAMESPACE} delete svc,statefulset,pvc,pv -l "$label"
	kubectl delete namespace ${NAMESPACE} --timeout=$TIMEOUT --force
}

# --------------------------------------
# UTILITIES
# --------------------------------------

before() {
	echo
	echo "[+] $1"
	RUNNING_TEST=$1
	ERRORS=()
	start
}

after() {
	echo ----------------------------------------
}

pass() {
	echo "[+] ${FUNCNAME[1]}: $PASSED"
}

fail() {
	#stacktrace=(${FUNCNAME[@]:1})
	#unset 'stacktrace[${#stacktrace[@]}-1]'
	msg="$@"
	echo "[+] ${FUNCNAME[1]}: $FAILED ${msg:+"- $msg"}"
	echo
	ERRORS+=("${FUNCNAME[1]} ${msg}")
	exit 1
}

exec_sql() {
	pod=$1
	sql=$2
	mysql_cmd='mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}"'
	kubectl --namespace ${NAMESPACE} exec "$pod" -- bash -c "${mysql_cmd} -e '${sql}' -q --skip-column-names ${@:3}"
}

populate_test_data() {
	pod=${1:-"mysql-0"}
	degree=${2:-20}
	exec_sql "$pod" 'DROP DATABASE IF EXISTS test;'
	exec_sql "$pod" 'CREATE DATABASE test;'
	exec_sql "$pod" 'CREATE TABLE test.rnd_values (id BIGINT NOT NULL AUTO_INCREMENT, val INT NOT NULL, PRIMARY KEY (id));'
	exec_sql "$pod" 'INSERT INTO test.rnd_values (val) VALUES (rand()*10000);'
	echo -n "Populating random values ["
   	for i in $(seq 1 $degree); do
		exec_sql "$pod" 'INSERT INTO test.rnd_values (val) SELECT a.val * rand() FROM test.rnd_values a;'
		cnt=$(exec_sql "$pod" "SELECT count(*) from test.rnd_values;")
		echo -n "...$cnt"
   	done
	echo "]"
}

wait_ready() {
	wait_count=${1:-1}
	echo -n "Waiting until exactly $wait_count containers ready ["
	timeout=$((SECONDS + 120))
	while [ $SECONDS -lt $timeout ]; do
		ready_count=$(kubectl --namespace ${NAMESPACE} get pods -l "$label" -o yaml 2>/dev/null | grep "ready: true" -c || true)
		[ $ready_count -eq $wait_count ] && echo "OK]" && break
		sleep 2
		echo -n "."
	done
	if [ $ready_count -ne $wait_count ]; then
		fail "Containers ready expected exactly '$wait_count' but was '$ready_count'!"
	fi	
}

# --------------------------------------
# TESTS
# --------------------------------------
test_clusterShutdown_recovered() {
	## Given
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=3 --timeout=$TIMEOUT
	wait_ready 3
	populate_test_data "mysql-1"
 	#kubectl --namespace ${NAMESPACE} delete po -l "$label" --grace-period=0 --force
 	
 	## When
 	stop
 	start 	
	wait_ready 3 120

  	## Then
	echo "Testing values"
	if ! exec_sql "mysql-0" "SHOW DATABASES;" | grep "test" &>/dev/null; then
		fail "Test database not found on pod mysql-0!"
	fi
	
	for i in {0..2}; do
		pod="mysql-$i"
    	cnt_actual=$(exec_sql "$pod" "SET SESSION wsrep_sync_wait = 1; SELECT count(*) from test.rnd_values;")
		echo "Values count on '$pod': $cnt_actual"
    	if [ $cnt -ne $cnt_actual ]; then
    		fail "Random values count on '$pod' expected '$cnt' but was '$cnt_actual'"
    	fi
	done
	
	pass
}

test_clusterCrash_recovered() {
  	## Given
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=3 --timeout=$TIMEOUT
	wait_ready 3
	populate_test_data "mysql-1"
    cnt=$(exec_sql "mysql-0" "SET SESSION wsrep_sync_wait = 1; SELECT count(*) from test.rnd_values;")

	# Crashing all cluster nodes
    #	for 1 in {1..3}; do
    #		docker kill $(docker ps -q -f name=mysql-${i})
    #	done
 	kubectl --namespace ${NAMESPACE} delete po -l "$label" --grace-period=0 --force --timeout=$TIMEOUT

 	## When
	start
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=3 --timeout=$TIMEOUT
	wait_ready 3

  	## Then
	echo "Testing values"
	if ! exec_sql "mysql-0" "SHOW DATABASES;" | grep "test" &>/dev/null; then
		fail "Test database not found on pod mysql-0!"
	fi
	
	for i in {0..2}; do
		pod="mysql-$i"
    	cnt_actual=$(exec_sql "$pod" "SET SESSION wsrep_sync_wait = 1; SELECT count(*) from test.rnd_values;")
		echo "Values count on '$pod': $cnt_actual"
    	if [ $cnt -ne $cnt_actual ]; then
    		fail "Random values count on '$pod' expected '$cnt' but was '$cnt_actual'"
    	fi
	done
	
	pass
}

test_nodeCrash_recovered() {
 	## Given
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=3 --timeout=$TIMEOUT
	wait_ready 3

 	## When
	# Crashing first cluster node
 	kubectl --namespace ${NAMESPACE} delete po "mysql-0" --grace-period=0 --force

	# Populating data on another node
	populate_test_data "mysql-1" 10

  	# Wait until all nodes are back
	wait_ready 3
	
  	## Then
	echo "Testing values"
	for i in {0..2}; do
		pod="mysql-$i"
    	cnt_actual=$(exec_sql "$pod" "SET SESSION wsrep_sync_wait = 1; SELECT count(*) from test.rnd_values;")
		echo "Values count on '$pod': $cnt_actual"
    	if [ $cnt -ne $cnt_actual ]; then
    		fail "Values count on '$pod' expected '$cnt' but was '$cnt_actual'"
    	fi
	done
	
	pass
}

test_scale_recovered() {
 	## Given
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=1 --timeout=$TIMEOUT
	wait_ready 1

 	## When
	populate_test_data "mysql-0" 10

  	## Then
	kubectl --namespace ${NAMESPACE} scale statefulsets mysql --replicas=3 --timeout=$TIMEOUT
	wait_ready 3

	echo "Testing values"
	for i in {0..2}; do
		pod="mysql-$i"
    	cnt_actual=$(exec_sql "$pod" "SET SESSION wsrep_sync_wait = 1; SELECT count(*) from test.rnd_values;")
		echo "Values count on '$pod': $cnt_actual"
    	if [ $cnt -ne $cnt_actual ]; then
    		fail "Values count on '$pod' expected '$cnt' but was '$cnt_actual'"
    	fi
	done
	
	pass
}

# --------------------------------------
# MAIN
# --------------------------------------
all_tests=$(sed -nE 's/^(test_[a-zA-Z0-9_]+)[[:space:]]*[\(\{].*$/\1/p' $0)

run_tests() {
	create
	echo "Running tests..."
	for testname in "$@"; do
		if ! [ ${testname:0:5} = "test_" ]; then
    		echo "Invalid test name: $testname"
    		exit 1  
    	fi
		before $testname
		eval $testname
		after $testname
	done
	delete
	echo "Done."
}

case "$1" in
	wait_ready)
		wait_ready "${@:2}"
		;;
	create)
		create
		;;
	start)
		start
		;;
	stop)
		stop
		;;
	delete)
		delete
		;;
	exec_sql)
		exec_sql "${@:2}"
		;;
	test_*)
		run_tests ${@}
		;;
	"")
		run_tests ${all_tests}
		;;
	*)
		echo "Usage: $0 <tests...>"
		echo
		echo "Tests:"
		printf '\t%s\n' ${all_tests}
		;;
esac

exit 0
