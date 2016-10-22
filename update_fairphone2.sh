#! /bin/bash

function error_exit {
  local parent_lineno="$1"
  local message="$2"
  local code="${3:-1}"
  if [[ -n "$message" ]]
  then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi

  exit "${code}"
}
trap 'error_exit ${LINENO}' ERR

set -o errexit
set -o pipefail
set -o nounset

download_dir="/var/tmp/fairphone_downloads"
declare -A update_url
declare -A update_md5
declare -A update_sha2
declare -A update_announce_url
function init()
{
  local version url md5 sha2 announce

  while read version url md5 sha2 announce
  do
    update_url[$version]=$url
    update_md5[$version]=$md5
    update_sha2[$version]=$sha2
    update_announce_url[$version]=$announce
  done << EOL
open_16.08.0 http://storage.googleapis.com/fairphone-updates/fp2-sibon-16.08.0-manual-userdebug.zip 855ee24f97ca85cc3219a9bc67a8967d e2270cf62d507abba87f824e551af10547761c52041b111641235713590407d5 https://forum.fairphone.com/t/fairphone-open-16-08-0-is-now-available/21973
open_16.09.0 - - - https://forum.fairphone.com/t/fairphone-open-16-09-0-is-now-available/22464
open_16.10.0 https://storage.googleapis.com/fairphone-updates/d7c72422-62fa-4a19-80af-a2fdd4bee25e/fp2-sibon-16.10.0-manual-userdebug.zip 6481730bc6588507f7b9de63db9c3a67 d2a69742aff49ef00db4a8dcd984fdfc6c9c3723279db21a20a55289d4411e61 https://forum.fairphone.com/t/fairphone-open-16-10-0-is-now-available/22849
fp2-sibon-16.07.1 - - - https://forum.fairphone.com/t/fp-open-os-16-07-is-now-available/21064
open_16.04.0 - - - https://forum.fairphone.com/t/fairphone-2-open-os-is-available/17208
EOL

  fp_open_versions=("open_16.04.0" "fp2-sibon-16.07.1" "open_16.08.0" "open_16.09.0" "open_16.10.0")

  mkdir -p "$download_dir"
}

function sideload_boot()
{
  echo "Connect phone in recovery mode with sideload option on!"
  echo "Press <enter> to continue"
  read
  
  # Get newest firmware download
  link=$(lynx --dump $1 'https://fairphone.zendesk.com/hc/en-us/articles/213290023-Fairphone-OS-downloads-for-Fairphone-2'|awk '/http/{print $2}'|grep '.zip'|head -n1)

  echo "-= Downloading update =-"
  wget $link

  fileName=$(echo $link|rev|cut -d/ -f1|rev)
  androiddir=$(locate platform-tools|head -n1)

  echo "-= Sideloading update =-"
  sudo $androiddir/adb sideload $fileName

  echo "-= Removing update =-"
  sudo rm -f $fileName

  echo "-= Done! Reboot the phone =-"
}

function phone_information() {
  echo "-= Getting information about your phone. =-"
  echo "   Please ensure that you can use ADB"
  echo "   and that your phone is in USB debugging."
  echo "   Read https://developer.android.com/studio/command-line/adb.html#Enabling"
  echo "   for more information about enabling ADB"
  echo
  read -p "Press <enter> when all is setup for ADB."

  local serial

  serial=$(adb devices | awk '$2 == "device" {print $1}')
  if [[ $serial == 'no' ]]
  then
    echo "No devices found !" 1>&2
    return 10
  fi

  fp_version=$(adb -s $serial shell "getprop ro.build.display.id" | dos2unix)
  fp_version=${fp_version##* }
  echo "-= You are currently running OS version $fp_version =-"
}

function download_image() {
  local i=0
  echo -n $fp_version | od -bc
  while (( i < ${#fp_open_versions[@]} ))
  do
    if [[ ${fp_open_versions[$i]} == $fp_version ]]
    then
      break
    fi
    i=$(( i + 1 ))
  done
  if (( i > ${#fp_open_versions[@]} ))
  then
    echo "-= You are running an unknown OS version =-"
    exit 1
  fi
  if (( i == ${#fp_open_versions[@]} ))
  then
    echo "-= You are running the latest OS version =-"
    return
  fi

  fp_next_version=${fp_open_versions[$i+1]}
  local url=${update_url[$fp_next_version]}
  local filename="$download_dir/${url##*/}"

  echo "-= Downloading the Fairphone image for $fp_next_version to $download_dir =-"

  wget --continue --output-document "$filename" $url

  echo "-= Checking the integrity of the downloaded image =-"
  echo "${update_md5[$fp_next_version]} $filename" > "$filename.md5"
  echo "${update_sha2[$fp_next_version]} $filename" > "$filename.sha2"
  echo -n "MD5 sum check: "
  md5sum --check "$filename.md5"
  echo -n "SHA256 sum check: "
  sha256sum --check "$filename.sha2"

  echo "-= All is OK. You can continue to flash this image =-"
}

function flash_rooted_boot() {
  echo "Connect phone with usb debugging on!"
  echo "Press <enter> to continue"
  read
  
  lynx_opts=$1 

  # Get newest bootimage download
  link=$(lynx --dump $lynx_opts 'https://fairphone.zendesk.com/hc/en-us/articles/213290023-Fairphone-OS-downloads-for-Fairphone-2'|awk '/http/{print $2}'|grep '.zip'|head -n1)
  fileName=$(echo $link|rev|cut -d/ -f1|rev)
  version=$(echo $fileName|cut -d- -f3)

  linkImage=$(lynx --dump $lynx_opts 'https://fp2.retsifp.de/'|awk '/http/{print $2}'|grep "$version/"|head -n1)
  linkImage=$(lynx --dump $lynx_opts "$linkImage"|awk '/http/{print $2}'|grep '.img'|grep '-eng-'|head -n1)

  echo "-= Downloading root image =-"
  wget $linkImage

  fileName=$(echo $linkImage|rev|cut -d/ -f1|rev)
  androiddir=$(locate platform-tools|head -n1)

  echo "-= Reboot phone =-"
  sudo $androiddir/adb reboot bootloader
  sleep 30

  echo "-= Push boot.img =-"
  sudo $androiddir/fastboot flash boot $fileName
  sleep 10

  echo "-= Reboot phone =-"
  sudo $androiddir/fastboot reboot

  echo "-= Removing file =-"
  sudo rm -f $fileName
}

function main()
{
  init
  phone_information
  download_image
}

main

# vim: set ai tabstop=2 shiftwidth=2 expandtab :
