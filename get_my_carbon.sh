#!/bin/bash
#
# Estimate the average carbon impact of this system based off of it's specifications
#

# Exit if no jq
if ! which jq >/dev/null 2>&1 ; then
    echo "Can't find command 'jq', this is required for program to function"
    exit 1
fi

#
# Determine Resources
#
# Info Required: 
# - Number of CPUs Y
# - Cores per CPU Y
# - CPU Architecture - No need, using model name
# - CPU TDP - No need, using model name
# - Number of Memory Modules Y
# - RAM (GB) per Module Y
# - Number of SSDs Y
# - Capacity per SSD Y
# - Number of HDDs Y 
# - Capacity per HDDs Y
# - Number of PSUs
# - Number of GPUs?

## Use flight-gather info if present
if rpm -qa |grep flight-gather -q ; then
    PLATFORM=$(/opt/flight/bin/flight gather show --force |grep '^:platform:' |awk '{print $2}')
    GATHER=true
else
    plat_query=$(dmidecode -t system |grep -E '^[[:blank:]]+Manufacturer' |awk '{print $2}')
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
            PLATFORM="Unknown"
            ;;
    esac
fi

## Determine if AWS or Alces Cloud instance (makes life much easier if it is) 
if [[ $PLATFORM == "AWS"  ]] || [[ $PLATFORM == "Alces Cloud" ]] ; then
    INSTANCE_TYPE=$(curl -s --fail http://169.254.169.254/latest/meta-data/instance-type)
    USE_INSTANCE_TYPE=true
fi

## Figure system info out
if [ ! -z $GATHER ] ; then
    # Grab some data from gather 
    NUMCPUS=$(flight gather show |grep -E '^[[:blank:]]+CPU' |wc -l)
    NUMCORESPERCPU=$(flight gather show |grep -m 1 -E '^[[:blank:]]+:cores:' |awk '{print $2}')
else
    # Work it out
    NUMCPUS=$(grep "physical id"  /proc/cpuinfo | sort -u | wc -l)
    NUMCORESPERCPU=$(grep -m 1 '^cpu cores' /proc/cpuinfo |awk '{print $4}') # Assume all CPUs have same cores per CPU
fi 

CPUMODEL=$(grep -m 1 '^model name' /proc/cpuinfo |sed 's/.*: //g;s/ @.*//g')
#CPUMANUFACTURER=$(dmidecode -t processor |grep -m 1 -E '[[:blank:]]+Manufacturer' |awk '{print $2}')
#CPUFAMILY=$(dmidecode -t processor |grep -m 1 -E '[[:blank:]]+Family' |awk '{print $2}')

# Memory distribution
NUMDIMMS=$(dmidecode -t memory |grep -E '^[[:blank:]]+Locator' |wc -l) # In GB
GBPERDIMM=$(dmidecode -t memory |grep -m 1 -E '^[[:blank:]]+Size' |awk '{print $2}') # Assume all dimms have same amount

# Disks
DISKSJSON=""
DISKSINFO=""
disks=$(ls /sys/block)
for disk in $disks ; do 
    rotate=$(cat /sys/block/$disk/queue/rotational)
    case $rotate in
        0)
            disktype="ssd"
            ;;
        1)
            disktype="hdd"
            ;;
        *)
            echo "Unknown disk type for $disk"
            echo "Can't determine if SSD or HDD"
            exit 1
            ;;
    esac
    size=$(($(lsblk -b --output SIZE -n -d /dev/$disk)/1024/1024/1024)) # Size in GB, rough estimate should round okay but larger sizes may differ
    DISKSJSON="{\"units\": 1, \"type\": \"$disktype\", \"capacity\": $size},$DISKSJSON"
    DISKSINFO="${size}GB $disktype, $DISKSINFO"
done

# GPU - Not sure

#
# Determine Power
#

case $PLATFORM in 
    "AWS")
        country=$(curl -s -L https://github.com/PaulieScanlon/cloud-regions-country-flags/raw/main/from-provider.js |grep "'$(curl -s --fail http://169.254.169.254/latest/meta-data/placement/region)':" -A 5 |grep country |sed "s/.* = '//g;s/'.*//g")
        if [[ "$country" == "England" ]] ; then
            country="United Kingdom"
        elif [[ "$country" == "South Korea" ]] ; then
            country="Korea, Republic Of"
        elif [[ "$country" == "United States of America" ]] ; then
            country="United States"
        fi
        LOCATION=$(curl -s https://api.boavizta.org/v1/utils/country_code |sed "s/.*$country\":\"//g;s/\".*//g")
        ;;
    "Azure")
        LOCATION=$()
        ;;
    *)
        # Attempt to work out location by external IP
        ip=$(curl -s https://ipinfo.io/ip)
        LOCATION=$(curl -s https://ipapi.co/$ip/country_code_iso3)
        ;;
esac

#
# Return GWP
#
# Returns:
# - No Load Impact
# - Medium Load Impact
# - Full Load Impact


## Create JSON
#
# Usage: 
# - Consider 1 hour in eval
# - Lifespan of 5 years
#
BASEREQUEST="
{
  \"model\": {
    \"type\": \"rack\"
  },
  \"configuration\": {
    \"cpu\": {
      \"units\": $NUMCPUS,
      \"core_units\": $NUMCORESPERCPU,
      \"name\": \"$CPUMODEL\"
    },
    \"ram\": [{
      \"units\": $NUMDIMMS,
      \"capacity\": $GBPERDIMM
    }],
    \"disk\": [
    $(echo "$DISKSJSON" |sed 's/,$//g')
    ]
  },
"

NOLOADREQUEST="$BASEREQUEST
  \"usage\": {
    \"usage_location\": \"$LOCATION\",
    \"hours_use_time\": 1,
    \"hours_life_time\": 1,
    \"time_workload\": 0
  }
}
"

HALFLOADREQUEST="$BASEREQUEST
  \"usage\": {
    \"usage_location\": \"$LOCATION\",
    \"hours_use_time\": 1,
    \"hours_life_time\": 1,
    \"time_workload\": 50
  }
}
"

FULLLOADREQUEST="$BASEREQUEST
  \"usage\": {
    \"usage_location\": \"$LOCATION\",
    \"hours_use_time\": 1,
    \"hours_life_time\": 1,
    \"time_workload\": 100
  }
}
"

NOLOAD=$(curl -s -X 'POST' \
  'https://api.boavizta.org/v1/server/?verbose=true&criteria=gwp' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "$NOLOADREQUEST" |jq '.impacts.gwp.use.value')

HALFLOAD=$(curl -s -X 'POST' \
  'https://api.boavizta.org/v1/server/?verbose=true&criteria=gwp' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "$HALFLOADREQUEST" |jq '.impacts.gwp.use.value')

FULLLOAD=$(curl -s -X 'POST' \
  'https://api.boavizta.org/v1/server/?verbose=true&criteria=gwp' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "$FULLLOADREQUEST" |jq '.impacts.gwp.use.value')

#
# Query Overview
#

cat << EOF
## Estimated System Specs

CPU: $NUMCPUS x $CPUMODEL ($NUMCORESPERCPU core(s) per CPU)
RAM: $NUMDIMMS x ${GBPERDIMM}GB
Disks: $(echo "$DISKSINFO" |sed 's/, $//g')

## Platform & Power Information

Platform: $PLATFORM
Location: $LOCATION

## Estimated Carbon Consumption

No Load: ${NOLOAD}kgCO2eq/hr
Half Load: ${HALFLOAD}kgCO2eq/hr
Full Load: ${FULLLOAD}kgCO2eq/hr
EOF
