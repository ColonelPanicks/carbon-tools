#!/bin/bash
#
# Estimate the average carbon impact of this system based off of it's specifications
#

# Vars
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOG_DIR="$DIR/logs"

# Exit if no jq
if ! which jq >/dev/null 2>&1 ; then
    echo "Can't find command 'jq', this is required for program to function"
    exit 1
fi

# Prepare log stuff
if [ ! -d $LOG_DIR ] ; then
    mkdir $LOG_DIR
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
# - Number of PSUs - Not sure how this could possibly be worked out for VMs, potentially with IPMI on hardware
# - Number of GPUs - Not yet supported in Boavizta

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
# - 1 hour of usage
# - 1 hour of lifetime (otherwise lifetime worth of manufacture is included
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

#
# Get GWP from Specs
#

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
# Get GWP from Instance Type
#
# This will likely be lower than the "from specs" answers because:
# - Specs does not do any resource "sharing" for virtualisation
#   which means it is assumed the system has a dedicated PSU
# - Specs also includes HDDs/SSDs whereas cloud instance types do not
#   although it seems that disks only have manufacture cost

if [ ! -z $USE_INSTANCE_TYPE ] ; then

NOLOADINSTANCEREQUEST="{
\"provider\": \"aws\", 
\"instance_type\": \"$INSTANCE_TYPE\",
\"usage\" : { 
  \"usage_location\": \"GBR\", 
  \"hours_use_time\": 1, 
  \"hours_life_time\": 1, 
  \"time_workload\": [{ 
    \"time_percentage\": 100, 
    \"load_percentage\": 0
    }]
  }
}
"
HALFLOADINSTANCEREQUEST="{
\"provider\": \"aws\", 
\"instance_type\": \"$INSTANCE_TYPE\",
\"usage\" : { 
  \"usage_location\": \"GBR\", 
  \"hours_use_time\": 1, 
  \"hours_life_time\": 1, 
  \"time_workload\": [{ 
    \"time_percentage\": 100, 
    \"load_percentage\": 50
    }]
  }
}
"

FULLLOADINSTANCEREQUEST="{
\"provider\": \"aws\", 
\"instance_type\": \"$INSTANCE_TYPE\",
\"usage\" : { 
  \"usage_location\": \"GBR\", 
  \"hours_use_time\": 1, 
  \"hours_life_time\": 1, 
  \"time_workload\": [{ 
    \"time_percentage\": 100, 
    \"load_percentage\": 100
    }]
  }
}
"

NOLOADINSTANCE="$(curl -s -X 'POST' -H 'accept: application/json' 'https://api.boavizta.org/v1/cloud/instance?verbose=true&criteria=gwp' -H 'Content-Type: application/json' -d "$NOLOADINSTANCEREQUEST" |jq '.impacts.gwp.use.value')"
HALFLOADINSTANCE="$(curl -s -X 'POST' -H 'accept: application/json' 'https://api.boavizta.org/v1/cloud/instance?verbose=true&criteria=gwp' -H 'Content-Type: application/json' -d "$HALFLOADINSTANCEREQUEST" |jq '.impacts.gwp.use.value')"
FULLLOADINSTANCE="$(curl -s -X 'POST' -H 'accept: application/json' 'https://api.boavizta.org/v1/cloud/instance?verbose=true&criteria=gwp' -H 'Content-Type: application/json' -d "$FULLLOADINSTANCEREQUEST" |jq '.impacts.gwp.use.value')"

NOLOADAVG=$(echo "print(round(($NOLOAD+$NOLOADINSTANCE)/2,4))" |python)
HALFLOADAVG=$(echo "print(round(($HALFLOAD+$HALFLOADINSTANCE)/2,4))" |python)
FULLLOADAVG=$(echo "print(round(($FULLLOAD+$FULLLOADINSTANCE)/2,4))" |python)

fi

#
# Output
#

# Debug information

cat <<EOF > $LOG_DIR/debug.log
Date of Report: $(date)

#
# System Info
#

## Estimated System Specs

CPU: $NUMCPUS x $CPUMODEL ($NUMCORESPERCPU core(s) per CPU)
RAM: $NUMDIMMS x ${GBPERDIMM}GB
Disks: $(echo "$DISKSINFO" |sed 's/, $//g')

## Platform & Power Information

Platform: $PLATFORM
Location: $LOCATION

#
# Hardware Spec Queries
#

# No Load
$NOLOADREQUEST

# Half Load
$HALFLOADREQUEST

# Full Load
$FULLLOADREQUEST

EOF

if [ ! -z $USE_INSTANCE_TYPE ] ; then
    cat << EOF >> $LOG_DIR/debug.log
#
# Instance Type Queries
#

# No Load
$NOLOADINSTANCEREQUEST

# Half Load
$HALFLOADINSTANCEREQUEST

# Full Load
$FULLLOADINSTANCEREQUEST
EOF
fi

# Data
cat << EOF > $LOG_DIR/data.sh
NOLOAD=$NOLOAD
HALFLOAD=$HALFLOAD
FULLLOAD=$FULLLOAD
EOF

if [ ! -z $USE_INSTANCE_TYPE ] ; then
    cat << EOF >> $LOG_DIR/data.sh
NOLOADINSTANCE=$NOLOADINSTANCE
HALFLOADINSTANCE=$HALFLOADINSTANCE
FULLLOADINSTANCE=$FULLLOADINSTANCE
NOLOADAVG=$NOLOADAVG
HALFLOADAVG=$HALFLOADAVG
FULLLOADAVG=$FULLLOADAVG
EOF
fi

# Carbon Report
cat << EOF > $LOG_DIR/report.md
## Estimated System Specs

CPU: $NUMCPUS x $CPUMODEL ($NUMCORESPERCPU core(s) per CPU)
RAM: $NUMDIMMS x ${GBPERDIMM}GB
Disks: $(echo "$DISKSINFO" |sed 's/, $//g')

## Platform & Power Information

Platform: $PLATFORM
Location: $LOCATION

## Estimated Carbon Consumption (From Specs)

No Load: ${NOLOAD}kgCO2eq/hr
Half Load: ${HALFLOAD}kgCO2eq/hr
Full Load: ${FULLLOAD}kgCO2eq/hr
EOF

if [ ! -z $USE_INSTANCE_TYPE ] ; then
    cat << EOF >> $LOG_DIR/report.md

## Estimated Carbon Consumption (From Instance Type) 

No Load: ${NOLOADINSTANCE}kgCO2eq/hr
Half Load: ${HALFLOADINSTANCE}kgCO2eq/hr
Full Load: ${FULLLOADINSTANCE}kgCO2eq/hr

## Combined Carbon Consumption Estimate (Average of Previous 2 Estimates)

No Load: $(echo "print(round(($NOLOAD+$NOLOADINSTANCE)/2,4))"  |python)kgCO2eq/hr
Half Load: $(echo "print(round(($HALFLOAD+$HALFLOADINSTANCE)/2,4))"  |python)kgCO2eq/hr
Full Load: $(echo "print(round(($FULLLOAD+$FULLLOADINSTANCE)/2,4))"  |python)kgCO2eq/hr
EOF
fi

cat $LOG_DIR/report.md
