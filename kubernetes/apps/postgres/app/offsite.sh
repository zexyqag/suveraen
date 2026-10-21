# Copies the running generation of the tenant's PostgreSQL from its bucket in the cluster's object store to both
# providers through rclone's crypt, which encrypts contents and names with the tenant's own password and salt (push),
# or brings generation $ORIGIN back from the provider $RESTORE_FROM names (fetch). A push never deletes: an object
# store that is lost or wiped must not empty the copies, which the providers expire instead. Nor does it send a
# generation the cluster no longer runs, such as one fetched back, which the providers already hold.
set -eu
export RCLONE_CONFIG_RGW_TYPE=s3 RCLONE_CONFIG_RGW_PROVIDER=Ceph RCLONE_CONFIG_RGW_ENDPOINT="http://$BUCKET_HOST:$BUCKET_PORT"
export RCLONE_CONFIG_RGW_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_CONFIG_RGW_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_CRYPT_TYPE=crypt
RCLONE_CONFIG_CRYPT_PASSWORD=$(printf %s "$CRYPT_PASSWORD" | rclone obscure -)
RCLONE_CONFIG_CRYPT_PASSWORD2=$(printf %s "$CRYPT_SALT" | rclone obscure -)
export RCLONE_CONFIG_CRYPT_PASSWORD RCLONE_CONFIG_CRYPT_PASSWORD2
# A locked bucket takes an upload only with its checksum, which rclone sends when it sets the lock itself, from parts
# small enough to buffer.
export RCLONE_CONFIG_OFFSITE_TYPE=s3 RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET=true RCLONE_CONFIG_OFFSITE_UPLOAD_CUTOFF=8M
export RCLONE_CONFIG_OFFSITE_CHUNK_SIZE=8M RCLONE_CONFIG_OFFSITE_OBJECT_LOCK_MODE=COMPLIANCE
export RCLONE_CONFIG_OFFSITE_OBJECT_LOCK_RETAIN_UNTIL_DATE="$LOCK"
provider() {
  eval "export RCLONE_CONFIG_OFFSITE_ENDPOINT=\"\$ENDPOINT_$1\" RCLONE_CONFIG_OFFSITE_REGION=\"\$REGION_$1\""
  eval "export RCLONE_CONFIG_OFFSITE_PROVIDER=\"\$PROVIDER_$1\" RCLONE_CONFIG_CRYPT_REMOTE=\"offsite:\$BUCKET_$1/postgres/\""
  eval "export RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID=\"\$ACCESS_KEY_ID_$1\""
  eval "export RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY=\"\$SECRET_ACCESS_KEY_$1\""
}
flags="--fast-list --transfers 2 -v"
case $1 in
  # Upload times stand in for modification times, and a copy newer than its source is up to date. One provider
  # failing doesn't keep the other from its copy.
  push)
    failed=0
    for n in 1 2; do
      (provider $n && exec rclone copy "rgw:$BUCKET_NAME/postgres-$GENERATION" "crypt:postgres-$GENERATION" --update \
        --use-server-modtime $flags) || failed=1
    done
    exit $failed
    ;;
  fetch)
    case $RESTORE_FROM in
      none)
        echo "nothing to fetch: generation $GENERATION starts anew or from the cluster's bucket"
        exit 0
        ;;
      offsite-1 | offsite-2) provider "${RESTORE_FROM#offsite-}" ;;
      *) exit 64 ;;
    esac
    exec rclone copy "crypt:postgres-$ORIGIN" "rgw:$BUCKET_NAME/postgres-$ORIGIN" $flags
    ;;
esac
exit 64
