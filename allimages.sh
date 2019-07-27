#!/usr/bin/env bash

set -o errexit

MINVERSION=2.5.1
PARALLEL=5

## Production-kind setup
# IMG=https://img.balena-cloud.com
# REPO="imrehg/fleettest-os"
# S3LINK="https://resin-production-img-cloudformation.s3.amazonaws.com/images/"

## Staging-kind setup
IMG=https://img.balena-staging.com
REPO="imrehg/fleettest-os-staging"
S3LINK="https://resin-staging-img.s3.amazonaws.com/images/"

function version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

taskList=()
taskCount=0
deviceTypes=$(curl --retry 10 --silent -L "${IMG}/api/v1/device-types" |  jq -r '.[].slug')
for type in ${deviceTypes[*]}; do
   echo "Device type: ${type}"
   versions=$(curl --retry 10 --silent -L "${IMG}/api/v1/image/${type}/versions" | jq -r '.versions[]' | sort -V )
   for version  in ${versions[*]}; do
     case $version in
        *.dev)
            if version_gt "${version}" "${MINVERSION}" ; then
                echo "${version}: candidate"
                taskCount=$((taskCount+1))
                taskList+=("${taskCount}:${type}:${version}")
            else
                continue
            fi
            ;;
        *)
            continue
     esac
   done
done

echo "Starting uploads: ${taskCount} to process"
# shellcheck disable=SC2016
printf "%s\n" "${taskList[@]}"   | \
  awk -F ":" '{print $2 " " $3}' | \
  stdbuf -oL xargs -L 1 -P ${PARALLEL} bash -c './devpush.sh -d "$0" -v "$1" -r "'"${REPO}"'" -s "'"${S3LINK}"'" 2>&1 | sed "s/^/$0-$1 : /"'
