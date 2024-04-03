#!/bin/bash
DIR=/tmp/carbon-collection

# Ensure appropriate running conditions
REQUIRES="curl lsblk dmidecode"
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
