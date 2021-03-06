if [ -z "$ROOT" ]; then
    echo "ROOT must be set to the root of the end-to-end tests" >&2
    exit 1
fi

if [ -n "$MACHINE_READABLE" ]; then
    LINE_END="\n"
else
    LINE_END="\r"
fi

step () {
    echo "==== $@"
}

get_kubernaut () {
    if [ ! -x "$KUBERNAUT" ]; then
        echo "Fetching kubernaut..."
        # curl -s -L -o "$KUBERNAUT" https://s3.amazonaws.com/datawire-static-files/kubernaut/$(curl -s https://s3.amazonaws.com/datawire-static-files/kubernaut/stable.txt)/kubernaut
        curl -s -L -o "$KUBERNAUT" https://s3.amazonaws.com/datawire-static-files/kubernaut/0.1.39/kubernaut
        chmod +x "$KUBERNAUT"
    fi
}

check_kubernaut_token () {
    if [ $("$KUBERNAUT" kubeconfig | grep -c 'Token not found') -gt 0 ]; then
        echo "You need a Kubernaut token. Go to"
        echo ""
        echo "https://kubernaut.io/token"
        echo ""
        echo "to get one, then run"
        echo ""
        echo "sh $ROOT/save-token.sh \"\$token\""
        echo ""
        echo "to save it before trying again."

        exit 1
    fi
}

shred_and_reclaim () {
    KUBERNAUT="$ROOT/kubernaut"

    get_kubernaut
    check_kubernaut_token

    step "Dropping old cluster"
    "$KUBERNAUT" discard

    step "Claiming new cluster"
    "$KUBERNAUT" claim
    export KUBECONFIG=${HOME}/.kube/kubernaut
}

cluster_ip () {
    kubectl cluster-info | fgrep master | python -c 'import sys; print(sys.stdin.readlines()[0].split()[5].split(":")[1].lstrip("/"))'
}

service_port() {
    kubectl get services "$1" -ojsonpath={.spec.ports[0].nodePort}
}

wait_for_pods () {
    namespace=${1:-default}
    attempts=60
    running=

    while [ $attempts -gt 0 ]; do
        pending=$(kubectl --namespace $namespace get pod -o json | grep phase | grep -c -v Running)

        if [ $pending -eq 0 ]; then
            printf "Pods running.              \n"
            running=YES
            break
        fi

        printf "try %02d: %d not running${LINE_END}" $attempts $pending
        attempts=$(( $attempts - 1 ))
        sleep 2
    done

    if [ -z "$running" ]; then
        echo 'Some pods have yet to start?' >&2
        exit 1
    fi
}

wait_for_ready () {
    baseurl=${1}
    attempts=60
    ready=

    while [ $attempts -gt 0 ]; do
        OK=$(curl -k $baseurl/ambassador/v0/check_ready 2>&1 | grep -c 'readiness check OK')

        if [ $OK -gt 0 ]; then
            printf "ambassador ready           \n"
            ready=YES
            break
        fi

        printf "try %02d: not ready${LINE_END}" $attempts
        attempts=$(( $attempts - 1 ))
        sleep 2
    done

    if [ -z "$ready" ]; then
        echo 'Ambassador not yet ready?' >&2
        kubectl get pods >&2
        exit 1
    fi
}

wait_for_extauth_running () {
    baseurl=${1}
    attempts=60
    ready=

    while [ $attempts -gt 0 ]; do
        OK=$(curl -k -s $baseurl/example-auth/ready | egrep -c '^OK ')

        if [ $OK -gt 0 ]; then
            printf "extauth ready              \n"
            ready=YES
            break
        fi

        printf "try %02d: not ready${LINE_END}" $attempts
        attempts=$(( $attempts - 1 ))
        sleep 5
    done

    if [ -z "$ready" ]; then
        echo 'extauth not yet ready?' >&2
        exit 1
    fi
}

wait_for_extauth_enabled () {
    baseurl=${1}
    attempts=60
    enabled=

    while [ $attempts -gt 0 ]; do
        OK=$(curl -k -s $baseurl/ambassador/v0/diag/?json=true | jget.py /filters/0/name 2>&1 | egrep -c 'extauth')

        if [ $OK -gt 0 ]; then
            printf "extauth enabled            \n"
            enabled=YES
            break
        fi

        printf "try %02d: not enabled${LINE_END}" $attempts
        attempts=$(( $attempts - 1 ))
        sleep 5
    done

    if [ -z "$enabled" ]; then
        echo 'extauth not yet enabled?' >&2
        exit 1
    fi
}

wait_for_demo_weights () {
    attempts=60
    routed=

    while [ $attempts -gt 0 ]; do
        if checkweights.py "$@"; then
            routed=YES
            break
        fi

        printf "try %02d: misweighted${LINE_END}" $attempts
        attempts=$(( $attempts - 1 ))
        sleep 5
    done

    if [ -z "$routed" ]; then
        echo 'weights still not correct?' >&2
        exit 1
    fi
}

check_diag () {
    baseurl=$1
    index=$2
    desc=$3

    rc=1

    curl -k -s ${baseurl}/ambassador/v0/diag/?json=true | jget.py /routes > check-$index.json

    if ! cmp -s check-$index.json diag-$index.json; then
        echo "check_diag $index: mismatch for $desc"

        if diag-diff.sh $index; then
            diag-fix.sh $index
            rc=0
        fi
    else
        echo "check_diag $index: OK"
        rc=0
    fi

    return $rc
}

istio_running () {
    kubectl get service istio-mixer >/dev/null 2>&1
}

ambassador_pod () {
    kubectl get pod -l app=ambassador -o jsonpath='{.items[0].metadata.name}'
}

# ISTIOHOME=${ISTIOHOME:-${HERE}/istio-0.1.6}

# source ${ISTIOHOME}/istio.VERSION

# if [ \( "$1" = "--delete" \) -o \( "$1" = "-d" \) ]; then
#     ACTION="delete"
#     HRACTION="Tearing down"
#     shift
# else
#     ACTION="apply"
#     HRACTION="Setting up"
# fi

# KUBEDIR=${HERE}/kube
