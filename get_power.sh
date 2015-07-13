#!/bin/bash -
#===============================================================================
#
#          FILE: get_power.sh
#
#         USAGE: ./get_power.sh
#
#   DESCRIPTION: Get power consumption for rack server or IBM BladeServer
#                (getting from IBM Blade Center chassis)
#
#       OPTIONS: ---
#  REQUIREMENTS: ipmitool, dmidecode, snmpwalk, awk, date, ls, cat,
#                flock, pgrep, mktemp, hostname, ps
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Polonevich Ivan
#  ORGANIZATION:
#       CREATED: 07/06/2015 14:57
#      REVISION: 005
#===============================================================================

#set -x                                     # Uncomment for debug
set -o nounset                              # Treat unset variables as an error

readonly TMP_DIR='/tmp'
readonly PROGNAME=$(basename "$0")
readonly LOCK_FD=200
readonly TIME_CACHE_INDEX_SECS=14400
readonly TIME_CACHE_VALUE_SECS=60
readonly MAX_RETRY=6
readonly IP=                                # IP IBM Blade Center

lock() {
  local prefix=$1
  local fd=${2:-$LOCK_FD}
  local lock_file=$TMP_DIR/$prefix.lock

  # create lock file
  eval "exec $fd>$lock_file"

  # acquier the lock
  flock -n $fd \
      && return 0 \
      || return 1
}
eexit() {
  local error_str="$@"
  echo $error_str
  exit 1
}
cache() {
  local cache_file=$TMP_DIR/${FUNCNAME[1]}.cached
  local -a tmp_vars=($@)
  local time_cache_sec=${tmp_vars[0]}
  local command_for_cache=${tmp_vars[@]:1:${#tmp_vars[*]}}

  if [[ "$command_for_cache" == "remove_cached_file" ]]; then
    rm -f $TMP_DIR/*.cached
    eexit "0"
  fi

  if [ -s $cache_file ]; then
    local time_file=$(ls -l --time-style="+%s" "$cache_file" | awk '{print $6}')
    local time_now=$(date "+%s")
    local time_diff=$(($time_now - $time_file))
    local result=

    if [[ $time_diff -ge $time_cache_sec ]];then
      result=$(cat $cache_file)
      ( { [[ ! $(pgrep $(echo $command_for_cache | awk '{print $1}')) ]] && local tmpfile=$(mktemp ${cache_file}.XXXXX); eval $command_for_cache > $tmpfile; mv -f $tmpfile $cache_file;} > /dev/null 2>&1 &);
    else
      result=$(cat $cache_file)
    fi
  else
    result=$( [[ ! $(pgrep $(echo $command_for_cache | awk '{print $1}')) ]] && local tmpfile=$(mktemp ${cache_file}.XXXXX); eval $command_for_cache > $tmpfile; mv -f $tmpfile $cache_file; cat $cache_file) || eexit "0"
  fi
  echo $result
}
get_index() {
  local slot="$2"
  local IP="$1"
  local result=
  oid="for i in 2 3; do walktree=\$(snmpwalk -Oqn -r2 -t30 -c public -v1 $IP .1.3.6.1.4.1.2.3.51.2.2.10.\$i.1.1.2| grep \"serverBladeBay$slot(\" ) ; if [[ \$walktree ]]; then echo \$walktree | awk '{b=gensub(/(\w+).1.1.2.(\w+)/, \"\\\\1.1.1.7.\\\\2\", \"g\", \$1 ); print b}' 2>/dev/null ; break;fi ;done"
  result=$(cache $TIME_CACHE_INDEX_SECS $oid)
  if [[ -z $result ]];then
    exit 1
  fi 
  echo $result
}
main () {
  lock $PROGNAME || eexit "0"

  is_blade=`dmidecode | grep -i "Location In Chassis" | grep -c Slot`

  if [[ $is_blade -eq 1 ]]; then
    slot=$(dmidecode | grep -i "Location In Chassis" | awk -F: '{print $2}' | sed -r "s/^.+?Slot(\w+).*?$/\1/" | sed -r "s/^0(\w+)$/\1/")
    result=
    retry=0
    while [[ $retry -lt $MAX_RETRY ]] && [[ -z $result ]]; do
      result=$(cache $TIME_CACHE_VALUE_SECS snmpwalk -r2 -t20 -c public -v1 $IP $(get_index $IP $slot) 2>/dev/null | sed -r "s/^.*\"(\w+)W\"$/\1/")
      ((retry++))
      if [[ $retry -eq 6 ]];then
        # Clean cache
        cache "remove_cached_file"
      fi
    done
    echo $result

  else
    if [ "$(ps ax | grep -v grep | grep -c ipmitool)" -gt "3" ];
      then echo '0';
    else
      cache $TIME_CACHE_VALUE_SECS "ipmitool sdr | awk -F\"|\" '{if (tolower(\$2) ~ /watt/) print \$2}' | awk 'BEGIN {RS = \"\\n\" ; FS = \" \" } { SUM+=\$1} END {print SUM}'"
    fi
  fi
}

main
