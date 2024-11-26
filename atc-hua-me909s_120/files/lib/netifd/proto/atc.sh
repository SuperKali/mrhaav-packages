#!/bin/sh
#
# AT commands for Huawei ME909s-120 modem
# 2024-11-26 by mrhaav
#


[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

update_IPv4 () {
    proto_init_update "$ifname" 1
    proto_set_keep 1
    proto_add_ipv4_address "$v4address" "$v4netmask"
#    proto_add_ipv4_route "$v4gateway" "128"
#    [ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$v4gateway"
    [ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$v4gateway" "$v4address"/32
    [ "$peerdns" = 0 ] || {
        proto_add_dns_server "$v4dns1"
        proto_add_dns_server "$v4dns2"
    }
    [ -n "$zone" ] && {
        proto_add_data
        json_add_string zone "$zone"
        proto_close_data
    }
    proto_send_update "$interface"
}

update_DYNv4 () {
        json_init
        json_add_string name "${interface}_4"
        json_add_string ifname "@$interface"
        json_add_string proto "static"
        json_add_array ipaddr
        json_add_string "" "${v4address}/${v4netmask}"
        json_close_array
        json_add_string gateway "$v4gateway"
        [ "$peerdns" = 0 ] || {
                json_add_array dns
                json_add_string "" "$v4dns1"
                json_add_string "" "$v4dns2"
                json_close_array
        }
        json_add_string zone "wan"
        json_close_object
        echo JSON: $(json_dump)
        ubus call network add_dynamic "$(json_dump)"
}

update_DHCPv4 () {
	json_init
	json_add_string name "${interface}_4"
	json_add_string ifname "@$interface"
	json_add_string proto "dhcp"
        proto_add_dynamic_defaults
        [ -n "$zone" ] && json_add_string zone "$zone"
        json_close_object
        [ "$atc_debug" -ge 1 ] && echo JSON: $(json_dump)
        ubus call network add_dynamic "$(json_dump)"
}
update_DHCPv6 () {
    json_init
    json_add_string name "${interface}6"
    json_add_string ifname "@$interface"
    json_add_string proto "dhcpv6"
    proto_add_dynamic_defaults
    json_add_string extendprefix 1
    [ "$peerdns" = 0 ] || {
        json_add_array dns
        json_add_string "" "$v6dns1"
        json_add_string "" "$v6dns2"
        json_close_array
    }
    [ -n "$zone" ] && json_add_string zone "$zone"
    json_close_object
    [ "$atc_debug" -ge 1 ] && echo JSON: $(json_dump)
    ubus call network add_dynamic "$(json_dump)"
}

release_interface () {
    proto_init_update "$ifname" 0
    proto_send_update "$interface"
}

subnet_calc () {
    local IPaddr=$1
    local A B C D 
    local x y netaddr res subnet gateway

    A=$(echo $IPaddr | awk -F '.' '{print $1}')
    B=$(echo $IPaddr | awk -F '.' '{print $2}')
    C=$(echo $IPaddr | awk -F '.' '{print $3}')
    D=$(echo $IPaddr | awk -F '.' '{print $4}')

    x=1
    y=4
    netaddr=$((y-1))
    res=$((D%y))

    while [ $res -eq 0 ] || [ $res -eq $netaddr ]
    do
        x=$((x+1))
        y=$((y*2))
        netaddr=$((y-1))
        res=$((D%y))
    done

    subnet=$((31-x))
    gateway=$((D/y))
    [ $res -eq 1 ] && gateway=$((gateway*y+2)) || gateway=$((gateway*y+1))
    echo $subnet $A.$B.$C.$gateway
}

IPversion () {
    local addr
    local version=NULL

    addr=$(echo $1 | tr -c -d '.' | wc -c)
    [ $addr -eq 3 ] && version='IPv4'
    [ $addr -eq 15 ] && version='IPv6'

    echo $version
}

IPv6_decTOhex () {
    local ipv6_dec=$1
    local ipv6_hex
    local dec_nb h_part l_part

    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
    do
       dec_nb=$(echo $ipv6_dec | awk -F '.' '{print $'$i'}')
       h_part=$(echo $(($dec_nb/16)))
       l_part=$(echo $(($dec_nb%16)))
       ipv6_hex=$ipv6_hex$(printf '%x' $h_part)
       ipv6_hex=$ipv6_hex$(printf '%x' $l_part)
       [ $(($i%2)) -eq 0 -a $i -lt 16 ] && ipv6_hex=$ipv6_hex':'
    done

    echo $ipv6_hex
}

hua_ip_hex2dec () {
    local hex_ip=$(echo $1 | grep -o '[0-9a-fA-F]\+$')
    local dec_ip=null
    local x

    [ ${#hex_ip} -eq 8 ] && {
        for x in 6 4 2 0
        do
            [ $x -eq 6 ] && {
                dec_ip=$(printf '%d' 0x${hex_ip:$x:2})
            } || {
                dec_ip=$dec_ip'.'$(printf '%d' 0x${hex_ip:$x:2})
            }
        done
    }

    echo $dec_ip
}

full_apn () {
    local apn=$1
    local rest

    rest=$(echo ${apn#*'.mnc'})
    rest=${#rest}
    rest=$((rest+4))
    [ $rest -lt ${#apn} ] && apn=${apn:: -$rest}

    echo $apn
}

nb_rat () {
    local rat_nb=$1
    case $rat_nb in
        0|1|3 )
            rat_nb=GSM ;;
        2|4|5|6 )
            rat_nb=WCDMA ;;
        7 )
            rat_nb=LTE ;;
        11 )
            rat_nb=NR ;;
        13 )
            rat_nb=LTE-ENDC
    esac
    echo $rat_nb
}

CxREG () {
    local reg_string=$1
    local lac_tac g_cell_id rat reject_cause

    if [ ${#reg_string} -gt 6 ]
    then
        lac_tac=$(echo $reg_string | awk -F ',' '{print $2}')
        g_cell_id=$(echo $reg_string | awk -F ',' '{print $3}')
        rat=$(echo $reg_string | awk -F ',' '{print $4}')
        rat=$(nb_rat $rat)
#        reject_cause=$(echo $reg_string | awk -F ',' '{print $6}')
        [ "$rat" = 'WCDMA' ] && {
            reg_string='RNCid: '$(printf '%d' 0x${g_cell_id:: -4})' LAC:'$(printf '%d' 0x$lac_tac)' CellId:'$(printf '%d' 0x${g_cell_id: -4})
        }
        [ "${rat::3}" = 'LTE' ] && {
            reg_string='TAC:'$(printf '%d' 0x$lac_tac)' eNodeB:'$(printf '%d' 0x${g_cell_id:: -2})'-'$(printf '%d' 0x${g_cell_id: -2})
        }
#        [ "$reject_cause" -gt 0 ] && reg_string=$reg_string' - Reject cause: '$reject_cause
        echo ', '$reg_string
    else
        echo ''
    fi
}

ucs2TOascii () {
    local ucs2_string=$1
    local ascii_string=''
    local x=0
    local ucs2_char ucs2_len

    ucs2_len=$((${#ucs2_string}/4*4))

    while [ $x -lt $ucs2_len ]
    do
        ucs2_char=$(echo ${ucs2_string:$x:4})
        [ ${ucs2_char::2} = '00' ] && {
            [ ${ucs2_char: -2} = '0A' ] && {
                ascii_string=$ascii_string'\n'
            } || {
                ascii_string=$ascii_string$(printf "\\x${ucs2_char: -2}")
            }
        } || {
            ascii_string=$ascii_string'\u'$ucs2_char
        }
        x=$(($x+4))
    done
    
    echo $ascii_string
}

proto_atc_init_config() {
    no_device=1
    available=1
    proto_config_add_string "device:device"
    proto_config_add_string "apn"
    proto_config_add_string "pincode"
    proto_config_add_string "pdp"
    proto_config_add_string "auth"
    proto_config_add_string "username"
    proto_config_add_string "password"
    proto_config_add_string "atc_debug"
    proto_config_add_string "delay"
    proto_config_add_defaults
}

proto_atc_setup () {
    local interface="$1"
    local sms_rx_folder=/var/sms/rx
    local OK_received=0
    local dual_stack=0
    local re_connect=0
    local pdp_still_active=0
    local atOut manufactor model fw uesd_apn
    local dns1 dns2 rat new_rat ifname plmn cops_format status sms_index sms_text sms_sender sms_date
    local devname devpath device apn pdp pincode auth username password delay atc_debug $PROTO_DEFAULT_OPTIONS
    json_get_vars device ifname apn pdp pincode auth username password delay atc_debug $PROTO_DEFAULT_OPTIONS

    mkdir -p $sms_rx_folder

    [ -z "$delay" ] && delay=1
    [ ! -f /var/modem.status -a "$delay" -ge 1 ] && {
        echo 'Modem boot delay '$delay's'
        sleep "$delay"
    }

    [ -z $ifname ] && {
        devname=$(basename $device)
        case "$devname" in
            *ttyACM*)
                devpath="$(readlink -f /sys/class/tty/$devname/device)"
                [ -n "$devpath" ] && ifname="$(ls  $devpath/../*/net/)" 2>/dev/null
                ;;
            *ttyUSB*)
                devpath="$(readlink -f /sys/class/tty/$devname/device)"
                [ -n "$devpath" ] && ifname="$(ls $devpath/../../*/net/)"  2>/dev/null
                ;;
        esac
    }
    [ -n "$ifname" ] || {
        proto_notify_error "$interface" NO_IFACE
        proto_set_available "$interface" 0
        proto_block_restart "$interface"
        return 1
    }

    zone="$(fw3 -q network "$interface" 2>/dev/null)"
    echo 0 > /var/modem.status
    echo Initiate modem with interface $ifname

# Set error codes to verbose
    atOut=$(COMMAND='AT+CMEE=2' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    while [ "$atOut" != 'OK' ]
    do
        echo 'Modem not ready yet: '$atOut
        sleep 1
        atOut=$(COMMAND='AT+CMEE=2' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    done
    
# Check SIMcard and PIN status
#    atOut=$(COMMAND='AT+CPIN?' gcom -d "$device" -s /etc/gcom/getrun_at.gcom | grep CPIN: | awk -F ' ' '{print $2 $3}' | sed -e 's/[\r\n]//g')
    atOut=$(COMMAND='AT+CPIN?' gcom -d "$device" -s /etc/gcom/getrun_at.gcom)
    CMEerror=$(echo "$atOut" | grep 'CME ERROR:' | awk -F ':' '{print $2}' | sed -e 's/[\r\n]//g')
    atOut=$(echo "$atOut" | grep CPIN: | awk -F ' ' '{print $2 $3}' | sed -e 's/[\r\n]//g')
    if [ -n "$CMEerror" ]
    then
        [ "${CMEerror::1}" = ' ' ] && CMEerror=${CMEerror:1}
        echo $CMEerror
        proto_notify_error "$interface" SIMfailure
        proto_block_restart "$interface"
        return 1
    elif [ -z "$atOut" ]
    then
        echo 'Can not read SIMcard'
        proto_notify_error "$interface" SIMreadfailure
        proto_block_restart "$interface"
        return 1
    fi

#    while [ -z "$atOut" ]
#    do
#        atOut=$(COMMAND='AT+CPIN?' gcom -d "$device" -s /etc/gcom/getrun_at.gcom | grep CPIN: | awk -F ' ' '{print $2 $3}' | sed -e 's/[\r\n]//g')
#   done
    case $atOut in
        READY )
            echo SIMcard ready
            ;;
        SIMPIN )
            if [ -z "$pincode" ]
            then
                echo PINcode required but missing
                proto_notify_error "$interface" PINmissing
                proto_block_restart "$interface"
                return 1
            fi
            atOut=$(COMMAND='AT+CPIN="'$pincode'"' gcom -d "$device" -s /etc/gcom/getrun_at.gcom | grep 'CME ERROR:')
            if [ -n "$atOut" ]
            then
                echo PINcode error: ${atOut:11}
                proto_notify_error "$interface" PINerror
                proto_block_restart "$interface"
                return 1
            fi
            echo PINcode verified
            ;;
        * )
            echo SIMcard error: $atOut
            proto_notify_error "$interface" PINerror
            proto_block_restart "$interface"
            return 1
            ;;
    esac

# Enable flightmode
    atOut=$(COMMAND='AT+CFUN=0' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    conStatus=offline

# Get modem manufactor and model
    atOut=$(COMMAND='ATI' gcom -d "$device" -s /etc/gcom/getrun_at.gcom)
    manufactor=$(echo "$atOut" | grep Manufacturer | awk -F ':' '{print $2}' | sed -e 's/\r//g')
    manufactor=${manufactor:1}
    model=$(echo "$atOut" | grep Model | awk -F ':' '{print $2}' | sed -e 's/\r//g')
    model=${model:1}
    fw=$(echo "$atOut" | grep Revision | awk -F ':' '{print $2}' | sed -e 's/\r//g')
    fw=${fw:1}
    [ "$atc_debug" -gt 1 ] && {
        echo $manufactor
        echo $model
        echo $fw
    }
    [ "$manufactor" = 'Huawei Technologies Co., Ltd.' -a "$model" = ME909s-120 ] || {
        echo 'Modem: '$manufactor' - '$model
        echo 'Wrong script. This is optimized for: Huawei Technologies Co., Ltd. - ME909s-120'
        proto_notify_error "$interface" MODEM
        proto_block_restart "$interface"
    }
    echo Configure modem

# URC
# Disable unsolicted indications
    atOut=$(COMMAND='AT^CURC=0' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut

# URC +CREG, +CGREG and +CEREG
    atOut=$(COMMAND='AT+CREG=0' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT+CGREG=2' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT+CEREG=2' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    
# Configure PDPcontext, profile 0 and 1
    atOut=$(COMMAND='AT+CGDCONT=0,"'$pdp'","'$apn'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT+CGDCONT=1,"'$pdp'","'$apn'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut

# Configure authentication, user and password, profile 0 and 1
    atOut=$(COMMAND='AT^AUTHDATA=0,$auth,,"'$username'","'$password'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT^AUTHDATA=1,$auth,,"'$username'","'$password'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut

# SMS config
    atOut=$(COMMAND='AT+CMGF=1' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT+CSCS="UCS2"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut
    atOut=$(COMMAND='AT+CNMI=2,1' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != 'OK' ] && echo $atOut

# Disable flightmode
    echo Activate modem
    COMMAND='AT+CFUN=1' gcom -d "$device" -s /etc/gcom/at.gcom
    
    while read URCline
    do
        firstASCII=$(printf "%d" \'${URCline::1})
        if [ ${firstASCII} != 13 ] && [ ${firstASCII} != 32 ] && [ ${#URCline} -gt 1 ]
        then
            URCcommand=$(echo $URCline | awk -F ':' '{print $1}')
            URCcommand=$(echo $URCcommand | sed -e 's/[\r\n]//g')
            x=${#URCcommand}
            x=$(($x+1))
            URCvalue=${URCline:x}
            [ "${URCvalue::1}" = ' ' ] && URCvalue=${URCvalue:1}
            URCvalue=$(echo $URCvalue | sed -e 's/"//g' | sed -e 's/[\r\n]//g')

            case $URCcommand in

                +CEREG|+CGREG )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    status=$(echo $URCvalue | awk -F ',' '{print $1}')
                    [ $URCcommand = '+CGREG' -a "$(echo $URCvalue | awk -F ',' '{print $4}')" = '7' ] && status=7
                    [ ${#URCvalue} -gt 6 ] && {
                        new_rat=$(echo $URCvalue | awk -F ',' '{print $4}')
                        new_rat=$(nb_rat $new_rat)
                    }
                    case $status in
                        0 )
                            echo ' '$conStatus' -> notRegistered'$(CxREG $URCvalue)
                            conStatus='notRegistered'
                            ;;
                        1 )
                            if [ "$conStatus" = 'registered' ]
                            then
                                [ "$atc_debug" -ge 1 ] && echo 'Cell change'$(CxREG $URCvalue)
                                [ "$new_rat" != "$rat" -a -n "$rat" ] && {
                                    echo 'RATchange: '$rat' -> '$new_rat
                                    rat=$new_rat
                                }
                            else
                                echo ' '$conStatus' -> registered - home network'$(CxREG $URCvalue)
                                conStatus='registered'
                                [ $re_connect -eq 1 ] && {
                                    pdp_still_active=0
                                    echo Activate session CEREG
#                                    COMMAND='AT^NDISDUP=1,1' gcom -d "$device" -s /etc/gcom/at.gcom
                                }
                            fi
                            ;;
                        2 )
                            echo ' '$conStatus' -> searching'$(CxREG $URCvalue)
                            conStatus='searching'
                            ;;
                        3 )
                            echo 'Registration denied, '$(CxREG $URCvalue)
                            proto_notify_error "$interface" REG_DENIED
                            proto_block_restart "$interface"
                            return 1
                            ;;
                        4 )
                            echo 'Unknown'
                            ;;
                        5 )
                            if [ "$conStatus" = 'registered' ]
                            then
                                [ "$atc_debug" -ge 1 ] && echo 'Cell change, '$(CxREG $URCvalue)
                                [ "$new_rat" != "$rat" -a -n "$rat" ] && {
                                    echo RATchange: $rat -> $new_rat
                                    rat=$new_rat
                                }
                            else
                                echo ' '$conStatus' -> registered - roaming'$(CxREG $URCvalue)
                                conStatus='registered'
                                [ $re_connect -eq 1 ] && {
                                    pdp_still_active=0
                                    echo Activate session CEREG
#                                    COMMAND='AT^NDISDUP=1,1' gcom -d "$device" -s /etc/gcom/at.gcom
                                }
                            fi
                            ;;
                        esac
                    ;;
                
                +COPS )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    cops_format=$(echo $URCvalue | awk -F ',' '{print $2}')
                    [ $cops_format -eq 0 ] && {
                        operator=$(echo $URCvalue | awk -F ',' '{print $3}' | sed -e 's/"//g')
                    }
                    [ $cops_format -eq 2 ] && {
                        plmn=$(echo $URCvalue | awk -F ',' '{print $3}' | sed -e 's/"//g')
                        rat=$(echo $URCvalue | awk -F ',' '{print $4}')
                        rat=$(nb_rat $rat)
                        echo 'Registered to '$operator' PLMN:'$plmn' on '$rat
                        echo Activate session
                        OK_received=1
                    }
                    ;;
                
                ^NWTIME )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    [ $re_connect -eq 0 ] && {
                        COMMAND='AT+COPS=3,0;+COPS?;+COPS=3,2;+COPS?' gcom -d "$device" -s /etc/gcom/at.gcom
                        re_connect=1
                    } || {
                        echo Activate session NWTIME
                        COMMAND='AT^NDISSTATQRY?' gcom -d "$device" -s /etc/gcom/at.gcom
                    }
                    ;;

                ^NDISSTAT )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    stat=$(echo $URCvalue | awk -F ',' '{print $1}')
                    err_code=$(echo $URCvalue | awk -F ',' '{print $2}')
                    pdp_type=$(echo $URCvalue | awk -F ',' '{print $4}')
                    [ "$stat" -eq 1 ] && {
                        COMMAND='AT+CGCONTRDP=1' gcom -d "$device" -s /etc/gcom/at.gcom
                    }
                    [ "$stat" -eq 0 ] && {
                        echo Session disconnected
                        release_interface
                    }
                    ;;

                ^NDISSTATQRY )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    stat=$(echo $URCvalue | awk -F ',' '{print $1}')
                    [ "$stat" -eq 0 ] && {
                        OK_received=1
                    }
                    ;;

                ^DHCP )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    v4address=$(hua_ip_hex2dec $(echo $URCvalue | awk -F ',' '{print $1}'))
                    v4netmask=$(hua_ip_hex2dec $(echo $URCvalue | awk -F ',' '{print $2}'))
                    v4gateway=$(hua_ip_hex2dec $(echo $URCvalue | awk -F ',' '{print $3}'))
                    v4dns1=$(hua_ip_hex2dec $(echo $URCvalue | awk -F ',' '{print $5}'))
                    v4dns2=$(hua_ip_hex2dec $(echo $URCvalue | awk -F ',' '{print $6}'))
                    OK_received=0
                    update_IPv4
                    ;;

                +CGCONTRDP )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    [ -z "$used_apn" ] && {
                        used_apn=$(echo $URCvalue | awk -F ',' '{print $3}')
                        used_apn=$(full_apn $used_apn)
                        [ "$apn" != $used_apn ] && echo 'Using network default APN: '$used_apn
                    }
                    OK_received=2
                    ;;

                +CGPADDR )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    IPaddress1=$(echo $URCvalue | awk -F ',' '{print $2}')
                    IPaddress2=$(echo $URCvalue | awk -F ',' '{print $3}')
                    [ $(IPversion $IPaddress1) = 'IPv4' ] && v4address=$IPaddress1
                    [ $(IPversion $IPaddress1) = 'IPv6' ] && v6address=$(IPv6_decTOhex $IPaddress1)
                    [ $(IPversion $IPaddress2) = 'IPv6' ] && {
                        v6address=$(IPv6_decTOhex $IPaddress2)
                        dual_stack=1
                    }
                    OK_received=3
                    [ $re_connect -eq 0 ] && re_connect=1
                    ;;

                '+CME ERROR' )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    [ $OK_received -eq 1 ] && {
                        echo 'Activate session failed, check your APN settings'
                        proto_notify_error "$interface" SESSION_FAILED
                        proto_block_restart "$interface"
                        return 1
                    }
                    ;;

                +CMTI )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    sms_index=$(echo $URCvalue | awk -F ',' '{print $2}')
                    COMMAND='AT+CMGR='$sms_index gcom -d "$device" -s /etc/gcom/at.gcom
                    ;;

                +CMGR )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    sms_sender=$(echo $URCvalue | awk -F ',' '{print $2}')
                    sms_sender=$(ucs2TOascii $sms_sender)
                    sms_date=$(echo $URCvalue | awk -F ',' -v OFS=',' '{print $4, $5}')
                    sms_date=$(echo $sms_date | awk -F '/' '{print $1 $2 $3}' | sed -e 's/,/_/g' | sed -e 's/://g')
                    sms_date=${sms_date:: -3}
                    OK_received=11
                    ;;

                ERROR )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    
                    ;;

                OK )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    [ $OK_received -eq 11 ] && {
                        COMMAND='AT+CMGD='$sms_index gcom -d "$device" -s /etc/gcom/at.gcom
                        OK_received=0
                    }
                    [ $OK_received -eq 3 ] && {
                        COMMAND='AT^DHCP?' gcom -d "$device" -s /etc/gcom/at.gcom
                    }
                    [ $OK_received -eq 2 ] && {
                        COMMAND='AT+CGPADDR=1' gcom -d "$device" -s /etc/gcom/at.gcom
                    }
                    [ $OK_received -eq 1 ] && {
                        OK_received=0
                        COMMAND='AT^NDISDUP=1,1' gcom -d "$device" -s /etc/gcom/at.gcom
                    }
                    ;;

                * )
                    [ "$atc_debug" -gt 1 ] && echo $URCline
                    [ $OK_received -eq 11 ] && {
                        echo $sms_date
                        sms_text=$URCline
                        sms_text=$(ucs2TOascii $sms_text)
                        echo 'SMS recieved from '$sms_sender
                        echo $sms_sender > $sms_rx_folder'/sms_'$sms_date
                        echo -e $sms_text >> $sms_rx_folder'/sms_'$sms_date
                        /usr/bin/atc_rx_sms.sh $sms_rx_folder'/sms_'$sms_date 2> /dev/null
                    }
                    ;;
            esac
        fi
    done < ${device}
}


proto_atc_teardown() {
#    local interface="$1"
#    local device=$(uci get network.${interface}.device)
#    local atOut
    echo $interface is disconnected
#    atOut=$(COMMAND='AT+CGACT=0,1' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    proto_init_update "*" 0
    proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol atc
}
