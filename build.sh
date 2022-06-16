set -e
set -x

debug() {
    true
    echo $* 1>&2
}

cd $(dirname "$0")

LOCK_FILE="/tmp/cloud-init-image-builder.lock"
TEMP_DIR=$(mktemp -d)
TODAYS_DATE=$(date +"%Y%m%d")
TARGET_PATH="/srv/data/deploy/www/cloud-init-images/debian/bullseye/amd64/${TODAYS_DATE}"

cleanup() {
    # TODO cmm - clean up based on build phase so artifacts are left when errors happen
    debug "Cleaning up..."
    rm -rf $TEMP_DIR 2> /dev/null
    #exit -1

    if [[ "$DOCKER_BUILD_FAILED" == "0" ]]; then
        docker image rm cloud-init-image-debian-bullseye:latest 2> /dev/null || true
        # if any...
    else
        debug "Docker build failed.  Leaving images in place."
    fi
    # if any...
    kill $(jobs -p) 2> /dev/null || true
    rm -f $LOCK_FILE
}

error() {
    logger -t $(basename $0) -s "$(date --rfc-3339=seconds) $1"
    exit 1
}

warn() {
    logger -t $(basename $0) -s "$(date --rfc-3339=seconds) $1"
}

if [[ -f $LOCK_FILE ]]; then
    error "Found ${LOCK_FILE}, exiting..."
else
    trap cleanup EXIT
    trap cleanup INT
    touch $LOCK_FILE
fi

debug "Starting docker build..."
DOCKER_BUILD_FAILED=0
if ! docker build -t cloud-init-image-debian-bullseye:latest . ; then
  DOCKER_BUILD_FAILED=1
  error "Docker build failed..."
fi

debug "Starting docker container to extract files..."
DOCKER_CONTAINER_IMAGE=$(docker run -d --rm --name debian-bullsye-container cloud-init-image-debian-bullseye /bin/bash -c 'sleep infinity')

debug "Starting to extract files from container..."
docker export ${DOCKER_CONTAINER_IMAGE} | tar -xf - -C $TEMP_DIR rootfs.xz squashfs.manifest boot/

debug "Killing docker container..."
docker kill ${DOCKER_CONTAINER_IMAGE}

debug "Placing cloud-init-images so they can be served..."
mkdir -vp $TARGET_PATH > /dev/null
cp $TEMP_DIR/rootfs.xz ${TARGET_PATH}/root.squashfs
cp $TEMP_DIR/squashfs.manifest ${TARGET_PATH}/root.squashfs.manifest
cp $TEMP_DIR/boot/vmlinuz* ${TARGET_PATH}/boot-kernel
cp $TEMP_DIR/boot/initrd.img* ${TARGET_PATH}/boot-initrd
chmod go+r ${TARGET_PATH}/boot-kernel
chmod go+r ${TARGET_PATH}/boot-initrd

debug "Linking cloud-init-images current..."
rm $(realpath ${TARGET_PATH}/../)/current || true
ln -s $(basename ${TARGET_PATH}) ${TARGET_PATH}/../current

debug "Removing cloud-init-images that are more than 60 days old"
find $(realpath ${TARGET_PATH}/../) -maxdepth 1 ! -path $(realpath ${TARGET_PATH}/../) -mtime +60 -type d -exec rm -rf {} \;
debug "Success!"

