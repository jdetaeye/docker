#!/bin/bash
# Usage:
#   $0 odoo
#   $0 odoo scaffold
#   $0 odoo --test-enable --workers=0 --stop-after-init -d testodoo -i base

set -e

# set the postgres database host, port, user and password according to the environment
# and pass them as arguments to the odoo process if not present in the config file
: ${HOST:=${DB_PORT_5432_TCP_ADDR:='db'}}
: ${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}
: ${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}
: ${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}
: ${DEFAULTDB:=${DB_ENV_POSTGRES_DEFAULTDB:=${POSTGRES_DEFAULTDB:='postgres'}}}
: ${MODE:=${MODE:='full'}}
: ${ODOO_ADMIN_PASSWD:='admin'}
: ${RUNNING_ENV:='dev'}
: ${AWS_HOST:='false'}
: ${AWS_REGION:='false'}
: ${AWS_ACCESS_KEY_ID:='false'}
: ${AWS_SECRET_ACCESS_KEY:='false'}
: ${AWS_BUCKETNAME:='false'}

DB_ARGS=()

function check_config() {
  param="$1"
  value="$2"
  if grep -q -E "^\s*\b${param}\b\s*=" "$ODOO_RC" ; then
      value=$(grep -E "^\s*\b${param}\b\s*=" "$ODOO_RC" | cut -d " " -f3 | sed 's/["\n\r]//g')
  fi;
  DB_ARGS+=("--${param}")
  DB_ARGS+=("${value}")
}

function config_s3() {
  command -v s3cmd > /dev/null 2>&1
  if [ "$AWS_HOST" != "false" ] && [ "$?" == "0" ]; then
    # If AWS_HOST is set and s3cmd is installed, configure it
    S3CMD_HOST=`echo $AWS_HOST | sed -e "s/^.*.$AWS_REGION/$AWS_REGION/"`
    sed -i -e 's/access_key =.*$/access_key = $AWS_ACCESS_KEY_ID/'  ~/.s3cfg
    sed -i -e 's/bucket_location =.*$/bucket_location = $AWS_REGION/'  ~/.s3cfg
    sed -i -e 's/host_base =.*$/host_base = $S3CMD_HOST/'  ~/.s3cfg
    sed -i -e 's/host_bucket =.*$/host_bucket = %(bucket)s.$S3CMD_HOST/'  ~/.s3cfg
    sed -i -e 's/secret_key =.*$/secret_key = $AWS_SECRET_ACCESS_KEY/'  ~/.s3cfg
    export DO_SPACE=`echo $AWS_HOST | sed -e "s/.$AWS_REGION.*$//"`
  fi
}

function migrate() {
  OLD=""
  DB_EXIST=$(psql -X -A -t -h $HOST -p $PORT -U $USER $DEFAULTDB -c "SELECT 1 AS result FROM pg_database WHERE datname = '$1'";)
  if [ "$DB_EXIST" = "1" ]; then
    export PGDATABASE=$1
    TABLE_EXIST=$(psql -X -A -t -h $HOST -p $PORT -U $USER -d $1 -c "
      SELECT EXISTS(
        SELECT *
        FROM information_schema.tables
        WHERE table_schema='public' AND
          table_catalog='$1' AND
          table_name='ir_config_parameter'
      )";)
    if [ "$TABLE_EXIST" = "1" ]; then
      OLD=$(psql -X -A -t -h $HOST -p $PORT -U $USER -v ON_ERROR_STOP=1 -d $1 -c "SELECT value FROM ir_config_parameter WHERE key = 'database.version'" 2> /dev/null ;)
    fi
  fi
  NEW=$(grep version= /odoo/setup.py | sed -e 's/^ *version="//' -e 's/",$//')
  if [ "$OLD" != "$NEW" ]; then
    echo "db_name = $1" >> $OPENERP_SERVER
    export MARABUNTA_DATABASE=$1
    [ "$OLD" != "" ] && export MARABUNTA_FORCE_VERSION=$NEW
    marabunta --allow-serie=True
    sed -i -e '/db_name.*$/d' $OPENERP_SERVER
  fi
}

function duplicate() {
  BACKUP=$(psql -X -A -t $DEFAULTDB -c "SELECT 1 AS result FROM pg_database WHERE datname = 'BACKUP';")
  if [ "$BACKUP" == "1" ]; then
    # If BACKUP database exists, copy it and upgrade it
    # TODO: Build DB_NAME with the tag of the image
    export DB_NAME=$(date -u +'%Y%m%d')
    TODAY=$(psql -X -A -t $DEFAULTDB -c "SELECT 1 AS result FROM pg_database WHERE datname = '$DB_NAME';")
    # Create one YYYYMMDD database per day
    if [ "$TODAY" != "1" ] ; then
      echo "Duplicating BACKUP to $DB_NAME"
      psql $DEFAULTDB -c "CREATE DATABASE \"$DB_NAME\" WITH TEMPLATE \"BACKUP\"";
      if [ "$AWS_HOST" == "false" ]; then
        cp -R /var/lib/odoo/filestore/BACKUP /var/lib/odoo/filestore/$DB_NAME
      else
        s3cmd cp --recursive s3://$DO_SPACE/$RUNNING_ENV-BACKUP/ s3://$DO_SPACE/$RUNNING_ENV-$DB_NAME/
      fi
    fi
    migrate $DB_NAME
  fi
}

function create() {
  EXIST=$(psql -X -A -t $DEFAULTDB -c "SELECT 1 AS result FROM pg_database WHERE datname = '$1'";)
  if [ "$EXIST" != "1" ]; then
    echo "Creating $1"
    createdb $1
  fi
}

function drop() {
  echo "Dropping $1"
  dropdb --if-exists $1
  if [ "$AWS_HOST" == "false" ]; then
    rm -Rf /var/lib/odoo/filestore/$1
  else
    s3cmd rm --force --recursive s3://$DO_SPACE/$RUNNING_ENV-$1/
  fi
}

function upgrade_existing () {
  echo "Upgrade existing databases"
  DATABASES=$(psql -X -A -t $DEFAULTDB -c "
    SELECT datname
    FROM pg_database
    WHERE datname not in ('MASTER', 'BACKUP', 'LATEST', 'postgres', '_dodb', 'defaultdb', 'template0', 'template1')";)
  for DB_NAME in $DATABASES; do
    echo "Upgrading $DB_NAME"
    migrate $DB_NAME
  done
}

check_config "db_host" "$HOST"
check_config "db_port" "$PORT"
check_config "db_user" "$USER"
check_config "db_password" "$PASSWORD"
config_s3

# shellcheck disable=SC2068
wait-for-psql.py ${DB_ARGS[@]} --timeout=30 --db_name=${DEFAULTDB}

# For psql, createdb and dropdb
export PGHOST=$HOST
export PGPORT=$PORT
export PGUSER=$USER
export PGPASSWORD=$PASSWORD
# For Marabunta
export MARABUNTA_MIGRATION_FILE=/odoo/migration.yml
export MARABUNTA_DB_USER=$USER
export MARABUNTA_DB_PASSWORD=$PASSWORD
export MARABUNTA_DB_PORT=$PORT
export MARABUNTA_DB_HOST=$HOST
export MARABUNTA_MODE=$MODE
# For anthem
export OPENERP_SERVER=/etc/odoo/odoo.conf
export ODOO_DATA_PATH=/odoo/data

# Set database configuration in odoo.conf
grep db_host $OPENERP_SERVER > /dev/null || echo "db_host = $HOST" >> $OPENERP_SERVER
grep db_port $OPENERP_SERVER > /dev/null || echo "db_port = $PORT" >> $OPENERP_SERVER
grep db_user $OPENERP_SERVER > /dev/null || echo "db_user = $USER" >> $OPENERP_SERVER
grep db_password $OPENERP_SERVER > /dev/null || echo "db_password = $PASSWORD" >> $OPENERP_SERVER
sed -i -e "s/admin_passwd.*$/admin_passwd = $ODOO_ADMIN_PASSWD/" $OPENERP_SERVER
sed -i -e '/db_name.*$/d' $OPENERP_SERVER

cd /odoo

# Check if the 2nd command line argument is --test-enable
if [ "$1" == "--test-enable" ] ; then
  # Change configuration of demo data
  sed -i -e 's/without_demo = all/without_demo = False/g' $OPENERP_SERVER
  # Run odoo with all command line arguments
  # shellcheck disable=SC2145
  echo "Running Odoo with the following commands: odoo $@"
  exec odoo "$@"
  exit 0
else
  case "$RUNNING_ENV" in
    "production")
      create MASTER
      migrate MASTER
      ;;
    "qa")
      upgrade_existing
      duplicate
      ;;
    "test")
      upgrade_existing
      duplicate
      ;;
    *) # dev
      drop LATEST
      create LATEST
      migrate LATEST
      ;;
  esac
  
  # Start Odoo
  case "$1" in
      -- | odoo)
          shift
          if [[ "$1" == "scaffold" ]] ; then
              exec odoo "$@"
          else
              exec odoo "$@" "${DB_ARGS[@]}"
          fi
          ;;
      -*)
          exec odoo "$@" "${DB_ARGS[@]}"
          ;;
      *)
          exec "$@"
  esac
fi

exit 1
