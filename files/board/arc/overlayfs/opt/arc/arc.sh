#!/usr/bin/env bash

. /opt/arc/include/functions.sh
. /opt/arc/include/addons.sh
. /opt/arc/include/modules.sh
. /opt/arc/include/consts.sh

# Check partition 3 space, if < 2GiB uses ramdisk
RAMCACHE=0
LOADER_DISK="`blkid | grep 'LABEL="ARC3"' | cut -d3 -f1`"
LOADER_DEVICE_NAME=`echo ${LOADER_DISK} | sed 's|/dev/||'`
if [ `cat /sys/block/${LOADER_DEVICE_NAME}/${LOADER_DEVICE_NAME}3/size` -lt 4194304 ]; then
  RAMCACHE=1
fi

# Export LKM: dev to userconfig
writeConfigKey "lkm" "dev" "${USER_CONFIG_FILE}"

# Get actual IP
IP=`ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`

# Check for Hypervisor
if grep -q ^flags.*\ hypervisor\  /proc/cpuinfo; then
    MACHINE="VIRTUAL"
    HYPERVISOR=$(lscpu | grep Hypervisor | awk '{print $3}')
fi

# Get DISK Config
if [ $(lspci -nn | grep -ie "\[0100\]" -ie "\[0107\]" | wc -l) -gt 0 ]; then
    RAIDSCSI="1"
fi
if [ $(lspci -nn | grep -ie "\[0106\]" -ie "\[0104\]" | wc -l) -gt 0 ]; then
    SATAHBA="1"
fi

# Dirty flag
DIRTY=0

MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
LAYOUT="`readConfigKey "layout" "${USER_CONFIG_FILE}"`"
KEYMAP="`readConfigKey "keymap" "${USER_CONFIG_FILE}"`"
LKM="`readConfigKey "lkm" "${USER_CONFIG_FILE}"`"
DIRECTBOOT="`readConfigKey "directboot" "${USER_CONFIG_FILE}"`"
SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"

###############################################################################
# Mounts backtitle dynamically
function backtitle() {
  BACKTITLE="ARC v${ARC_VERSION} |"
  if [ -n "${MODEL}" ]; then
    BACKTITLE+=" ${MODEL}"
  else
    BACKTITLE+=" (no model)"
  fi
    BACKTITLE+=" |"
  if [ -n "${BUILD}" ]; then
    BACKTITLE+=" ${BUILD}"
  else
    BACKTITLE+=" (no build)"
  fi
    BACKTITLE+=" |"
  if [ -n "${SN}" ]; then
    BACKTITLE+=" ${SN}"
  else
    BACKTITLE+=" (no SN)"
  fi
    BACKTITLE+=" |"
  if [ -n "${IP}" ]; then
    BACKTITLE+=" ${IP}"
  else
    BACKTITLE+=" (no IP)"
  fi
    BACKTITLE+=" |"
  if [ "$RAIDSCSI" -gt 0 ]; then
    BACKTITLE+=" RAID/SCSI"
  elif [ "$SATAHBA" -gt 0 ]; then
    BACKTITLE+=" SATA/HBA"
  else
    BACKTITLE+=" No HDD found"
  fi
    BACKTITLE+=" |"
  if [ -n "${HYPERVISOR}" ]; then
    BACKTITLE+=" ${HYPERVISOR}"
  else
    BACKTITLE+=" Baremetal"
  fi
    BACKTITLE+=" |"
  if [ -n "${KEYMAP}" ]; then
    BACKTITLE+=" (${LAYOUT}/${KEYMAP})"
  else
    BACKTITLE+=" (qwerty/us)"
  fi
  echo ${BACKTITLE}
}

###############################################################################
# Make Model Config
function arcMenu() {
  RESTRICT=1
  FLGBETA=0
  dialog --backtitle "`backtitle`" --title "Model" --aspect 18 \
    --infobox "Reading models" 0 0
  while true; do
    echo "" > "${TMP_PATH}/menu"
    FLGNEX=0
    while read M; do
      M="`basename ${M}`"
      M="${M::-4}"
      PLATFORM=`readModelKey "${M}" "platform"`
      DT="`readModelKey "${M}" "dt"`"
      BETA="`readModelKey "${M}" "beta"`"
      SN="`readModelKey "${M}" "serial"`"
      MAC1="`readModelKey "${M}" "mac1"`"
      MAC2="`readModelKey "${M}" "mac2"`"
      MAC3="`readModelKey "${M}" "mac3"`"
      MAC4="`readModelKey "${M}" "mac4"`"
      [ "${BETA}" = "true" -a ${FLGBETA} -eq 0 ] && continue
      # Check id model is compatible with CPU
      COMPATIBLE=1
      if [ ${RESTRICT} -eq 1 ]; then
        for F in `readModelArray "${M}" "flags"`; do
          if ! grep -q "^flags.*${F}.*" /proc/cpuinfo; then
            COMPATIBLE=0
            FLGNEX=1
            break
          fi
        done
      fi
      [ "${DT}" = "true" ] && DT="-DT" || DT=""
      [ ${COMPATIBLE} -eq 1 ] && echo "${M} \"\Zb${PLATFORM}${DT}\Zn\" " >> "${TMP_PATH}/menu"
    done < <(find "${MODEL_CONFIG_PATH}" -maxdepth 1 -name \*.yml | sort)
    [ ${FLGNEX} -eq 1 ] && echo "f \"\Z1Show incompatible \Zn\"" >> "${TMP_PATH}/menu"
    [ ${FLGBETA} -eq 0 ] && echo "b \"\Z1Show beta \Zn\"" >> "${TMP_PATH}/menu"
    dialog --backtitle "`backtitle`" --colors --menu "Choose the model" 0 0 0 \
      --file "${TMP_PATH}/menu" 2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    resp=$(<${TMP_PATH}/resp)
    [ -z "${resp}" ] && return
    if [ "${resp}" = "f" ]; then
      RESTRICT=0
      continue
    fi
    if [ "${resp}" = "b" ]; then
      FLGBETA=1
      continue
    fi
    # If user change model, clean buildnumber and S/N
    if [ "${MODEL}" != "${resp}" ]; then
      MODEL=${resp}
      writeConfigKey "model" "${MODEL}" "${USER_CONFIG_FILE}"
      BUILD="42962"
      writeConfigKey "build" "${BUILD}" "${USER_CONFIG_FILE}"
      writeConfigKey "sn" "${SN}" "${USER_CONFIG_FILE}"
      # Delete old files
      rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}"
      DIRTY=1
    fi
    break
  done
  arcbuild
}

###############################################################################
# Adding Synoinfo and Addons
function arcbuild() {
  ITEMS="`readConfigEntriesArray "builds" "${MODEL_CONFIG_PATH}/${MODEL}.yml" | sort -r`"
  dialog --clear --no-items --backtitle "`backtitle`" \
    --menu "Choose a build number" 0 0 0 ${ITEMS} 2>${TMP_PATH}/resp
  [ $? -ne 0 ] && return
  resp=$(<${TMP_PATH}/resp)
  [ -z "${resp}" ] && return
  if [ "${BUILD}" != "${resp}" ]; then
    dialog --backtitle "`backtitle`" --title "Build Number" \
      --infobox "Reconfiguring Synoinfo, Addons and Modules" 0 0
    BUILD=${resp}
    writeConfigKey "build" "${BUILD}" "${USER_CONFIG_FILE}"
    # Delete synoinfo and reload model/build synoinfo
    writeConfigKey "synoinfo" "{}" "${USER_CONFIG_FILE}"
    while IFS="=" read KEY VALUE; do
      writeConfigKey "synoinfo.${KEY}" "${VALUE}" "${USER_CONFIG_FILE}"
    done < <(readModelMap "${MODEL}" "builds.${BUILD}.synoinfo")
    # Check addons
    PLATFORM="`readModelKey "${MODEL}" "platform"`"
    KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
    while IFS="=" read ADDON PARAM; do
      [ -z "${ADDON}" ] && continue
      if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
        deleteConfigKey "addons.${ADDON}" "${USER_CONFIG_FILE}"
      fi
    done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")
    # Rebuild modules
    writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
    while read ID DESC; do
      writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
    done < <(getAllModules "${PLATFORM}" "${KVER}")
    # Remove old files
    rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}"
    DIRTY=1
  fi
  dialog --backtitle "`backtitle`" --title "ARC Config" \
    --infobox "Configuration successfull!" 0 0  
    arcdiskconf
}

###############################################################################
# Adding Synoinfo and Addons
function arcdiskconf() {
    dialog --backtitle "`backtitle`" --title "ARC Config" \
        --infobox "ARC Disk configuration started!" 0 0  
    let diskidxmapidx=0
    badportfail=false
    sataportmap=""
    diskidxmap=""

    maxdisks="`readModelKey "${MODEL}" "disks"`"

    # look for dummy SATA flagged by kernel (bad ports)
    dmys=$(dmesg | grep ": DUMMY$" | awk -F"] ata" '{print $2}' | awk -F: '{print $1}' | sort -n)

    # if we cannot find usb disk, the boot disk must be intended for SATABOOT
    if [ $(ls -la /sys/block/sd* | fgrep "/usb" | wc -l) -eq 0 ]; then
        loaderdisk=$(mount | grep -i optional | grep cde | awk -F / '{print $3}' | uniq | cut -c 1-3)
        sbpci=$(ls -la /sys/block/$loaderdisk | awk -F"/ata" '{print $1}' | awk -F"/" '{print $NF}' | cut --complement -f1 -d:)
    fi

    # get all SATA controllers PCI class 106
    # 100 = SCSI, 104 = RAIDHBA, 107 = SAS - none of these appear to honor sataportmap/diskidxmap
        pcis=$(
        lspci -d ::104
        lspci -d ::106 | awk '{print $1}'
    )

    # loop through controllers in correct order
    for pci in $pcis; do
        # get attached block devices (exclude CD-ROMs)
        ports=$(ls -la /sys/class/ata_device | fgrep "$pci" | wc -l)
        drives=$(ls -la /sys/block | fgrep "$pci" | grep -v "sr.$" | wc -l)
        echo -e "\nFound \"$(lspci -s $pci | sed "s/\ .*://")\""
        echo -n "Detected $ports ports/$drives drives. "

        # look for bad ports on this controller
        badports=""
        for dmy in $dmys; do
            badpci=$(ls -la /sys/class/ata_port/ata$dmy | awk -F"/ata$dmy/ata_port/" '{print $1}' | awk -F"/" '{print $NF}' | cut --complement -f1 -d:)
            [ "$pci" = "$badpci" ] && badports=$(echo $badports$dmy" ")
        done
        # display the bad ports, referenced to controller port numbering
        if [ ! -z "$badports" ]; then
            # minmap is invalid with bad ports!
            [ "$1" = "minmap" ] && badportfail=true
            # get first port of PCI adapter with bad ports
            badportbase=$(ls -la /sys/class/ata_port | fgrep "$badpci" | awk -F"/ata_port/ata" '{print $2}' | sort -n | head -1)
            echo -n "Bad ports:"
            for badport in $badports; do
                let badport=$badport-$badportbase+1
                echo -n " "$badport
            done
            echo -n ". "
        fi
        # SATABOOT controller? (if so, it has to be mapped as first controller, we think)
        if [ "$pci" = "$sbpci" ]; then
            [ ${drives} -gt 1 ]
            sataportmap=$sataportmap"1"
            diskidxmap=$diskidxmap$(printf "%02X" $maxdisks)
        else
            if [ "$pci" = "00:1f.2" ] && [ "$HYPERVISOR" = "KVM" ]; then
                # KVM q35 bogus controller?
                sataportmap=$sataportmap"1"
                diskidxmap=$diskidxmap$(printf "%02X" $maxdisks)
            else
                # handle VMware virtual SATA controller insane port count
                if [ "$HYPERVISOR" = "VMware" ] && [ $ports -eq 30 ]; then
                    ports=8
                else
                    # if minmap and not vmware virtual sata, don't update sataportmap/diskidxmap
                    if [ "$1" = "minmap" ]; then
                        echo
                        continue
                    fi
                fi
                # if badports are in the port range, set the fail flag
                if [ ! -z "$badports" ]; then
                    for badport in $badports; do
                        let badport=$badport-$badportbase+1
                        [ $ports -ge $badport ] && badportfail=true
                    done
                fi
                if [ $ports -gt 9 ]; then
                    let ports=$ports+48
                    portchar=$(printf \\$(printf "%o" $ports))
                else
                    portchar=$ports
                fi
                sataportmap=$sataportmap$portchar
                diskidxmap=$diskidxmap$(printf "%02x" $diskidxmapidx)
                let diskidxmapidx=$diskidxmapidx+$ports
            fi
        fi
    done

    # ports > maxdisks?
    [ "$diskidxmapidx" -gt "$maxdisks" ]

    # fix kernel panic if 1st position is set to 0 ports (from no SATA mappings or deliberate user selection)
    [ -z "$sataportmap" -o "${sataportmap:0:1}" = "0" ] && sataportmap=1${sataportmap:1}

    # handle no assigned SATA ports affecting SCSI mapping problem
    [ -z "$diskidxmap" ] && diskidxmap="00"

    # now advise on SCSI drives for user peace of mind
    # 100 = SCSI, 104 = RAIDHBA, 107 = SAS - none of these honor sataportmap/diskidxmap
    pcis=$(
        lspci -d ::100
        lspci -d ::107 | awk '{print $1}'
    )
    [ ! -z "$pcis" ] && echo
    # loop through non-SATA controllers
    for pci in $pcis; do
        # get attached block devices (exclude CD-ROMs)
        drivesscsi=$(ls -la /sys/block | fgrep "$pci" | grep -v "sr.$" | wc -l)
        echo "Found RAID/SCSI \""$(lspci -s $pci | sed "s/\ .*://")"\" ($drivesscsi drives)"
    done
    writeConfigKey "cmdline.SataPortMap" "$sataportmap" "${USER_CONFIG_FILE}"
    writeConfigKey "cmdline.DiskIdxMap" "$diskidxmap" "${USER_CONFIG_FILE}"
    dialog --backtitle "`backtitle`" --title "ARC Config" \
      --infobox "ARC Disk configuration successfull! SataPortMap=${sataportmap} | DiskIdxMap=${diskidxmap}" 0 0  
    sleep 5
    arcnet
}

###############################################################################
# Make Network Config
function arcnet() {
  lshw -class network -short > "${TMP_PATH}/netconf"
  if grep -R "eth0" "${TMP_PATH}/netconf"
  then
    if grep -R "eth1" "${TMP_PATH}/netconf"
    then
      if grep -R "eth2" "${TMP_PATH}/netconf"
      then
        if grep -R "eth3" "${TMP_PATH}/netconf"
        then
          echo "4 Network Adapter found"
          writeConfigKey "cmdline.mac1"           "$MAC1" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.mac2"           "$MAC2" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.mac3"           "$MAC3" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.mac4"           "$MAC4" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.netif_num" "4"            "${USER_CONFIG_FILE}"
        else
          echo "3 Network Adapter found"
          writeConfigKey "cmdline.mac1"           "$MAC1" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.mac2"           "$MAC2" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.mac3"           "$MAC3" "${USER_CONFIG_FILE}"
          writeConfigKey "cmdline.netif_num" "3"            "${USER_CONFIG_FILE}"
        fi
      else
        echo "2 Network Adapter found"
        writeConfigKey "cmdline.mac1"             "$MAC1" "${USER_CONFIG_FILE}"
        writeConfigKey "cmdline.mac2"             "$MAC2" "${USER_CONFIG_FILE}"
        writeConfigKey "cmdline.netif_num" "2"              "${USER_CONFIG_FILE}"
      fi
    else
      echo "1 Network Adapter found"
      writeConfigKey "cmdline.mac1"               "$MAC1" "${USER_CONFIG_FILE}"
      writeConfigKey "cmdline.netif_num" "1"                "${USER_CONFIG_FILE}"
    fi
  else
    echo "No Network Adapter found"
  fi
  MAC1="`readConfigKey "cmdline.mac1" "${USER_CONFIG_FILE}"`"
  MAC="${MAC1:0:2}:${MAC1:2:2}:${MAC1:4:2}:${MAC1:6:2}:${MAC1:8:2}:${MAC1:10:2}"
  ip link set dev eth0 address ${MAC} 2>&1 | dialog --backtitle "`backtitle`" \
    --title "Load ARC MAC Table" --infobox "Set new MAC" 0 0
  sleep 5
  /etc/init.d/S41dhcpcd restart 2>&1 | dialog --backtitle "`backtitle`" \
    --title "Load ARC MAC Table" --progressbox "Renewing IP" 20 70
  sleep 5
  IP=`ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`
  dialog --backtitle "`backtitle`" --title "ARC Config" \
      --infobox "ARC Network configuration successfull!" 0 0
  sleep 5
  dialog --clear --no-items --backtitle "`backtitle`"
}

###############################################################################
# Extracting DSM for building Loader
function extractDsmFiles() {
  PAT_URL="`readModelKey "${MODEL}" "builds.${BUILD}.pat.url"`"
  PAT_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.hash"`"
  RAMDISK_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.ramdisk-hash"`"
  ZIMAGE_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.zimage-hash"`"

  if [ ${RAMCACHE} -eq 0 ]; then
    OUT_PATH="${CACHE_PATH}/dl"
    echo "Cache to disk"
  else
    OUT_PATH="${TMP_PATH}/dl"
    echo "Cache to ram"
  fi
  mkdir -p "${OUT_PATH}"

  PAT_FILE="${MODEL}-${BUILD}.pat"
  PAT_PATH="${OUT_PATH}/${PAT_FILE}"
  EXTRACTOR_PATH="${CACHE_PATH}/extractor"
  EXTRACTOR_BIN="syno_extract_system_patch"
  OLDPAT_URL="https://global.download.synology.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"
  OLDPAT_PATH="${OUT_PATH}/DS3622xs+-42218.pat"

  if [ -f "${PAT_PATH}" ]; then
    echo "${PAT_FILE} cached."
  else
    echo "Downloading ${PAT_FILE}"
    STATUS=`curl --insecure -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar`
    if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
      dialog --backtitle "`backtitle`" --title "Error downloading" --aspect 18 \
        --msgbox "Check internet or cache disk space" 0 0
      return 1
    fi
  fi

  echo -n "Checking hash of ${PAT_FILE}: "
  if [ "`sha256sum ${PAT_PATH} | awk '{print$1}'`" != "${PAT_HASH}" ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of pat not match, try again!" 0 0
    rm -f ${PAT_PATH}
    return 1
  fi
  echo "OK"

  rm -rf "${UNTAR_PAT_PATH}"
  mkdir "${UNTAR_PAT_PATH}"
  echo -n "Disassembling ${PAT_FILE}: "

  header="$(od -bcN2 ${PAT_PATH} | head -1 | awk '{print $3}')"
  case ${header} in
    105)
      echo "Uncompressed tar"
      isencrypted="no"
      ;;
    213)
      echo "Compressed tar"
      isencrypted="no"
      ;;
    255)
      echo "Encrypted"
      isencrypted="yes"
      ;;
    *)
      dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
        --msgbox "Could not determine if pat file is encrypted or not, maybe corrupted, try again!" \
        0 0
      return 1
      ;;
  esac

  if [ "${isencrypted}" = "yes" ]; then
    # Check existance of extractor
    if [ -f "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" ]; then
      echo "Extractor cached."
    else
      # Extractor not exists, get it.
      mkdir -p "${EXTRACTOR_PATH}"
      # Check if old pat already downloaded
      if [ ! -f "${OLDPAT_PATH}" ]; then
        echo "Downloading old pat to extract synology .pat extractor..."
        STATUS=`curl --insecure -w "%{http_code}" -L "${OLDPAT_URL}" -o "${OLDPAT_PATH}"  --progress-bar`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "Error downloading" --aspect 18 \
            --msgbox "Check internet or cache disk space" 0 0
          return 1
        fi
      fi
      # Extract ramdisk from PAT
      rm -rf "${RAMDISK_PATH}"
      mkdir -p "${RAMDISK_PATH}"
      tar -xf "${OLDPAT_PATH}" -C "${RAMDISK_PATH}" rd.gz >"${LOG_FILE}" 2>&1
      if [ $? -ne 0 ]; then
        dialog --backtitle "`backtitle`" --title "Error extracting" --textbox "${LOG_FILE}" 0 0
      fi

      # Extract all files from rd.gz
      (cd "${RAMDISK_PATH}"; xz -dc < rd.gz | cpio -idm) >/dev/null 2>&1 || true
      # Copy only necessary files
      for f in libcurl.so.4 libmbedcrypto.so.5 libmbedtls.so.13 libmbedx509.so.1 libmsgpackc.so.2 libsodium.so libsynocodesign-ng-virtual-junior-wins.so.7; do
        cp "${RAMDISK_PATH}/usr/lib/${f}" "${EXTRACTOR_PATH}"
      done
      cp "${RAMDISK_PATH}/usr/syno/bin/scemd" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}"
      rm -rf "${RAMDISK_PATH}"
    fi
    # Uses the extractor to untar pat file
    echo "Extracting..."
    LD_LIBRARY_PATH=${EXTRACTOR_PATH} "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}" || true
  else
    echo "Extracting..."
    tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}" >"${LOG_FILE}" 2>&1
    if [ $? -ne 0 ]; then
      dialog --backtitle "`backtitle`" --title "Error extracting" --textbox "${LOG_FILE}" 0 0
    fi
  fi

  echo -n "Checking hash of zImage: "
  HASH="`sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}'`"
  if [ "${HASH}" != "${ZIMAGE_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of zImage not match, try again!" 0 0
    return 1
  fi
  echo "OK"
  writeConfigKey "zimage-hash" "${ZIMAGE_HASH}" "${USER_CONFIG_FILE}"

  echo -n "Checking hash of ramdisk: "
  HASH="`sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}'`"
  if [ "${HASH}" != "${RAMDISK_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of ramdisk not match, try again!" 0 0
    return 1
  fi
  echo "OK"
  writeConfigKey "ramdisk-hash" "${RAMDISK_HASH}" "${USER_CONFIG_FILE}"

  echo -n "Copying files: "
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/zImage"          "${ORI_ZIMAGE_FILE}"
  cp "${UNTAR_PAT_PATH}/rd.gz"           "${ORI_RDGZ_FILE}"
  echo "DSM extract complete" 
}

###############################################################################
# Building Loader
function make() {
  clear
  MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
  BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"

  # Check if all addon exists
  while IFS="=" read ADDON PARAM; do
    [ -z "${ADDON}" ] && continue
    if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
      dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
        --msgbox "Addon ${ADDON} not found!" 0 0
      return 1
    fi
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")

  [ ! -f "${ORI_ZIMAGE_FILE}" -o ! -f "${ORI_RDGZ_FILE}" ] && extractDsmFiles

  /opt/arc/zimage-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "zImage not patched:\n`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  /opt/arc/ramdisk-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Ramdisk not patched:\n`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  echo "Cleaning"
  rm -rf "${UNTAR_PAT_PATH}"

  echo "Ready!"
  sleep 3
  DIRTY=0
  return 0
}

###############################################################################
# Calls boot.sh to boot into DSM kernel/ramdisk
function boot() {
  [ ${DIRTY} -eq 1 ] && dialog --backtitle "`backtitle`" --title "Alert" \
    --yesno "Config changed, would you like to rebuild the loader?" 0 0
  if [ $? -eq 0 ]; then
    make || return
  fi
  boot.sh
}

###############################################################################
# Permits user edit the user config
function editUserConfig() {
  while true; do
    dialog --backtitle "`backtitle`" --title "Edit with caution" \
      --editbox "${USER_CONFIG_FILE}" 0 0 2>"${TMP_PATH}/userconfig"
    [ $? -ne 0 ] && return
    mv "${TMP_PATH}/userconfig" "${USER_CONFIG_FILE}"
    ERRORS=`yq eval "${USER_CONFIG_FILE}" 2>&1`
    [ $? -eq 0 ] && break
    dialog --backtitle "`backtitle`" --title "Invalid YAML format" --msgbox "${ERRORS}" 0 0
  done
  OLDMODEL=${MODEL}
  OLDBUILD=${BUILD}
  MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
  BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
  SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"
  if [ "${MODEL}" != "${OLDMODEL}" -o "${BUILD}" != "${OLDBUILD}" ]; then
    # Remove old files
    rm -f "${MOD_ZIMAGE_FILE}"
    rm -f "${MOD_RDGZ_FILE}"
  fi
  DIRTY=1
}

###############################################################################
# Shows available Drives
function alldrives() {
        TEXT=""
        NUMPORTS=0
        for PCI in `lspci -nn | grep -ie "\[0106\]" | awk '{print$1}'`; do
          NAME=`lspci -s "${PCI}" | sed "s/\ .*://"`
          TEXT+="\Z1SATA Controller\Zn dedected:\n\Zb${NAME}\Zn\n\nPorts: "
          unset HOSTPORTS
          declare -A HOSTPORTS
          while read LINE; do
            ATAPORT="`echo ${LINE} | grep -o 'ata[0-9]*'`"
            PORT=`echo ${ATAPORT} | sed 's/ata//'`
            HOSTPORTS[${PORT}]=`echo ${LINE} | grep -o 'host[0-9]*$'`
          done < <(ls -l /sys/class/scsi_host | fgrep "${PCI}")
          while read PORT; do
            ls -l /sys/block | fgrep -q "${PCI}/ata${PORT}" && ATTACH=1 || ATTACH=0
            PCMD=`cat /sys/class/scsi_host/${HOSTPORTS[${PORT}]}/ahci_port_cmd`
            [ "${PCMD}" = "0" ] && DUMMY=1 || DUMMY=0
            [ ${ATTACH} -eq 1 ] && TEXT+="\Z2\Zb"
            [ ${DUMMY} -eq 1 ] && TEXT+="\Z1"
            TEXT+="${PORT}\Zn "
            NUMPORTS=$((${NUMPORTS}+1))
          done < <(echo ${!HOSTPORTS[@]} | tr ' ' '\n' | sort -n)
          TEXT+="\n"
        done
        TEXT+="\nTotal of ports: ${NUMPORTS}\n"
        TEXT+="\nPorts with color \Z1red\Zn as DUMMY, color \Z2\Zbgreen\Zn has drive connected."
        TEXT+="\n \n"
        alldrivessas
}

###############################################################################
# Shows available Drives
function alldrivessas() {
        if [ $(lspci -nn | grep -ie "\[0100\]" -ie "\[0107\]" | wc -l) -gt 0 ]; then
        pcis=$(
        lspci -d ::100
        lspci -d ::107 | awk '{print $1}'
        )
        [ ! -z "$pcis" ]
        # loop through non-SATA controllers
        for pci in $pcis; do
        # get attached block devices (exclude CD-ROMs)
        DRIVES=$(ls -la /sys/block | fgrep "$pci" | grep -v "sr.$" | wc -l)
        done
        for PCI in `lspci -nn | grep -ie "\[0100\]" -ie "\[0107\]" | awk '{print$1}'`; do
          NAME=`lspci -s "${PCI}" | sed "s/\ .*://"`
          TEXT+="\Z1SCSI/RAID/SAS Controller\Zn dedected:\n\Zb${NAME}\Zn\n"
          TEXT+="\nDrives: \Z2\Zb${DRIVES}\Zn connected"
          TEXT+="\n\n"
        done
        fi
        dialog --backtitle "`backtitle`" --colors --aspect 18 \
          --msgbox "${TEXT}" 0 0
}

###############################################################################
# Shows option to manage addons
function addonMenu() {
  # Read 'platform' and kernel version to check if addon exists
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  # Read addons from user config
  unset ADDONS
  declare -A ADDONS
  while IFS="=" read KEY VALUE; do
    [ -n "${KEY}" ] && ADDONS["${KEY}"]="${VALUE}"
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")
  NEXT="a"
  # Loop menu
  while true; do
    dialog --backtitle "`backtitle`" --default-item ${NEXT} \
      --menu "Choose an Option" 0 0 0 \
      a "Add an Addon" \
      d "Delete Addon(s)" \
      s "Show user Addons" \
      m "Show all available Addons" \
      o "Download a external Addon" \
      e "Exit" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a) NEXT='a'
        rm "${TMP_PATH}/menu"
        while read ADDON DESC; do
          arrayExistItem "${ADDON}" "${!ADDONS[@]}" && continue
          echo "${ADDON} \"${DESC}\"" >> "${TMP_PATH}/menu"
        done < <(availableAddons "${PLATFORM}" "${KVER}")
        if [ ! -f "${TMP_PATH}/menu" ] ; then 
          dialog --backtitle "`backtitle`" --msgbox "No available addons to add" 0 0 
          NEXT="e"
          continue
        fi
        dialog --backtitle "`backtitle`" --menu "Select an addon" 0 0 0 \
          --file "${TMP_PATH}/menu" 2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        ADDON="`<"${TMP_PATH}/resp"`"
        [ -z "${ADDON}" ] && continue
        dialog --backtitle "`backtitle`" --title "params" \
          --inputbox "Type a opcional params to addon" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        ADDONS[${ADDON}]="`<"${TMP_PATH}/resp"`"
        writeConfigKey "addons.${ADDON}" "${VALUE}" "${USER_CONFIG_FILE}"
        DIRTY=1
        ;;
      d) NEXT='d'
        if [ ${#ADDONS[@]} -eq 0 ]; then
          dialog --backtitle "`backtitle`" --msgbox "No user addons to remove" 0 0 
          continue
        fi
        ITEMS=""
        for I in "${!ADDONS[@]}"; do
          ITEMS+="${I} ${I} off "
        done
        dialog --backtitle "`backtitle`" --no-tags \
          --checklist "Select addon to remove" 0 0 0 ${ITEMS} \
          2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        ADDON="`<"${TMP_PATH}/resp"`"
        [ -z "${ADDON}" ] && continue
        for I in ${ADDON}; do
          unset ADDONS[${I}]
          deleteConfigKey "addons.${I}" "${USER_CONFIG_FILE}"
        done
        DIRTY=1
        ;;
      s) NEXT='s'
        ITEMS=""
        for KEY in ${!ADDONS[@]}; do
          ITEMS+="${KEY}: ${ADDONS[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "User addons" \
          --msgbox "${ITEMS}" 0 0
        ;;
      m) NEXT='m'
        MSG=""
        while read MODULE DESC; do
          if arrayExistItem "${MODULE}" "${!ADDONS[@]}"; then
            MSG+="\Z4${MODULE}\Zn"
          else
            MSG+="${MODULE}"
          fi
          MSG+=": \Z5${DESC}\Zn\n"
        done < <(availableAddons "${PLATFORM}" "${KVER}")
        dialog --backtitle "`backtitle`" --title "Available addons" \
          --colors --msgbox "${MSG}" 0 0
        ;;
      o)
        TEXT="please enter the complete URL to download.\n"
        dialog --backtitle "`backtitle`" --aspect 18 --colors --inputbox "${TEXT}" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        URL="`<"${TMP_PATH}/resp"`"
        [ -z "${URL}" ] && continue
        clear
        echo "Downloading ${URL}"
        STATUS=`curl --insecure -w "%{http_code}" -L "${URL}" -o "${TMP_PATH}/addon.tgz" --progress-bar`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "Error downloading" --aspect 18 \
            --msgbox "Check internet, URL or cache disk space" 0 0
          return 1
        fi
        ADDON="`untarAddon "${TMP_PATH}/addon.tgz"`"
        if [ -n "${ADDON}" ]; then
          dialog --backtitle "`backtitle`" --title "Success" --aspect 18 \
            --msgbox "Addon '${ADDON}' added to loader" 0 0
        else
          dialog --backtitle "`backtitle`" --title "Invalid addon" --aspect 18 \
            --msgbox "File format not recognized!" 0 0
        fi
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
# Permit user select the modules to include
function selectModules() {
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  dialog --backtitle "`backtitle`" --title "Modules" --aspect 18 \
    --infobox "Reading modules" 0 0
  ALLMODULES=`getAllModules "${PLATFORM}" "${KVER}"`
  unset USERMODULES
  declare -A USERMODULES
  while IFS="=" read KEY VALUE; do
    [ -n "${KEY}" ] && USERMODULES["${KEY}"]="${VALUE}"
  done < <(readConfigMap "modules" "${USER_CONFIG_FILE}")
  # menu loop
  while true; do
    dialog --backtitle "`backtitle`" --menu "Choose a option" 0 0 0 \
      s "Show selected Modules" \
      a "Select all Modules" \
      d "Deselect all Modules" \
      c "Choose Modules to include" \
      e "Exit" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && break
    case "`<${TMP_PATH}/resp`" in
      s) ITEMS=""
        for KEY in ${!USERMODULES[@]}; do
          ITEMS+="${KEY}: ${USERMODULES[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "User modules" \
          --msgbox "${ITEMS}" 0 0
        ;;
      a) dialog --backtitle "`backtitle`" --title "Modules" \
           --infobox "Selecting all modules" 0 0
        unset USERMODULES
        declare -A USERMODULES
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        while read ID DESC; do
          USERMODULES["${ID}"]=""
          writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
        done <<<${ALLMODULES}
        ;;
      d) dialog --backtitle "`backtitle`" --title "Modules" \
           --infobox "Deselecting all modules" 0 0
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        unset USERMODULES
        declare -A USERMODULES
        ;;
      c)
        rm -f "${TMP_PATH}/opts"
        while read ID DESC; do
          arrayExistItem "${ID}" "${!USERMODULES[@]}" && ACT="on" || ACT="off"
          echo "${ID} ${DESC} ${ACT}" >> "${TMP_PATH}/opts"
        done <<<${ALLMODULES}
        dialog --backtitle "`backtitle`" --title "Modules" --aspect 18 \
          --checklist "Select modules to include" 0 0 0 \
          --file "${TMP_PATH}/opts" 2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        resp=$(<${TMP_PATH}/resp)
        [ -z "${resp}" ] && continue
        dialog --backtitle "`backtitle`" --title "Modules" \
           --infobox "Writing to user config" 0 0
        unset USERMODULES
        declare -A USERMODULES
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        for ID in ${resp}; do
          USERMODULES["${ID}"]=""
          writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
        done
        ;;
      e)
        break
        ;;
    esac
  done
}

###############################################################################
# Shows available keymaps to user choose one
function keymapMenu() {
  dialog --backtitle "`backtitle`" --default-item "${LAYOUT}" --no-items \
    --menu "Choose a Layout" 0 0 0 "azerty" "bepo" "carpalx" "colemak" \
    "dvorak" "fgGIod" "neo" "olpc" "qwerty" "qwertz" \
    2>${TMP_PATH}/resp
  [ $? -ne 0 ] && return
  LAYOUT="`<${TMP_PATH}/resp`"
  OPTIONS=""
  while read KM; do
    OPTIONS+="${KM::-7} "
  done < <(cd /usr/share/keymaps/i386/${LAYOUT}; ls *.map.gz)
  dialog --backtitle "`backtitle`" --no-items --default-item "${KEYMAP}" \
    --menu "Choice a keymap" 0 0 0 ${OPTIONS} \
    2>/tmp/resp
  [ $? -ne 0 ] && return
  resp=`cat /tmp/resp 2>/dev/null`
  [ -z "${resp}" ] && return
  KEYMAP=${resp}
  writeConfigKey "layout" "${LAYOUT}" "${USER_CONFIG_FILE}"
  writeConfigKey "keymap" "${KEYMAP}" "${USER_CONFIG_FILE}"
  zcat /usr/share/keymaps/i386/${LAYOUT}/${KEYMAP}.map.gz | loadkeys
}

###############################################################################
# Shows update menu to user
function updateMenu() {
  while true; do
    dialog --backtitle "`backtitle`" --menu "Choose an Option" 0 0 0 \
      a "Update ARC" \
      d "Update Addons" \
      l "Update LKMs" \
      m "Update Modules" \
      e "Exit" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a)
        dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
          --infobox "Checking last version" 0 0
        ACTUALVERSION="v${ARC_VERSION}"
        TAG="`curl --insecure -s https://api.github.com/repos/AuxXxilium/arc/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`"
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
            --msgbox "Error checking new version" 0 0
          continue
        fi
        if [ "${ACTUALVERSION}" = "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
            --yesno "No new version. Actual version is ${ACTUALVERSION}\nForce update?" 0 0
          [ $? -ne 0 ] && continue
        fi
        dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
          --infobox "Downloading last version ${TAG}" 0 0
        # Download update file
        STATUS=`curl --insecure -w "%{http_code}" -L \
          "https://github.com/AuxXxilium/arc/releases/download/${TAG}/update.zip" -o /tmp/update.zip`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
            --msgbox "Error downloading update file" 0 0
          continue
        fi
        unzip -oq /tmp/update.zip -d /tmp
        if [ $? -ne 0 ]; then
          dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
            --msgbox "Error extracting update file" 0 0
          continue
        fi
        # Check checksums
        (cd /tmp && sha256sum --status -c sha256sum)
        if [ $? -ne 0 ]; then
          dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
            --msgbox "Checksum do not match!" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
          --infobox "Installing new files" 0 0
        # Process update-list.yml
        while IFS="=" read KEY VALUE; do
          mv /tmp/`basename "${KEY}"` "${VALUE}"
        done < <(readConfigMap "replace" "/tmp/update-list.yml")
        while read F; do
          [ -f "${F}" ] && rm -f "${F}"
          [ -d "${F}" ] && rm -Rf "${F}"
        done < <(readConfigArray "remove" "/tmp/update-list.yml")
        dialog --backtitle "`backtitle`" --title "Update ARC" --aspect 18 \
          --yesno "ARC updated with success to ${TAG}!\nReboot?" 0 0
        [ $? -ne 0 ] && continue
        reboot
        exit
        ;;

      d)
        dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
          --infobox "Checking last version" 0 0
        TAG=`curl --insecure -s https://api.github.com/repos/AuxXxilium/arc-addons/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
            --msgbox "Error checking new version" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
          --infobox "Downloading last version" 0 0
        STATUS=`curl --insecure -s -w "%{http_code}" -L "https://github.com/AuxXxilium/arc-addons/releases/download/${TAG}/addons.zip" -o /tmp/addons.zip`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
            --msgbox "Error downloading new version" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
          --infobox "Extracting last version" 0 0
        rm -rf /tmp/addons
        mkdir -p /tmp/addons
        unzip /tmp/addons.zip -d /tmp/addons >/dev/null 2>&1
        dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
          --infobox "Installing new addons" 0 0
        for PKG in `ls /tmp/addons/*.addon`; do
          ADDON=`basename ${PKG} | sed 's|.addon||'`
          rm -rf "${ADDONS_PATH}/${ADDON}"
          mkdir -p "${ADDONS_PATH}/${ADDON}"
          tar xaf "${PKG}" -C "${ADDONS_PATH}/${ADDON}" >/dev/null 2>&1
        done
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "Update addons" --aspect 18 \
          --msgbox "Addons updated with success!" 0 0
        ;;

      l)
        dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
          --infobox "Checking last version" 0 0
        TAG=`curl --insecure -s https://api.github.com/repos/AuxXxilium/redpill-lkm/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
            --msgbox "Error checking new version" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
          --infobox "Downloading last version" 0 0
        STATUS=`curl --insecure -s -w "%{http_code}" -L "https://github.com/AuxXxilium/redpill-lkm/releases/download/${TAG}/rp-lkms.zip" -o /tmp/rp-lkms.zip`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
            --msgbox "Error downloading last version" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
          --infobox "Extracting last version" 0 0
        rm -rf "${LKM_PATH}/"*
        unzip /tmp/rp-lkms.zip -d "${LKM_PATH}" >/dev/null 2>&1
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "Update LKMs" --aspect 18 \
          --msgbox "LKMs updated with success!" 0 0
        ;;
      m)
        unset PLATFORMS
        declare -A PLATFORMS
        while read M; do
          M="`basename ${M}`"
          M="${M::-4}"
          P=`readModelKey "${M}" "platform"`
          ITEMS="`readConfigEntriesArray "builds" "${MODEL_CONFIG_PATH}/${M}.yml"`"
          for B in ${ITEMS}; do
            KVER=`readModelKey "${M}" "builds.${B}.kver"`
            PLATFORMS["${P}-${KVER}"]=""
          done
        done < <(find "${MODEL_CONFIG_PATH}" -maxdepth 1 -name \*.yml | sort)
        dialog --backtitle "`backtitle`" --title "Update Modules" --aspect 18 \
          --infobox "Checking last version" 0 0
        TAG=`curl --insecure -s https://api.github.com/repos/AuxXxilium/arc-modules/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "Update Modules" --aspect 18 \
            --msgbox "Error checking new version" 0 0
          continue
        fi
        for P in ${!PLATFORMS[@]}; do
          dialog --backtitle "`backtitle`" --title "Update Modules" --aspect 18 \
            --infobox "Downloading ${P} modules" 0 0
          STATUS=`curl --insecure -s -w "%{http_code}" -L "https://github.com/AuxXxilium/arc-modules/releases/download/${TAG}/${P}.tgz" -o "/tmp/${P}.tgz"`
          if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
            dialog --backtitle "`backtitle`" --title "Update Modules" --aspect 18 \
              --msgbox "Error downloading ${P}.tgz" 0 0
            continue
          fi
          rm "${MODULES_PATH}/${P}.tgz"
          mv "/tmp/${P}.tgz" "${MODULES_PATH}/${P}.tgz"
        done
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "Update Modules" --aspect 18 \
          --msgbox "Modules updated with success!" 0 0
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
# Shows Systeminfo to user
function sysinfo() {
        TYPEINFO=$(vserver=$(lscpu | grep Hypervisor | wc -l)
            if [ $vserver -gt 0 ]; then echo "VM"; else echo "Baremetal"; fi
        )
        CPUINFO=$(awk -F':' '/^model name/ {print $2}' /proc/cpuinfo | uniq | sed -e 's/^[ \t]*//')
        MEMINFO=$(free -g | awk 'NR==2' | awk '{print $2}')
        SCSIPCI=$(lspci -nn | grep -ie "\[0100\]" -ie "\[0107\]" | awk '{print$1}')
        SCSIINFO=$(lspci -s "${SCSIPCI}" | sed "s/\ .*://")
        SATAPCI=$(lspci -nn | grep -ie "\[0106\]" -ie "\[0104\]" | awk '{print$1}')
        SATAINFO=$(lspci -s "${SATAPCI}" | sed "s/\ .*://")
        MODULESINFO=$(kmod list | awk '{print$1}' | awk 'NR>1')
        TEXT=""
        TEXT+="\nSystem: \Zb${TYPEINFO}\Zn"
        if [ -n $HYPERVISOR ]; then
        TEXT+="\nHypervisor: \Zb$HYPERVISOR\Zn\n"
        fi
        TEXT+="\nCPU: \Zb${CPUINFO}\Zn"
        TEXT+="\nRAM: \Zb${MEMINFO}GB\Zn\n"
        if [ -n "$RAIDSCSI" ]; then
        TEXT+="\nStorage Mode: \ZbSCSI/RAID Mode enabled\Zn\n"
        TEXT+="\nRAID/SCSI Controller dedected:\n\Zb${SCSIINFO}\Zn\n"
        fi
        if [ -n "$SATAHBA" ]; then
        TEXT+="\nStorage Mode: \ZbSATA/HBA Mode enabled\Zn\n"
        TEXT+="\nSATA/HBA Controller dedected:\n\Zb${SATAINFO}\Zn"
        fi
        TEXT+="\n"
        TEXT+="\nModules: \Zb${MODULESINFO}\n"
        TEXT+="\n"
        dialog --backtitle "`backtitle`" --title "Systeminformation" --aspect 18 --colors --msgbox "${TEXT}" 0 0 
}

###############################################################################
###############################################################################

if [ "x$1" = "xb" -a -n "${MODEL}" -a -n "${BUILD}" -a loaderIsConfigured ]; then
  make
  boot
fi
# Main loop
NEXT="m"
while true; do
  echo "- \"========== Main ========== \" "                                                 > "${TMP_PATH}/menu"
  echo "m \"Choose Model for Loader \" "                                                    >> "${TMP_PATH}/menu"
  if [ -n "${MODEL}" ]; then
  echo "l \"Build the Loader \" "                                                           >> "${TMP_PATH}/menu"
  fi
  if loaderIsConfigured; then
  echo "b \"Boot the Loader \" "                                                            >> "${TMP_PATH}/menu"
  fi
  echo "= \"======== Enhanced ======== \" "                                                 >> "${TMP_PATH}/menu"
  if [ -n "${MODEL}" ]; then
  echo "g \"Show Controller/Drives \" "                                                     >> "${TMP_PATH}/menu"
  fi
  if [ -n "${MODEL}" ]; then
  echo "a \"Addons \" "                                                                     >> "${TMP_PATH}/menu"
  echo "o \"Modules \" "                                                                    >> "${TMP_PATH}/menu"
  echo "u \"Edit user config \" "                                                           >> "${TMP_PATH}/menu"
  fi
  echo "t \"Sysinfo \" "                                                                    >> "${TMP_PATH}/menu"
  echo "r \"Switch direct boot: \Z4${DIRECTBOOT}\Zn \" "                                    >> "${TMP_PATH}/menu"
  echo "# \"======== Settings ======== \" "                                                 >> "${TMP_PATH}/menu"
  echo "k \"Choose a keymap \" "                                                            >> "${TMP_PATH}/menu"
  [ ${RAMCACHE} -eq 0 -a -d "${CACHE_PATH}/dl" ] && echo "c \"Clean disk cache \" "         >> "${TMP_PATH}/menu"
  echo "p \"Update Menu\" "                                                                 >> "${TMP_PATH}/menu"
  echo "e \"Exit\" "                                                                        >> "${TMP_PATH}/menu"
  dialog --clear --default-item ${NEXT} --backtitle "`backtitle`" --colors \
    --menu "Choose the option" 0 0 0 --file "${TMP_PATH}/menu" \
    2>${TMP_PATH}/resp
  [ $? -ne 0 ] && break
  case `<"${TMP_PATH}/resp"` in
    m) arcMenu; NEXT="l" ;;
    l) make; NEXT="b" ;;
    b) boot ;;
    g) alldrives ;;
    a) addonMenu ;;
    o) selectModules ;;
    u) editUserConfig ;;
    t) sysinfo ;;
    r) [ "${DIRECTBOOT}" = "false" ] && DIRECTBOOT='true' || DIRECTBOOT='false'
    writeConfigKey "directboot" "${DIRECTBOOT}" "${USER_CONFIG_FILE}"
    NEXT="b"
    ;;
    k) keymapMenu ;;
    c) dialog --backtitle "`backtitle`" --title "Cleaning" --aspect 18 \
      --prgbox "rm -rfv \"${CACHE_PATH}/dl\"" 0 0 ;;
    p) updateMenu ;;
    e) break ;;
  esac
done
clear
echo -e "Call \033[1;32marc.sh\033[0m to return to menu"