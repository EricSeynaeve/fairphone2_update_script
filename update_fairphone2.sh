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
sh_file="$HOME/.fairphone2_updatesh"
config_dir="$HOME/.fairphone2_updater"
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
fp2-sibon-16.10.0 https://storage.googleapis.com/fairphone-updates/d7c72422-62fa-4a19-80af-a2fdd4bee25e/fp2-sibon-16.10.0-manual-userdebug.zip 6481730bc6588507f7b9de63db9c3a67 d2a69742aff49ef00db4a8dcd984fdfc6c9c3723279db21a20a55289d4411e61 https://forum.fairphone.com/t/fairphone-open-16-10-0-is-now-available/22849
fp2-sibon-16.09.0 - - - https://forum.fairphone.com/t/fairphone-open-16-09-0-is-now-available/22464
fp2-sibon-16.08.0 http://storage.googleapis.com/fairphone-updates/fp2-sibon-16.08.0-manual-userdebug.zip 855ee24f97ca85cc3219a9bc67a8967d e2270cf62d507abba87f824e551af10547761c52041b111641235713590407d5 https://forum.fairphone.com/t/fairphone-open-16-08-0-is-now-available/21973
fp2-sibon-16.07.1 - - - https://forum.fairphone.com/t/fp-open-os-16-07-is-now-available/21064
fp2-sibon-16.04.0 - - - https://forum.fairphone.com/t/fairphone-2-open-os-is-available/17208
EOL

  fp_open_versions=("open_16.04.0" "fp2-sibon-16.07.1" "fp2-sibon-16.08.0" "fp2-sibon-16.09.0" "fp2-sibon-16.10.0")

  mkdir -p "$download_dir"
  if [[ -f "$sh_file" ]]
  then
    source "$sh_file"
  fi
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

  if [[ $(adb devices | sed '1d') == *device* ]]
  then
    fp_version=$(adb -s $serial shell "getprop ro.build.display.id" | dos2unix)
    fp_version=${fp_version##* }
    encrypted=$(adb -s $serial shell "getprop ro.crypto.state" | dos2unix)
    if [[ $encrypted == "unencrypted" ]]
    then
      encrypted='false'
    else
      encrypted='true'
    fi
    echo "-= You are currently running OS version $fp_version =-"
    if [[ $encrypted == 'true' ]]
    then
      echo "-= Your phone is encrypted. =-"
    fi
    echo "prev_detected_fp_version=$fp_version" > "$sh_file"
    echo "prev_detected_encrypted=$encrypted" > "$sh_file"
  else
    # see if we can find a previous detected version
    fp_version=${prev_detected_fp_version:-}
    encrypted=${prev_detected_encrypted:-}
    if [[ -z $fp_version ]]
    then
      echo "-= Unable to find current fairphone version. =-"
      echo "-= Assuming you're running the latest version. =-"
      fp_version=${fp_open_versions[-1]}
    fi
  fi
}

function download_image() {
  local i=0
  fp_next_version=''
  if [[ $fp_version == ${fp_open_versions[-1]} ]]
  then
    fp_next_version=$fp_version
    echo "-= You are running the latest OS version =-"
    return
  fi
  while (( i < ${#fp_open_versions[@]} ))
  do
    if [[ ${fp_open_versions[$i]} == $fp_version ]]
    then
      fp_next_version=${fp_open_versions[$i+1]}
      break
    fi
    i=$(( i + 1 ))
  done
  if [[ -z $fp_next_version ]]
  then
    echo "-= You are running an unknown OS version =-"
    exit 1
  fi

  local url=${update_url[$fp_next_version]}
  image_filename="$download_dir/${url##*/}"

  echo "-= Downloading the Fairphone image for $fp_next_version to $download_dir =-"

  wget --continue --output-document "$image_filename" $url

  echo "-= Checking the integrity of the downloaded image =-"
  echo "${update_md5[$fp_next_version]} $image_filename" > "$image_filename.md5"
  echo "${update_sha2[$fp_next_version]} $image_filename" > "$image_filename.sha2"
  echo -n "MD5 sum check: "
  md5sum --check "$image_filename.md5"
  echo -n "SHA256 sum check: "
  sha256sum --check "$image_filename.sha2"

  echo "-= All is OK. You can continue to flash this image =-"
}

function flash_boot() {
  if [[ $fp_next_version == $fp_version ]]
  then
    echo "-= No need to flash your ROM. =-"
    return
  fi

  echo "-= Please reboot the phone in fastboot mode. =-"
  echo "   For this:"
  echo "     - power off the phone"
  echo "     - disconnect the phone from the computer,"
  echo "     - startup and hold down the Volume Down button during bootup."
  echo "       Don't be worried if the bootup screen remains visible. This is normal."
  echo "   See https://forum.fairphone.com/t/pencil2-installing-fairphone-open-os-using-fastboot-step-by-step-guide/17522"
  echo "   While rebooting, I will extract the image for version $fp_next_version."

  rm -rf "$download_dir/flash"
  mkdir -p "$download_dir/flash"
  cd "$download_dir/flash"
  unzip "$image_filename"
  chmod u+x "$download_dir/flash/flash.sh"

  echo "-= Preparation is finished. =-"
  echo "   Ensure that the phone is reconnected via USB to this computer."
  read -p "Press <enter> when reboot to fastboot is finished and USB is connected again."

  if ! (timeout 10 fastboot devices | grep fastboot)
  then
    echo "-= No devices detected via fastboot."
    echo "   Is the connectivity OK ?"
    echo "      E.g. bad USB cable"
    echo "      E.g. battery empty"
    echo "   Did you setup the udev rule correctly ? =-"
    echo "      Check the setting of the udev rule as described on"
    echo "      https://developer.android.com/studio/run/device.html#setting-up"
    echo "      Example of udev rule in the file /etc/udev/rules.d/51-fp2-android.rules:"
    echo "         SUBSYSTEM==\"usb\", ATTR{idVendor}==\"18d1\", ATTR{idProduct}==\"d00d\",MODE=\"0666\", OWNER=\"your_user_name\""
    return
  fi

  echo "-= Upgrading your OS from $fp_version to $fp_next_version. =-"
  ./flash.sh
  echo "-= Done. Your phone should now be rebooting in version $fp_next_version. =-"
}

function install_or_update_fdroid()
{
  local fdroid_name='org.fdroid.fdroid'
  if ! adb shell dumpsys package $fdroid_name >/dev/null
  then
    read -p "Do you wish to install FDroid [Y/n] ? "
    if [[ ${REPLY,,} == "n" ]]
    then
      return
    fi
  else
    local fdroid_version=$(adb shell dumpsys package $fdroid_name | awk -F'[[:space:]=]*' '$2 == "versionCode" {print $3}')
    if (( $fdroid_version < 101050 ))
    then
      read -p "Do you wish to update FDroid [Y/n] ? "
      if [[ ${REPLY,,} == "n" ]]
      then
        return
      fi
      # removing fdroid if installed as normal app
      adb uninstall org.fdroid.fdroid || true
    else
      echo "FDroid is on the latest version."
      return
    fi
  fi
  echo "-= Downloading latest fdroid version =-"
  local fdroid_apk="/var/tmp/fdroid.apk"
  wget --continue --output-document $fdroid_apk https://f-droid.org/repo/org.fdroid.fdroid_101050.apk

  echo "-= Making fdroid a system app =-"
  echo "   In order to do this, make sure that you have enabled debugging option"
  echo "   and that in there, ADB can obtain root."
  read -p "Press <enter> when all is setup for ADB root access."
  adb push $fdroid_apk /sdcard/FDroid.apk
  adb shell su -c \'mount -o rw,remount /system\'
  adb shell su -c \'mv /sdcard/FDroid.apk /system/priv-app/\'
  adb shell su -c \'chmod 644 /system/priv-app/FDroid.apk\'
  adb shell su -c \'mount -o ro,remount /system\'
  echo "-= FDroid will be available after the next reboot =-"
}

function install_or_update_app()
{
  local nick=$1
  local name=$2
  local version=$3
  local url=$4

  local installed_version=$(adb shell dumpsys package $name | awk -F'[[:space:]=]*' '$2 == "versionCode" {print $3}')
  if [[ -z $installed_version ]]
  then
    read -p "Do you wish to install $nick [Y/n] ? "
    if [[ ${REPLY,,} == "n" ]]
    then
      return
    fi
  elif (( $installed_version < $version ))
  then
    read -p "Do you wish to update $nick [Y/n] ? "
    if [[ ${REPLY,,} == "n" ]]
    then
      return
    fi
  else
    echo "$nick is up-to-date"
    return
  fi

  local tmpfile=$(mktemp --tmpdir=/var/tmp "${nick}_XXXXXXXXXXX.apk")
  wget -O "$tmpfile" $url
  adb install "$tmpfile"
  rm -f "$tmpfile"
}

function install_or_update_apps()
{
  install_or_update_app OsmAnd~ net.osmand.plus 247 https://f-droid.org/repo/net.osmand.plus_247.apk
  install_or_update_app DAVdroid at.bitfire.davdroid 123 https://f-droid.org/repo/at.bitfire.davdroid_123.apk
  install_or_update_app K-9Mail com.fsck.k9 23113 https://f-droid.org/repo/com.fsck.k9_23113.apk
}

function install_trusted_certs()
{
  local certs_dir="$config_dir/trusted_cert"

  local hash
  local tmpfile
  echo "-= Install trusted system certs =-"
  for crt in $(ls $certs_dir/*.crt)
  do
    hash=$(openssl x509 -inform PEM -subject_hash_old -in $crt | head -n 1)
    echo "   Installing cert ${hash}.0"
    tmpfile=$(mktemp --tmpdir=/var/tmp "cert_XXXXXXXXXXX.crt")
    cat $crt > $tmpfile
    openssl x509 -inform PEM -text -in $crt -out /dev/null >> $tmpfile
    adb shell rm -rf /sdcard/certs
    adb shell mkdir /sdcard/certs
    adb push $tmpfile /sdcard/certs/${hash}.0
    adb shell su -c \'mount -o rw,remount /system\'
    adb shell su -c \'mv /sdcard/certs/${hash}.0 /system/etc/security/cacerts/\'
    adb shell su -c \'chmod 644 /system/etc/security/cacerts/${hash}.0\'
    adb shell su -c \'mount -o ro,remount /system\'
    rm -f $tmpfile
  done
  echo "-= System certs will be available after next reboot =-"
}

function main()
{
  init
  phone_information
  download_image
  flash_boot
  adb wait-for-device
  install_or_update_fdroid
  install_or_update_apps
  install_trusted_certs
}

main

# vim: set ai tabstop=2 shiftwidth=2 expandtab :
