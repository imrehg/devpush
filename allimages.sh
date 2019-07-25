#!/usr/bin/env bash

set -o errexit

MINVERSION=2.5.1

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

function run_upload() {
    local deviceType=$1
    local versionName=$2
   ./devpush.sh -d "$deviceType" -v "$versionName" -r "$REPO" -s "${S3LINK}" || echo "UPLOAD FAILED: ${deviceType}:${versionName}, continuing with next...."
}

deviceTypes=$(curl --retry 10 --silent -L "${IMG}/api/v1/device-types" |  jq -r '.[].slug')
deviceTypes="raspberrypi3"
for type in ${deviceTypes[@]}; do
   echo "Device type: ${type}"
   versions=$(curl --retry 10 --silent -L "${IMG}/api/v1/image/${type}/versions" | jq -r '.versions[]' | sort -V )
   for version  in ${versions[@]}; do
     case $version in
        *.dev)
            if version_gt "${version}" "${MINVERSION}" ; then
                echo "${version}: candidate"
                run_upload "${type}" "${version}"
            else
                continue
            fi
            ;;
        *)
            continue
     esac
   done
done