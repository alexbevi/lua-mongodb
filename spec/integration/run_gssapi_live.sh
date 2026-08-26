#!/usr/bin/env bash

set -euo pipefail

gssapi_mongod=${MONGODB_GSSAPI_MONGOD:?MONGODB_GSSAPI_MONGOD must name MongoDB Enterprise mongod}
gssapi_package_tree=${MONGODB_GSSAPI_PACKAGE_TREE:?MONGODB_GSSAPI_PACKAGE_TREE must name the installed rock tree}
gssapi_temp_dir=$(mktemp -d /tmp/lua-mongodb-gssapi.XXXXXXXX)
gssapi_realm=LUA-MONGODB.TEST
gssapi_host=gssapi.test
gssapi_canonical_endpoint=gssapi-alias.test
gssapi_port=27018
gssapi_kdc_port=10088
gssapi_user=driver_$(openssl rand -hex 8)
gssapi_principal=${gssapi_user}@${gssapi_realm}
gssapi_user_password=$(openssl rand -hex 24)
gssapi_master_password=$(openssl rand -hex 24)
gssapi_krb5_conf=${gssapi_temp_dir}/krb5.conf
gssapi_kdc_conf=${gssapi_temp_dir}/kdc.conf
gssapi_keytab=${gssapi_temp_dir}/mongod.keytab
gssapi_cache=${gssapi_temp_dir}/client.ccache
gssapi_mongod_pid=
gssapi_kdc_pid=

cleanup() {
  if test -n "$gssapi_mongod_pid" && kill -0 "$gssapi_mongod_pid" 2>/dev/null; then
    kill "$gssapi_mongod_pid"
    wait "$gssapi_mongod_pid" || true
  fi

  if test -n "$gssapi_kdc_pid" && kill -0 "$gssapi_kdc_pid" 2>/dev/null; then
    kill "$gssapi_kdc_pid"
    wait "$gssapi_kdc_pid" || true
  fi

  case "$gssapi_temp_dir" in
    /tmp/lua-mongodb-gssapi.*)
      rm -rf -- "$gssapi_temp_dir"
      ;;
  esac
}

trap cleanup EXIT
trap 'echo "GSSAPI live setup failed at line $LINENO" >&2' ERR

if test -n "${GITHUB_ACTIONS:-}"; then
  printf '::add-mask::%s\n' "$gssapi_principal"
  printf '::add-mask::%s\n' "$gssapi_user_password"
  printf '::add-mask::%s\n' "$gssapi_master_password"
fi

mkdir -p "$gssapi_temp_dir/database" "$gssapi_temp_dir/mongodb-data"

cat > "$gssapi_krb5_conf" <<EOF
[libdefaults]
  default_realm = $gssapi_realm
  dns_lookup_kdc = false
  dns_lookup_realm = false
  rdns = false

[realms]
  $gssapi_realm = {
    kdc = 127.0.0.1:$gssapi_kdc_port
  }

[domain_realm]
  .$gssapi_host = $gssapi_realm
  $gssapi_host = $gssapi_realm
EOF

cat > "$gssapi_kdc_conf" <<EOF
[kdcdefaults]
  kdc_ports = $gssapi_kdc_port
  kdc_tcp_ports = $gssapi_kdc_port

[realms]
  $gssapi_realm = {
    acl_file = $gssapi_temp_dir/kadm5.acl
    admin_keytab = $gssapi_temp_dir/kadm5.keytab
    database_name = $gssapi_temp_dir/database/principal
    key_stash_file = $gssapi_temp_dir/database/stash
    max_life = 10h 0m 0s
    max_renewable_life = 7d 0h 0m 0s
  }
EOF

printf '*/*@%s *\n' "$gssapi_realm" > "$gssapi_temp_dir/kadm5.acl"

export KRB5_CONFIG=$gssapi_krb5_conf
export KRB5_KDC_PROFILE=$gssapi_kdc_conf
export KRB5CCNAME=FILE:$gssapi_cache

echo "Creating the ephemeral Kerberos realm"
kdb5_util create -s -r "$gssapi_realm" -P "$gssapi_master_password" \
  > "$gssapi_temp_dir/kdb5.log" 2>&1
kadmin.local -r "$gssapi_realm" \
  -q "addprinc -pw $gssapi_user_password $gssapi_principal" \
  > "$gssapi_temp_dir/kadmin-user.log" 2>&1
kadmin.local -r "$gssapi_realm" \
  -q "addprinc -randkey mongodb/$gssapi_host@$gssapi_realm" \
  > "$gssapi_temp_dir/kadmin-service.log" 2>&1
kadmin.local -r "$gssapi_realm" \
  -q "ktadd -k $gssapi_keytab mongodb/$gssapi_host@$gssapi_realm" \
  > "$gssapi_temp_dir/kadmin-keytab.log" 2>&1
chmod 600 "$gssapi_keytab"

krb5kdc -n -r "$gssapi_realm" > "$gssapi_temp_dir/kdc.log" 2>&1 &
gssapi_kdc_pid=$!

echo "Acquiring an ephemeral client ticket"
for _ in $(seq 1 20); do
  if printf '%s\n' "$gssapi_user_password" \
      | kinit "$gssapi_principal" > "$gssapi_temp_dir/kinit.log" 2>&1
  then
    break
  fi

  if ! kill -0 "$gssapi_kdc_pid" 2>/dev/null; then
    echo "The ephemeral Kerberos KDC stopped before issuing a ticket" >&2
    exit 1
  fi

  sleep 0.25
done

if ! klist -s; then
  echo "The ephemeral Kerberos KDC did not issue a client ticket" >&2
  exit 1
fi

echo "Starting MongoDB Enterprise with GSSAPI authentication"
env KRB5_CONFIG="$gssapi_krb5_conf" KRB5_KTNAME="$gssapi_keytab" \
  "$gssapi_mongod" \
  --auth \
  --bind_ip 127.0.0.1,127.0.0.2 \
  --dbpath "$gssapi_temp_dir/mongodb-data" \
  --logpath "$gssapi_temp_dir/mongod.log" \
  --port "$gssapi_port" \
  --setParameter authenticationMechanisms=GSSAPI \
  --setParameter saslHostName="$gssapi_host" \
  > "$gssapi_temp_dir/mongod-console.log" 2>&1 &
gssapi_mongod_pid=$!

for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/$gssapi_port) 2>/dev/null; then
    exec 3>&-
    exec 3<&-
    break
  fi

  if ! kill -0 "$gssapi_mongod_pid" 2>/dev/null; then
    echo "MongoDB Enterprise stopped before accepting connections" >&2
    exit 1
  fi

  sleep 0.5
done

if ! (exec 3<>/dev/tcp/127.0.0.1/$gssapi_port) 2>/dev/null; then
  echo "MongoDB Enterprise did not accept connections" >&2
  exit 1
fi
exec 3>&-
exec 3<&-

export MONGODB_GSSAPI_LIVE=1
export MONGODB_GSSAPI_BOOTSTRAP_URI=mongodb://127.0.0.1:$gssapi_port
export MONGODB_GSSAPI_CANONICAL_ENDPOINT=$gssapi_canonical_endpoint
export MONGODB_GSSAPI_HOST=$gssapi_host
export MONGODB_GSSAPI_PASSWORD=$gssapi_user_password
export MONGODB_GSSAPI_PORT=$gssapi_port
export MONGODB_GSSAPI_PRINCIPAL=$gssapi_principal
export MONGODB_GSSAPI_PACKAGE_TREE=$gssapi_package_tree
export MONGODB_GSSAPI_SERVICE_ENDPOINT=$gssapi_canonical_endpoint

echo "Running the installed-rock GSSAPI integration test"
make test-focus \
  FOCUS_INTEGRATION=spec/integration/auth_gssapi_live_spec.lua \
  FOCUS_LINT=spec/integration/auth_gssapi_live_spec.lua
