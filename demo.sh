#!/usr/bin/env bash

# RGB
CLOSING_METHOD="opret1st"
CONTRACT_DIR="contracts"
IFACE="RGB20"
RGB_WALLET_VER="0.11.0-beta.3"
TRANSFER_NUM=0

# wallet and network
DESCRIPTOR_WALLET_FEATURES="--features cli,hot"
RGB_WALLET_FEATURES="--all-features"
DESCRIPTOR_WALLET_VER="0.10.1"
OPRET_KEYCHAIN="<0;1;9>"
TAPRET_KEYCHAIN="<0;1;9;10>"
KEYCHAIN=$OPRET_KEYCHAIN
DER_SCHEME="bip84"
ESPLORA_ENDPOINT="http://localhost:8094/regtest/api"
NETWORK="regtest"
WALLETS=("issuer" "rcpt1" "rcpt2")
WALLET_PATH="wallets"

# maps
declare -A CONTRACT_MAP
declare -A DESC_MAP
declare -A WLT_ID_MAP
WLT_ID_MAP[${WALLETS[0]}]=0
WLT_ID_MAP[${WALLETS[1]}]=1
WLT_ID_MAP[${WALLETS[2]}]=2

# script
DEBUG=0
NAME=$(basename "$0")

# shell colors
C1='\033[0;32m' # green
C2='\033[0;33m' # orange
C3='\033[0;34m' # blue
C4='\033[0;31m' # red
NC='\033[0m'    # No Color


# utility functions
_die() {
    printf "\n${C4}ERROR: %s${NC}\n" "$@"
    exit 1
}

_log() {
    printf "${C3}%s${NC}\n" "$@"
}

_subtit() {
    printf "${C2} > %s${NC}\n" "$@"
}

_tit() {
    echo
    printf "${C1}==== %-20s ====${NC}\n" "$@"
}

_trace() {
    # note: calls redirecting stderr to /dev/null will drop xtrace output
    { local trace=0; } 2>/dev/null
    { [ -o xtrace ] && trace=1; } 2>/dev/null
    { [ $DEBUG = 1 ] && set -x; } 2>/dev/null
    "$@"
    { [ $trace == 0 ] && set +x; } 2>/dev/null
}

# internal functions
_gen_addr_rgb() {
    local wallet="$1"
    _log "generating new address for wallet \"$wallet\""
    local wallet_id=${WLT_ID_MAP[$wallet]}
    ADDR="$(_trace "${RGB[@]}" -d "data${wallet_id}" address -w "$wallet" 2>/dev/null \
        | awk '/bcrt/ {print $NF}')"
    _log "generated address: $ADDR"
}

_wait_esplora_sync() {
    echo -n "waiting for esplora to have synced"
    bitcoind_height=$("${BCLI[@]}" getblockcount)
    while :; do
        esplora_height=$(curl -s $ESPLORA_ENDPOINT/blocks/tip/height)
        [ "$bitcoind_height" == "$esplora_height" ] && break
        echo -n "."
        sleep 1
    done
    echo "synced"
}

_gen_blocks() {
    local count="$1"
    _log "mining $count block(s)"
    _trace "${BCLI[@]}" -rpcwallet=miner -generate "$count" >/dev/null
    _wait_esplora_sync
}

_gen_utxo() {
    local wallet="$1"
    _gen_addr_rgb "$wallet"
    _log "sending funds to wallet \"$wallet\""
    txid="$(_trace "${BCLI[@]}" -rpcwallet=miner sendtoaddress "$ADDR" 1)"
    _gen_blocks 1
    _sync_wallet "$wallet"
    _get_utxo "$wallet" "$txid"
}

_get_utxo() {
    local wallet="$1"
    local txid="$2"
    _log "extracting vout"
    local wallet_id=${WLT_ID_MAP[$wallet]}
    vout=$(_trace "${RGB[@]}" -d "data${wallet_id}" utxos -w "$wallet" 2>/dev/null \
        | awk "/$txid/ {print \$NF}" | cut -d: -f2)
    [ -n "$vout" ] || _die "couldn't retrieve vout for txid $txid"
    _log "txid $txid, vout: $vout"
}

_list_unspent() {
    local wallet="$1"
    local wallet_id=${WLT_ID_MAP[$wallet]}
    _trace "${RGB[@]}" -d "data${wallet_id}" utxos -w "$wallet" 2>/dev/null
}

_sync_wallet() {
    local wallet="$1"
    _log "syncing wallet $wallet"
    local wallet_id=${WLT_ID_MAP[$wallet]}
    _trace "${RGB[@]}" -d "data${wallet_id}" utxos -w "$wallet" --sync >/dev/null 2>&1
}

# main functions
check_balance() {
    local wallet="$1"
    local expected="$2"
    local contract_name="$3"
    _subtit "checking \"$contract_name\" balance for $wallet"
    local contract_id allocations amount wallet_id
    wallet_id=${WLT_ID_MAP[$wallet]}
    contract_id=${CONTRACT_MAP[$contract_name]}
    mapfile -t outpoints < <(_trace _list_unspent "$wallet" | awk '/:[0-9]+$/ {print $NF}')
    BALANCE=0
    if [ "${#outpoints[@]}" -gt 0 ]; then
        _log "outpoints:"
        for outpoint in "${outpoints[@]}"; do
            echo " - $outpoint"
        done
        mapfile -t allocations < <(_trace "${RGB[@]}" -d "data${wallet_id}" \
            state -w "$wallet" "$contract_id" $IFACE 2>/dev/null \
            | grep 'amount=' | awk -F',' '{print $1" "$2}')
        _log "allocations:"
        for allocation in "${allocations[@]}"; do
            echo " - $allocation"
        done
        for utxo in "${outpoints[@]}"; do
            for allocation in "${allocations[@]}"; do
                amount=$(echo "$allocation" \
                    | awk "/$utxo/ {print \$1}" | awk -F'=' '{print $2}')
                BALANCE=$((BALANCE + amount))
            done
        done
    fi
    if [ "$BALANCE" != "$expected" ]; then
        _die "$(printf '%s' \
            "balance \"$BALANCE\" for contract \"$contract_id\" " \
            "($contract_name) differs from the expected \"$expected\"")"
    fi
    _log "$(printf '%s' \
        "balance \"$BALANCE\" for contract \"$contract_id\" " \
        "($contract_name) matches the expected one")"
}

check_schemata_version() {
    if ! sha256sum -c --status rgb-schemata.sums; then
        _die "rgb-schemata version mismatch (hint: try \"git submodule update\")"
    fi
}

check_tools() {
    _subtit "checking required tools"
    local required_tools="base64 cargo cut docker grep head jq sha256sum"
    for tool in $required_tools; do
        if ! which "$tool" >/dev/null; then
            _die "could not find reruired tool \"$tool\", please install it and try again"
        fi
    done
    if ! docker compose >/dev/null; then
        _die "could not call docker compose (hint: install docker compose plugin)"
    fi
}

cleanup() {
    _subtit "stopping services and cleaning data directories"
    docker compose down
    rm -rf data{0,1,2,core,index}
}

export_asset() {
    local contract_name="$1"
    local contract_file contract_id wallet wallet_id
    contract_file=${CONTRACT_DIR}/${contract_name}.rgb
    contract_id=${CONTRACT_MAP[$contract_name]}
    wallet="issuer"
    wallet_id=${WLT_ID_MAP[$wallet]}
    _trace "${RGB[@]}" -d "data${wallet_id}" export -w "$wallet" "$contract_id" "$contract_file" 2>/dev/null
}

get_issue_utxo() {
    _subtit "creating issuance UTXO"
    [ $DEBUG = 1 ] && _log "unspents before issuance" && _list_unspent issuer
    _gen_utxo issuer
    TXID_ISSUE=$txid
    VOUT_ISSUE=$vout
}

import_asset() {
    local contract_name="$1"
    local wallet="$2"
    local contract_file wallet_id
    contract_file=${CONTRACT_DIR}/${contract_name}.rgb
    wallet_id=${WLT_ID_MAP[$wallet]}
    # note: all output to stderr
    _trace "${RGB[@]}" -d "data${wallet_id}" import -w "$wallet" "$contract_file" 2>&1 | grep Contract
}

issue_asset() {
    local contract_name="$1"
    _subtit "issuing asset \"$contract_name\""
    local contract_base contract_tmpl contract_yaml
    local contract_id issuance wallet wallet_id
    wallet="issuer"
    wallet_id=${WLT_ID_MAP[$wallet]}
    contract_base=${CONTRACT_DIR}/${contract_name}
    contract_tmpl=${contract_base}.yaml.template
    contract_yaml=${contract_base}.yaml
    sed \
        -e "s/issued_supply/2000/" \
        -e "s/created_timestamp/$(date +%s)/" \
        -e "s/closing_method/$CLOSING_METHOD/" \
        -e "s/txid/$TXID_ISSUE/" \
        -e "s/vout/$VOUT_ISSUE/" \
        "$contract_tmpl" > "$contract_yaml"
    issuance="$(_trace "${RGB[@]}" -d "data${wallet_id}" issue -w "$wallet" "$SCHEMA" "$contract_yaml" 2>&1)"
    contract_id="$(echo "$issuance" | grep '^A new contract' | cut -d' ' -f4)"
    CONTRACT_MAP[$contract_name]=$contract_id
    _log "contract ID: $contract_id"
    _log "contract state after issuance"
    _trace "${RGB[@]}" -d "data${wallet_id}" state -w "$wallet" "$contract_id" $IFACE
    [ $DEBUG = 1 ] && _log "unspents after issuance" && _list_unspent "$wallet" 2>/dev/null
}

install_rust_crate() {
    local crate="$1"
    local version="$2"
    if [ -n "$3" ]; then
        read -r -a features <<< "$3"
    fi
    if [ -n "$4" ]; then
        read -r -a opts <<< "$4"
    fi
    _subtit "installing $crate to ./$crate"
    cargo install "$crate" --version "$version" --locked \
        --root "./$crate" "${features[@]}" "${opts[@]}" \
        || _die "error installing $crate"
}

prepare_wallets() {
    _subtit "preparing wallets"
    _trace "${BCLI[@]}" createwallet miner >/dev/null
    _gen_blocks 103
    local descriptor
    mkdir -p $WALLET_PATH
    rm -rf $WALLET_PATH/*.seed $WALLET_PATH/*.derive
    for wallet in "${WALLETS[@]}"; do
        _log "creating wallet $wallet"
        _trace "${BTCHOT[@]}" seed -p '' "$WALLET_PATH/$wallet.seed" >/dev/null
        descriptor="$(_trace "${BTCHOT[@]}" derive \
            -s $DER_SCHEME --testnet --seed-password '' --account-password '' \
            "$WALLET_PATH/$wallet.seed" "$WALLET_PATH/$wallet.derive" \
            | tail -2 | head -1)"
        DESC_MAP[$wallet]="$(echo "$descriptor" \
            | sed -e 's/^.*(//' -e 's/).*$//' -e "s#/\*/#/$KEYCHAIN/#")"
        [ $DEBUG = 1 ] && echo "descriptor: ${DESC_MAP[$wallet]}"
    done
}

# shellcheck disable=2034
set_aliases() {
    _subtit "setting command aliases"
    BCLI=("docker" "compose" "exec" "-T" "esplora" "cli")
    BTCHOT=("descriptor-wallet/bin/btc-hot")
    BTCCOLD=("descriptor-wallet/bin/btc-cold")
    RGB=("rgb-wallet/bin/rgb" "-n" "$NETWORK" "-e" "$ESPLORA_ENDPOINT")
}

setup_rgb_clients() {
    _subtit "setting up RGB clients"
    local desc_opt interface_dir schemata_dir wallet wallet_id
    interface_dir="./rgb-schemata/interfaces"
    schemata_dir="./rgb-schemata/schemata"
    desc_opt="--wpkh"
    [ $CLOSING_METHOD = "tapret1st" ] && desc_opt="--tapret-key-only"
    for wallet in "${WALLETS[@]}"; do
        wallet_id=${WLT_ID_MAP[$wallet]}
        _trace "${RGB[@]}" -d "data${wallet_id}" create $desc_opt "${DESC_MAP[$wallet]}" "$wallet" 2>/dev/null
        _trace "${RGB[@]}" -d "data${wallet_id}" import -w "$wallet" $interface_dir/RGB20.rgb 2>/dev/null
        _trace "${RGB[@]}" -d "data${wallet_id}" import -w "$wallet" $schemata_dir/NonInflatableAssets.rgb 2>/dev/null
        _trace "${RGB[@]}" -d "data${wallet_id}" import -w "$wallet" $schemata_dir/NonInflatableAssets-RGB20.rgb 2>/dev/null
    done
    wallet="${WALLETS[0]}"
    wallet_id=${WLT_ID_MAP[$wallet]}
    SCHEMA="$(_trace "${RGB[@]}" -d "data${wallet_id}" schemata -w "$wallet" 2>/dev/null | awk '{print $1}')"
    _log "schema: $SCHEMA"
    [ $DEBUG = 1 ] && _trace "${RGB[@]}" -d "data${wallet_id}" interfaces -w issuer 2>/dev/null
}

start_services() {
    _subtit "checking data directories"
    for data_dir in data0 data1 data2; do
       if [ -d "$data_dir" ]; then
           if [ "$(stat -c %u $data_dir)" = "0" ]; then
               echo "existing data directory \"$data_dir\" found, owned by root"
               echo "please remove it and try again (e.g. 'sudo rm -r $data_dir')"
               _die "cannot continue"
           fi
           echo "existing data directory \"$data_dir\" found, removing"
           rm -r $data_dir
       fi
       mkdir -p "$data_dir"
    done
    _subtit "stopping services"
    docker compose down -v
    _subtit "checking bound ports"
    if ! which ss >/dev/null; then
        _log "ss not available, skipping bound ports check"
        return
    fi
    # see docker-compose.yml for the exposed ports
    EXPOSED_PORTS=(8094 50001)
    for port in "${EXPOSED_PORTS[@]}"; do
        if [ -n "$(ss -HOlnt "sport = :$port")" ];then
            _die "port $port is already bound, services can't be started"
        fi
    done
    _subtit "cleaning esplora data dir"
    if [ -d "dataesplora" ]; then
        docker compose run --rm esplora bash -c "rm -r /data/.bitcoin.conf /data/*"
    fi
    _subtit "starting services"
    docker compose up -d
    # wait for services to start
    until docker compose logs esplora |grep -q 'waiting for bitcoind sync to finish'; do
        sleep 1
    done
}

transfer_asset() {
    transfer_create "$@"    # parameter pass-through
    transfer_complete       # uses global variables set by transfer_create
    # unset global variables set by transfer operations
    unset BALANCE CONSIGNMENT NAME PSBT
    unset BLNC_RCPT BLNC_SEND RCPT_WLT SEND_WLT
}

transfer_create() {
    ## params
    local wallets="$1"          # sender>receiver wallet names
    local balances="$2"         # expected sender/recipient starting balances
    local send_amounts="$3"     # asset amount/change for the transfer
    local witness="$4"          # 1 for witness txid, blinded UTXO otherwise
    local reuse_invoice="$5"    # 1 to re-use the previous invoice
    NAME="${6:-"usdt"}"         # optional contract name (default: usdt)

    # increment transfer number
    TRANSFER_NUM=$((TRANSFER_NUM+1))

    ## data variables
    local contract_id rcpt_data rcpt_id send_data send_id
    local blnc_send blnc_rcpt send_amt send_chg
    SEND_WLT=$(echo "$wallets" |cut -d/ -f1)
    RCPT_WLT=$(echo "$wallets" |cut -d/ -f2)
    send_id=${WLT_ID_MAP[$SEND_WLT]}
    rcpt_id=${WLT_ID_MAP[$RCPT_WLT]}
    contract_id=${CONTRACT_MAP[$NAME]}
    send_data="data${send_id}"
    rcpt_data="data${rcpt_id}"
    send_amt=$(echo "$send_amounts" |cut -d/ -f1)
    send_chg=$(echo "$send_amounts" |cut -d/ -f2)
    blnc_send=$(echo "$balances" |cut -d/ -f1)
    blnc_rcpt=$(echo "$balances" |cut -d/ -f2)

    ## starting situation
    _log "spending $send_amt from $SEND_WLT with $send_chg change"
    [ $DEBUG = 1 ] && _log "sender unspents before transfer" && _list_unspent "$SEND_WLT"
    [ $DEBUG = 1 ] && _log "recipient unspents before transfer" && _list_unspent "$RCPT_WLT"
    _subtit "initial balances"
    check_balance "$SEND_WLT" "$blnc_send" "$NAME"
    check_balance "$RCPT_WLT" "$blnc_rcpt" "$NAME"
    BLNC_SEND=$((blnc_send-send_amt))
    BLNC_RCPT=$((blnc_rcpt+send_amt))
    [ "$BLNC_SEND" = "$send_chg" ] || \
        _die "expected final sender balance ($BLNC_SEND) differs from the provided one ($send_chg)"

    ## generate invoice
    _subtit "(recipient) preparing invoice for transfer n. $TRANSFER_NUM"
    local address_mode
    if [ "$reuse_invoice" != 1 ]; then
        if [ "$witness" = 1 ]; then
            address_mode="-a"
        else
            _gen_utxo "$RCPT_WLT"
            address_mode=""
        fi
            # not quoting $address_mode so it doesn't get passed as "" if empty
            # shellcheck disable=SC2086
            INVOICE="$(_trace "${RGB[@]}" -d "$rcpt_data" invoice \
                $address_mode \
                -w "$RCPT_WLT" "$contract_id" $IFACE "$send_amt" 2>/dev/null)"
    fi
    _log "invoice: $INVOICE"

    ## RGB tansfer
    _subtit "(sender) preparing RGB transfer"
    CONSIGNMENT="consignment_${TRANSFER_NUM}.rgb"
    PSBT=tx_${TRANSFER_NUM}.psbt
    _trace "${RGB[@]}" -d "$send_data" transfer -w "$SEND_WLT" \
        --method $CLOSING_METHOD \
        "$INVOICE" $send_data/$CONSIGNMENT $send_data/$PSBT \
        2>/dev/null
    if ! ls "$send_data/$CONSIGNMENT" >/dev/null 2>&1; then
        _die "could not locate consignment file: $send_data/$CONSIGNMENT"
    fi

    ## extract PSBT data
    local decoded_psbt
    decoded_psbt="$(_trace "${BCLI[@]}" decodepsbt "$(base64 -w0 $send_data/$PSBT)")"
    if [ $DEBUG = 1 ]; then
        _log "showing PSBT including RGB transfer data"
        echo "$decoded_psbt" | jq
    fi
    TXID_CHANGE="$(echo "$decoded_psbt" | jq -r '.tx |.txid')"
    # select vout which is not OP_RETURN (0) nor witness UTXO (AMT_RCPT)
    VOUT_CHANGE="$(echo "$decoded_psbt" | jq -r '.tx |.vout |.[] |select(.value > 0.001) |.n')"
    [ $DEBUG = 1 ] && _log "change outpoint: $TXID_CHANGE:$VOUT_CHANGE"

    ## copy generated consignment to recipient
    _subtit "(sender) copying consignment to recipient data directory"
    _trace cp {"$send_data","$rcpt_data"}/"$CONSIGNMENT"
    # inspect consignment (output to file as it's very big)
    _trace "${RGB[@]}" -d "$send_data" inspect -f debug \
        "$send_data/$CONSIGNMENT" 2>/dev/null > "$CONSIGNMENT.inspect"
    _log "consignment inspect logged to file: $CONSIGNMENT.inspect"
}

transfer_complete() {
    ## recipient: validate transfer
    _subtit "(recipient) validating consignment"
    local rcpt_data rcpt_id send_data send_id vldt
    send_id=${WLT_ID_MAP[$SEND_WLT]}
    rcpt_id=${WLT_ID_MAP[$RCPT_WLT]}
    send_data="data${send_id}"
    rcpt_data="data${rcpt_id}"
    # note: all output to stderr
    vldt="$(_trace "${RGB[@]}" -d "$rcpt_data" validate \
        "$rcpt_data/$CONSIGNMENT" 2>&1)"
    [ $DEBUG = 1 ] && _log "$vldt"
    if ! echo "$vldt" | grep -q 'The provided consignment is valid'; then
        _die "validation failed"
    fi

    ## sign + finalize + broadcast PSBT
    _subtit "(sender) signing PSBT"
    local signing tx txid
    signing="$(_trace "${BTCHOT[@]}" sign -p '' \
        $send_data/$PSBT "$WALLET_PATH/$SEND_WLT.derive")"
    if ! echo "$signing" | grep -q 'Done 1 signatures'; then
        _die "signing failed"
    fi
    _subtit "(sender) finalizing PSBT"
    tx="$(_trace "${BTCCOLD[@]}" finalize $send_data/$PSBT)"
    _subtit "(sender) broadcasting tx"
    txid="$(_trace "${BCLI[@]}" sendrawtransaction "$tx")"
    _log "$txid"

    ## mine and sync wallets
    _subtit "confirming transaction"
    _gen_blocks 1
    _subtit "syncing wallets"
    _sync_wallet "$SEND_WLT"
    _sync_wallet "$RCPT_WLT"

    ## accept transfer
    local accept
    _subtit "(recipient) accepting transfer"
    # note: all output to stderr
    accept="$(_trace "${RGB[@]}" -d "data${rcpt_id}" accept -w "$RCPT_WLT" \
        $rcpt_data/$CONSIGNMENT 2>&1)"
    [ $DEBUG = 1 ] && _log "$accept"
    if ! echo "$accept" | grep -q 'Transfer accepted into the stash'; then
        _die "accept failed"
    fi

    ## ending situation
    [ $DEBUG = 1 ] && _log "sender unspents after transfer" && _list_unspent "$SEND_WLT"
    [ $DEBUG = 1 ] && _log "recipient unspents after transfer" && _list_unspent "$RCPT_WLT"
    _subtit "final balances"
    check_balance "$SEND_WLT" "$BLNC_SEND" "$NAME"
    check_balance "$RCPT_WLT" "$BLNC_RCPT" "$NAME"
}

help() {
    echo "$NAME [-h|--help] [-t|--tapret] [-v|--verbose]"
    echo ""
    echo "options:"
    echo "    -h --help     show this help message"
    echo "    -t --tapret   user tapret1st closing method"
    echo "    -v --verbose  enable verbose output"
}


# cmdline arguments
while [ -n "$1" ]; do
    case $1 in
        -h|--help)
            help
            exit 0
            ;;
        -t|--tapret)
            CLOSING_METHOD="tapret1st"
            KEYCHAIN=$TAPRET_KEYCHAIN
            DER_SCHEME="bip86"
            ;;
        -v|--verbose)
            DEBUG=1
            ;;
        *)
            help
            _die "unsupported argument \"$1\""
            ;;
    esac
    shift
done

# initial setup
_tit "setting up"
check_tools
check_schemata_version
set_aliases
install_rust_crate "descriptor-wallet" "$DESCRIPTOR_WALLET_VER" "$DESCRIPTOR_WALLET_FEATURES" "--git https://github.com/BP-WG/descriptor-wallet --branch master --debug"
install_rust_crate "rgb-wallet" "$RGB_WALLET_VER" "$RGB_WALLET_FEATURES" "--git https://github.com/RGB-WG/rgb --branch v0.11"
#trap cleanup EXIT
start_services
prepare_wallets
setup_rgb_clients

# asset issuance
_tit "issuing assets"
get_issue_utxo
issue_asset "usdt"
issue_asset "other"
_tit "checking asset balances after issuance"
check_balance "issuer" "2000" "usdt"
check_balance "issuer" "2000" "other"

# export/import asset
_tit "exporting asset"
export_asset usdt
_tit "importing asset to recipient 1"
import_asset usdt rcpt1

# TODO: re-introduce aborted transfer + 2nd asset (blank)
# transfer loop:
#   1. issuer -> rcpt 1 (spend issuance)
#     1a. only initiate tranfer, don't complete (aborted transfer)
#     1b. retry transfer (re-using invoice) and complete it
#   2. check asset balances (blank)
#   3. issuer -> rcpt 1 (spend change, using witness vout)
#   4. rcpt 1 -> rcpt 2 (spend both received allocations)
#   5. rcpt 2 -> issuer (close loop)
#   6. issuer -> rcpt 1 (spend received back)
_tit "transferring asset from issuer to recipient 1 (spend issuance)"
transfer_asset issuer/rcpt1 2000/0 100/1900 0 0

_tit "checking issuer asset balances after the 1st transfer (blank transition)"
check_balance "issuer" "1900" "usdt"
check_balance "issuer" "2000" "other"

_tit "transferring asset from issuer to recipient 1 (spend change, using witness vout)"
transfer_asset issuer/rcpt1 1900/100 200/1700 1 0

_tit "transferring asset from recipient 1 to recipient 2 (spend received)"
transfer_asset rcpt1/rcpt2 300/0 150/150 0 0

_tit "transferring asset from recipient 2 to issuer (witness vout)"
transfer_asset rcpt2/issuer 150/1700 100/50 1 0

_tit "transferring asset from issuer to recipient 1 (spend received back)"
transfer_asset issuer/rcpt1 1800/150 50/1750 0 0

_tit "checking final asset balances"
check_balance "issuer" "1750" "usdt"
check_balance "rcpt1" "200" "usdt"
check_balance "rcpt2" "50" "usdt"
check_balance "issuer" "2000" "other"

_tit "sandbox run finished"
