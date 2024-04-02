#!/bin/bash
DIR=/tmp/carbon-collection

# Ensure appropriate running conditions
REQUIRES="curl lsblk dmidecode patch"
for req in $REQUIRES ; do 
    if ! command -v $req >/dev/null 2>&1 ; then
        echo "Command '$req' not found, exiting..."
        exit 1
    fi
done

# Prepare path and directories
mkdir $DIR
export PATH="$PATH:$DIR"

# Download things
curl -sL https://raw.githubusercontent.com/openflighthpc/carbon-reporting/dev/carbon-report/opt/flight/libexec/commands/carbon > $DIR/carbon
curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 > $DIR/jq
## SF build of bc because nowhere offering precompiled binary like jq
curl -sL https://repo.openflighthpc.org/test/bc > $DIR/bc

chmod +x $DIR/{bc,carbon,jq}

# Patch carbon
## Use IMDSv2 for AWS (requires a token) 
## Use lsblk to generate a list of disks excluding loop devices and ram devices
cat << 'EOF' > $DIR/carbon.patch
--- carbon	2024-04-02 09:01:13.425795203 +0000
+++ carbon.stufix	2024-04-02 09:01:31.949990922 +0000
@@ -85,7 +85,16 @@
 esac

 ## Determine cloud instance and provider
-INSTANCE_TYPE=$(curl -s --fail http://169.254.169.254/latest/meta-data/instance-type)
+case "$PLATFORM" in
+    "AWS")
+        TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
+        CLOUDCURL=(curl -H "X-aws-ec2-metadata-token: $TOKEN")
+    ;;
+    "OpenStack")
+        CLOUDCURL=(curl)
+    ;;
+esac
+INSTANCE_TYPE=$("${CLOUDCURL[@]}" -s --fail http://169.254.169.254/latest/meta-data/instance-type)
 ARCHETYPES=$(curl -s -X 'GET' \
   "${BOAVIZTA_URL}/v1/cloud/instance/all_instances?provider=${CLOUD_PROVIDER}" \
   -H 'accept: application/json')
@@ -104,7 +113,7 @@
 GBPERDIMM=$($GATHER_COMMAND show .ram.capacity_per_unit)

 # Disks
-disks=$(ls /sys/block)
+disks=$(lsblk -e7 -l -d -o NAME -n)
 for disk in $disks ; do
 	size=$($GATHER_COMMAND show .disks.[$disk].size)
 	disktype=$($GATHER_COMMAND show .disks.[$disk].type)
@@ -114,7 +123,7 @@

 case $PLATFORM in
     "AWS")
-        country=$(curl -s -L https://github.com/PaulieScanlon/cloud-regions-country-flags/raw/main/from-provider.js |grep "'$(curl -s --fail http://169.254.169.254/latest/meta-data/placement/region)':" -A 5 |grep country |sed "s/.* = '//g;s/'.*//g")
+        country=$(curl -s -L https://github.com/PaulieScanlon/cloud-regions-country-flags/raw/main/from-provider.js |grep "'$("${CLOUDCURL[@]}" -s --fail http://169.254.169.254/latest/meta-data/placement/region)':" -A 5 |grep country |sed "s/.* = '//g;s/'.*//g")
         if [[ "$country" == "England" ]] ; then
             country="United Kingdom"
         elif [[ "$country" == "South Korea" ]] ; then
EOF

patch -u -i $DIR/carbon.patch $DIR/carbon

# Create fake gather
cat << 'EOF' > $DIR/gather
#!/bin/bash

SUB="$1"
VAL="$2"

# Check first arg
if [[ "$SUB" != "show" ]] ; then
    echo "Unknown subcommand, should be 'show'"
    exit 1
fi

# Get correct data wanted by call
case "$VAL" in
    ".platform")
        plat_query="$(dmidecode -t system |grep -E '^[[:blank:]]+Manufacturer' |awk '{print $2}')"
        case $plat_query in
            "OpenStack")
                PLATFORM="$plat_query"
            ;;
            "Amazon")
                PLATFORM="AWS"
            ;;
            "Microsoft")
                PLATFORM="Azure"
            ;;
            *)
                PLATFORM="Metal"
            ;;
        esac
        STAT="$PLATFORM"
    ;;
    ".cpus.units")
        STAT="$(dmidecode -q -t processor |grep '^Processor Information'  |wc -l)"
    ;;
    ".cpus.cores_per_cpu")
        STAT="$(dmidecode -q -t processor |grep 'Thread Count'  -m 1 |sed 's/.*: //g')"
    ;;
    '.cpus.cpu_data.[CPU0].model')
        STAT="$(grep -m 1 '^model name' /proc/cpuinfo |sed 's/.*: //g;s/ @.*//g')"
    ;;
    ".ram.units")
        STAT="$(dmidecode -q -t 17 |grep '^Memory Device' | wc -l)"
    ;;
    ".ram.capacity_per_unit")
        STAT="$(dmidecode -t memory |grep -m 1 -E '^[[:blank:]]+Size' |awk '{print $2}')"
    ;;
    ".disks."*".size")
        disk="$(echo "$VAL" |sed 's/.*disks\.\[//g;s/\]\.size.*//g')"
        STAT="$(($(lsblk -b --output SIZE -n -d /dev/$disk)/1024/1024/1024))"
    ;;
    ".disks."*".type")
        disk="$(echo "$VAL" |sed 's/.*disks\.\[//g;s/\]\.type.*//g')"
        rotate=$(cat /sys/block/$disk/queue/rotational)
        case $rotate in
            0)
                disktype="ssd"
                ;;
            1)
                disktype="hdd"
                ;;
        esac
        STAT="$disktype"
    ;;
    *)
        echo "Unknown val: $VAL"
        exit 1
    ;;
esac

echo "$STAT"
EOF

chmod +x $DIR/gather

# Tweak things
sed -i 's/^GATHER_COMMAND=.*/GATHER_COMMAND="gather"/g' $DIR/carbon
sed -i 's,^BOAVIZTA_URL=.*,BOAVIZTA_URL="http://api.boavizta.openflighthpc.org",g' $DIR/carbon

# Run report
carbon report

# Tidy things 
rm -rf $DIR
