# Aurora lab helpers. Installed at boot as /etc/profile.d/dblab.sh (loaded by `bash -l`).
# Each use_* command exports PGHOST/PGUSER/PGPASSWORD/PGDATABASE/PGSSLMODE, so plain
# `psql` connects. Credentials are read from the RDS-managed secret on every call.
if [ -f /opt/dblab/dblab.env ]; then
  . /opt/dblab/dblab.env

  _dblab_creds() {
    _s=$(aws secretsmanager get-secret-value --region "$DBLAB_REGION" --secret-id "$SECRET_ARN" \
      --query SecretString --output text) || return 1
    PGUSER=$(printf '%s' "$_s" | jq -r .username)
    PGPASSWORD=$(printf '%s' "$_s" | jq -r .password)
    export PGUSER PGPASSWORD
    unset _s
  }

  _dblab_use() {
    _dblab_creds || return 1
    export PGHOST="$1" PGPORT=5432 PGDATABASE="$DB_NAME" PGSSLMODE=require
    echo "psql now points at the $2 ($1)"
  }

  use_writer()   { _dblab_use "$WRITER_ENDPOINT" "Aurora cluster writer endpoint"; }
  use_reader()   { _dblab_use "$READER_ENDPOINT" "Aurora cluster reader endpoint"; }
  use_proxy()    { _dblab_use "$PROXY_ENDPOINT" "RDS Proxy read/write endpoint"; }
  use_proxy_ro() { _dblab_use "$PROXY_RO_ENDPOINT" "RDS Proxy read-only endpoint"; }

  labsync() {
    sudo aws s3 sync --region "$DBLAB_REGION" --quiet "s3://$DBLAB_BUCKET" /opt/dblab &&
      sudo chmod +x /opt/dblab/scripts/*.sh &&
      sudo cp /opt/dblab/scripts/dblab_profile.sh /etc/profile.d/dblab.sh &&
      . /etc/profile.d/dblab.sh &&
      echo "synced s3://$DBLAB_BUCKET -> /opt/dblab"
  }
fi
