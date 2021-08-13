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
TARGET_PATH="/srv/deploy/www/cloud-init-images/focal/amd64/${TODAYS_DATE}"

cleanup() {
    # TODO cmm - clean up based on build phase so artifacts are left when errors happen
    debug "Cleaning up..."
    #exit -1
    rm -rf $TEMP_DIR 2> /dev/null
    rm focal-server-cloudimg-amd64-root.tar.xz 2> /dev/null || true
    rm focal-server-cloudimg-amd64-root.tar 2> /dev/null || true
    rm SHA256SUMS 2> /dev/null || true
    rm SHA256SUMS.gpg 2> /dev/null || true
    if [[ "$DOCKER_BUILD_FAILED" == "0" ]]; then
        docker image rm cloud-init-image-focal:latest 2> /dev/null || true
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

debug "Downloading cloud init root filesystem..."
curl -s --output focal-server-cloudimg-amd64-root.tar.xz http://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-root.tar.xz

debug "Downloading cloud init hash..."
curl -s --output SHA256SUMS http://cloud-images.ubuntu.com/focal/current/SHA256SUMS

debug "Downloading cloud init hash detached signature..."
curl -s --output SHA256SUMS.gpg http://cloud-images.ubuntu.com/focal/current/SHA256SUMS.gpg

debug "Verifying GPG signature of hash"
#gpg --no-default-keyring --keyring ./cdimage-at-ubuntu.com.gpg --keyserver keyserver.ubuntu.com --recv-keys 1A5D6C4C7DB87C81
gpgv -q --keyring ./cdimage-at-ubuntu.com.gpg SHA256SUMS.gpg SHA256SUMS
if [[ $? -ne 0 ]]; then
  error "GPG did not verify signature correctly"
fi

debug "Checking hash against cloud init base image"
shasum -a 256 -c <(grep focal-server-cloudimg-amd64-root.tar.xz SHA256SUMS) > /dev/null
if [[ $? -ne 0 ]]; then
  error "shasum did not check against image correctly"
fi

# Work around docker bug where xz keeps running after build finishes
debug "Uncompressing root filesystem to a bare tarball"
xz --decompress --stdout focal-server-cloudimg-amd64-root.tar.xz > focal-server-cloudimg-amd64-root.tar
rm focal-server-cloudimg-amd64-root.tar.xz

debug "Starting docker build..."
DOCKER_BUILD_FAILED=0
if ! docker build -t cloud-init-image-focal:latest . > /dev/null; then 
  DOCKER_BUILD_FAILED=1
  error "Docker build failed..."
fi

debug "Starting docker container to extract files..."
DOCKER_CONTAINER_IMAGE=$(docker run -d --rm --name focal-container cloud-init-image-focal /bin/bash -c 'sleep infinity')

debug "Starting to extract files from container..."
docker export ${DOCKER_CONTAINER_IMAGE} | tar -xf - -C $TEMP_DIR rootfs.xz squashfs.manifest boot/

debug "Killing docker container..."
docker kill ${DOCKER_CONTAINER_IMAGE}

debug "Placing cloud-init-images so they can be served..."
mkdir -vp $TARGET_PATH > /dev/null
cp $TEMP_DIR/rootfs.xz ${TARGET_PATH}/squashfs
cp $TEMP_DIR/squashfs.manifest ${TARGET_PATH}/squashfs.manifest
cp $TEMP_DIR/boot/vmlinuz ${TARGET_PATH}/boot-kernel
cp $TEMP_DIR/boot/initrd.img ${TARGET_PATH}/boot-initrd
chmod go+r ${TARGET_PATH}/boot-kernel
chmod go+r ${TARGET_PATH}/boot-initrd

debug "Linking cloud-init-images current..."
rm $(realpath ${TARGET_PATH}/../)/current || true
ln -s $(basename ${TARGET_PATH}) ${TARGET_PATH}/../current

debug "Removing cloud-init-images that are more than 60 days old"
find $(realpath ${TARGET_PATH}/../) -maxdepth 1 ! -path $(realpath ${TARGET_PATH}/../) -mtime +60 -type d -exec rm -rf {} \;
debug "Success!"

