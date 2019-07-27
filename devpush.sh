#!/usr/bin/env bash

set -o errexit
# set -x

FORCE=no
RESINOS_REGISTRY="registry.hub.docker.com"

# input: device type and os verison docker hub repository
function usage()
{
    echo "usage: devpush.sh -d devicetype -v version -r repository -s imagefolder [--force]"
}

function urlencode() {
    # urlencode <string>
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C
    
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "%s" "$c"  ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
    
    LC_COLLATE=$old_lc_collate
}

function image_exists() {
    # Try to fetch the manifest of a repo:tag combo, to check for the existence of that
    # repo and tag.
    # Currently only works with v2 registries
    # The return value is "no" if can't access that manifest, and "yes" if we can find it
    local REGISTRY=$1
    local REPO=$2
    local TAG=$3
    local exists=no
    local REGISTRY_URL="https://${REGISTRY}/v2"
    local MANIFEST="${REGISTRY_URL}/${REPO}/manifests/${TAG}"
    local response

    # Check
    response=$(curl --retry 10 --write-out "%{http_code}" --silent --output /dev/null "${MANIFEST}")
    if [ "$response" = 401 ]; then
        # 401 is "Unauthorized", have to grab the access tokens from the provided endpoint
        local auth_header
        local realm
        local service
        local scope
        local token
        local response_auth
        auth_header=$(curl --retry 10 -I --silent "${MANIFEST}" |grep -i www-authenticate)
        # The auth_header looks as
        # Www-Authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:resin/resinos:pull"
        # shellcheck disable=SC2001
        realm=$(echo "$auth_header" | sed 's/.*realm="\([^,]*\)",.*/\1/' )
        # shellcheck disable=SC2001
        service=$(echo "$auth_header" | sed 's/.*,service="\([^,]*\)",.*/\1/' )
        # shellcheck disable=SC2001
        scope=$(echo "$auth_header" | sed 's/.*,scope="\([^,]*\)".*/\1/' )
        # Grab the token from the appropriate address, and retry the manifest query with that
        token=$(curl --retry 10 --silent "${realm}?service=${service}&scope=${scope}" | jq -r '.access_token // .token')
        response_auth=$(curl --retry 10 --write-out "%{http_code}" --silent --output /dev/null -H "Authorization: Bearer ${token}" "${MANIFEST}")
        if [ "$response_auth" = 200 ]; then
            exists=yes
        fi
    elif [ "$response" = 200 ]; then
        exists=yes
    fi
    echo "${exists}"
}

while [ "$1" != "" ]; do
    case $1 in
        '-d' | '--device-type' )
            shift
            deviceType=$1
            ;;
        '-v' | '--version' )
            shift
            version=$1
            ;;
        '-r' | '--repository' )
            shift
            repository=$1
            ;;
        '-s' | '--storage' )
            shift
            storage=$1
            ;;
        '-f' | '--force' )
            FORCE=yes
            ;;
        * )
            usage
            exit 1
    esac
    shift
done

missingparams="no"
if [ -z "${deviceType}" ] ; then
    echo "Please set the target device type with '-d' or '--device-type', such as raspberrypi3"
    missingparams="yes"
fi
if [ -z "${version}" ] ; then
    echo "Please set the OS version with '-v' or '--version', such as 2.38.0+rev1"
    missingparams="yes"
fi
if [ -z "${repository}" ] ; then
    echo "Please set the repository with '-r' or '--repository', such as 'resin/resinos'"
    missingparams="yes"
fi
if [ -z "${storage}" ] ; then
    echo "Please set S3 domain with '-s' or '--storage', such as https://resin-production-img-cloudformation.s3.amazonaws.com/images/"
    missingparams="yes"
fi
if [ "${missingparams}" != "no" ] ; then
    exit 1
fi

imageTag="$(echo "$version" | tr + _)-${deviceType}"
imageName="${repository}:${imageTag}"
echo "Image name: ${imageName}"

# delete image if it exists locally
docker rmi -f "${imageName}" || true


# check if image is already up there
if [ "$(image_exists "$RESINOS_REGISTRY" "$repository" "$imageTag")" = "yes" ]; then
    if [ "$FORCE" = "yes" ] ; then
        echo "WARN: image already exists in ${repository}, but we are going to overwrite it."
        docker rmi -f "${imageName}"
    else
        echo "Finished: image already exists in ${repository}, nothing to do."
        exit
    fi
else
    echo "Image ${imageName} does not exists yet, good "
fi

# download file from S3
echo "Getting file from s3"
imageFile=$(mktemp -u "balenaos-image.${deviceType-generic}.${version-noversion}.XXXXXX.docker")

url_base="${storage}${deviceType}/$(urlencode "${version}")"
url="${url_base}/resin-image.docker" 
result=$(curl --silent -L "${url}" --write-out '%{http_code}' -o "${imageFile}")
if [ "$result" != "200" ]; then
    echo "Couldn't download image: http code ${result}"
    # Cleanup
    rm "${imageFile}" || true
    exit 2
fi

result=$(docker load -q -i "${imageFile}") || { echo "Couldn't load file into docker, giving up."; exit 3; }
rm "${imageFile}"

# shellcheck disable=SC2001
loaded_image=$(echo "$result" | sed 's/^Loaded image.* //')
# push to docker hub
docker tag "${loaded_image}" "${imageName}"
docker push "${imageName}"
# cleanup
docker rmi -f "${loaded_image}" "${imageName}" || true
echo "DONE: ${imageName}"
echo "DONE: ${imageName}" >> devpush.log
