#!/usr/bin/env bash
set -e
log() { echo $@ >&2; }
vv() { log "$@";"$@"; }
set -o pipefail
dup() { vv docker-compose up -d --no-deps $@; }
dupr() { vv dup --force-recreate $@; }
cd $(dirname $(readlink -f $0))
if [[ -z ${SKIP_STOP} ]];then
    vv docker-compose stop -t 0
    vv systemctl stop docker-mailman || true
fi
vv docker-compose stop -t 0 web mailman nginx || true
dup log
dup postfix setup-debian setup-services
dup db dbs
vv docker-compose exec -T \
    -e SKIP_DB_RESET=${SKIP_DB_RESET-} \
    -e SKIP_DB=${SKIP_DB-} \
    -e SKIP_FILES=${SKIP_FILES-} \
    db bash -i <<_EOF
set -e
log() { echo \$@ >&2; }
vv() { log "\$@";"\$@"; }
dbs="\$MM_DB_NAME \$WEB_DB_NAME"
export DEBIAN_FRONTEND=noninteractive
sql() { psql -v ON_ERROR_STOP=1 \${A_DB_URL}; }
if [[ -z \${SKIP_DB-} ]];then
for d in \$dbs;do
    vv dropdb   -U \$POSTGRES_USER \$d || true
    vv createdb -U \$POSTGRES_USER -O \$POSTGRES_USER \$d -T db
done
fi
pkgs=""
if ! (ssh -V >/dev/null 2>&1 );then pkgs="\$pkgs openssh-client";fi
if ! (rsync --version >/dev/null 2>&1 );then pkgs="\$pkgs rsync";fi
if [[ -n "\$pkgs" ]];then apt -yq update && apt install -yq \$pkgs;fi
if [[ -z \${SKIP_DB_RESET-} ]];then
#
echo "loading web"
ssh \${OLD_MM_HOST} "PGPASSWORD=\${OLD_HK_DB_PASSWORD} \
 pg_dump -wFc -U \${OLD_HK_DB_USER} -h \${OLD_DB_HOST} -p \${OLD_DB_PORT} -d \${OLD_HK_DB_NAME}" \
 | pg_restore --if-exists -U \${POSTGRES_USER} -cwOxd \${WEB_DB_NAME}
#
echo "loading mailman"
ssh \${OLD_MM_HOST} "PGPASSWORD=\${OLD_MM_DB_PASSWORD} \
 pg_dump -wFc -U \${OLD_MM_DB_USER} -h \${OLD_DB_HOST} -p \${OLD_DB_PORT} -d \${OLD_MM_DB_NAME}" \
 | pg_restore --if-exists -U \${POSTGRES_USER} -cwOxd \${MM_DB_NAME}
#
echo "dumps loaded"
fi
if [[ -z \${SKIP_FILES-} ]];then
rsync -aAHv \${OLD_MM_HOST}:/srv/projects/postorius/data/static/  /mailman-data/web/
rsync -aAHv \${OLD_MM_HOST}:/srv/projects/hyperkitty/data/static/ /mailman-data/web/ --exclude=CACHE/
rsync -aAHv \${OLD_MM_HOST}:/srv/projects/mailman3/data/var/      /mailman-data/mailman/var/
chown -Rf 100:65533 /mailman-data/mailman/var/
fi
_EOF
docker-compose run --rm --entrypoint bash mailman -exc "cd /opt/mailman && chmod -R g-s . && chown -Rf mailman . && cd var/data && chmod o+r * . .. ../.."
docker-compose run --rm --entrypoint bash web     -exc "chown -Rf mailman /opt/mailman/mailman-web-data"
dupr mailman web
dupr nginx
# vim:set et sts=4 ts=4 tw=0:
