#!/usr/bin/env bash

# closing method: Tapret (tapret1st) or OP_RETURN (opret1st)
CLOSING_METHOD="opret1st"

# wallet and network
BDK_CLI_VER="0.27.1"
RGB_CONTRACTS_VER="0.10.0-beta.2"
DERIVE_PATH="m/86'/1'/0'/1"
DESC_TYPE="wpkh"
ELECTRUM="localhost:50001"
NETWORK="regtest"
IFACE="RGB20"
CONTRACT_FILE="contract/usdt.rgb"
CONTRACT_TMPL="contract/usdt_template.yaml"
CONTRACT_YAML="contract/usdt.yaml"

# output
DEBUG=0
INSPECT=0

# shell colors
C1='\033[0;32m' # green
C2='\033[0;33m' # orange
C3='\033[0;34m' # blue
C4='\033[0;31m' # red
NC='\033[0m'    # No Color

_die() {
    printf "\n${C4}ERROR: %s${NC}\n" "$@"
    exit 1
}

_tit() {
    echo
    printf "${C1}==== %-20s ====${NC}\n" "$@"
}

_subtit() {
    printf "${C2} > %s${NC}\n" "$@"
}

_log() {
    printf "${C3}%s${NC}\n" "$@"
}

_trace() {
    { local trace=0; } 2>/dev/null
    { [ -o xtrace ] && trace=1; } 2>/dev/null
    { [ "$DEBUG" != 0 ] && set -x; } 2>/dev/null
    "$@"
    { [ "$trace" == 0 ] && set +x; } 2>/dev/null
}

_wait_user() {
    if [ "$INSPECT" != 0 ]; then
        read -r -p "press any key to continue" -N 1 _
    fi
}

# shellcheck disable=2034
set_aliases() {
    BCLI=("docker" "compose" "exec" "-T" "-u" "blits" "bitcoind" "bitcoin-cli" "-$NETWORK")
    BDKI="bdk-cli/bin/bdk-cli"
    RGB=("rgb-contracts/bin/rgb" "-n" "$NETWORK")
    DATA0="data0"
    DATA1="data1"
    DATA2="data2"
}

check_tools() {
    local required_tools="base64 cargo cut docker grep head jq"
    for tool in $required_tools; do
        if ! which "$tool" >/dev/null; then
            _die "could not find reruired tool \"$tool\", please install it and try again"
        fi
    done
    if ! docker compose >/dev/null; then
        _die "could not call docker compose (hint: install docker compose plugin)"
    fi
}

check_dirs() {
    for data_dir in data0 data1 data2 datacore dataindex; do
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
}

install_bdk_cli() {
    local crate="bdk-cli"
    _log "installing $crate to ./$crate"
    cargo install bdk-cli --version $BDK_CLI_VER \
        --root ./$crate --features electrum \
        || _die "error installing $crate"
}

install_rgb_crates() {
    local crate="rgb-contracts"
    _log "installing $crate to ./$crate"
    cargo install rgb-contracts --version $RGB_CONTRACTS_VER \
        --debug \
        --git "https://github.com/nicbus/rgb" --branch "speed_fast" \
        --root ./$crate --all-features \
        || _die "error installing $crate"
}

cleanup() {
    docker compose down
    rm -rf data{0,1,2,core,index}
}

setup_rgb_clients() {
    local data num schemata_dir start end
    data="data"
    schemata_dir="./rgb-schemata/schemata"
    IMPORT_TIME=0
    for num in 0 1 2; do
        start=$(date +%s%3N)
        _trace "${RGB[@]}" -d ${data}${num} import ./rgb-schemata/interfaces/RGB20.rgb
        _trace "${RGB[@]}" -d ${data}${num} import $schemata_dir/NonInflatableAssets.rgb
        _trace "${RGB[@]}" -d ${data}${num} import $schemata_dir/NonInflatableAssets-RGB20.rgb
        end=$(date +%s%3N)
        IMPORT_TIME=$((IMPORT_TIME+(end-start)))
    done
    IMPORT_TIME=$((IMPORT_TIME/3))
    SCHEMA="$(_trace "${RGB[@]}" -d ${data}${num} schemata | awk '{print $1}')"
    _log "schema: $SCHEMA"
    _trace "${RGB[@]}" -d ${data}${num} interfaces
}

start_services() {
    docker compose down
    docker compose up -d
}

prepare_wallets() {
    _trace "${BCLI[@]}" createwallet miner >/dev/null
    for wallet in 'issuer' 'rcpt1' 'rcpt2'; do
        _log "generating new descriptors for wallet $wallet"
        rm -rf ~/.bdk-bitcoin/$wallet
        local xprv
        local der_xprv
        local der_xpub
        xprv="$(_trace $BDKI key generate | jq -r '.xprv')"
        der_xprv=$(_trace $BDKI key derive -p $DERIVE_PATH -x "$xprv" | jq -r '.xprv')
        der_xpub=$(_trace $BDKI key derive -p $DERIVE_PATH -x "$xprv" | jq -r '.xpub')
        printf -v "xprv_$wallet" '%s' "$xprv"
        printf -v "der_xprv_$wallet" '%s' "$der_xprv"
        printf -v "der_xpub_$wallet" '%s' "$der_xpub"
        local xprv_var="xprv_$wallet"
        local der_xprv_var="der_xprv_$wallet"
        local der_xpub_var="der_xpub_$wallet"
        _log "xprv: ${!xprv_var}"
        _log "der_xprv: ${!der_xprv_var}"
        _log "der_xpub: ${!der_xpub_var}"
    done
}

gen_blocks() {
    local count="$1"
    _log "mining $count block(s)"
    _trace "${BCLI[@]}" -rpcwallet=miner -generate "$count" >/dev/null
    sleep 1     # give electrs time to index
}

gen_addr_bdk() {
    local wallet="$1"
    _log "generating new address for wallet \"$wallet\""
    local der_xpub_var="der_xpub_$wallet"
    ADDR=$(_trace $BDKI -n $NETWORK wallet -w "$wallet" -d "${DESC_TYPE}(${!der_xpub_var})" \
        get_new_address | jq -r '.address')
    _log "generated address: $ADDR"
}

sync_wallet() {
    local wallet="$1"
    _log "syncing wallet $wallet"
    local der_xpub_var="der_xpub_$wallet"
    _trace $BDKI -n $NETWORK wallet -w "$wallet" \
        -d "${DESC_TYPE}(${!der_xpub_var})" -s $ELECTRUM sync
}

get_utxo() {
    local wallet="$1"
    local txid="$2"
    _log "extracting vout"
    local der_xpub_var="der_xpub_$wallet"
    local filter=".[] | .outpoint | select(contains(\"$txid\"))"
    vout=$(_trace $BDKI -n $NETWORK wallet -w "$wallet" -d "${DESC_TYPE}(${!der_xpub_var})" \
        list_unspent | jq -r "$filter" | cut -d: -f2)
    [ -n "$vout" ] || _die "couldn't retrieve vout for txid $txid"
    _log "txid $txid, vout: $vout"
}

gen_utxo() {
    local wallet="$1"
    local mode="bdk"
    [ "$wallet" = "miner" ] && mode="core"
    # generate an address
    gen_addr_$mode "$wallet"
    # send and mine
    _log "sending funds to wallet \"$wallet\""
    txid="$(_trace "${BCLI[@]}" -rpcwallet=miner sendtoaddress "$ADDR" 1)"
    gen_blocks 1
    sync_wallet "$wallet"
    get_utxo "$wallet" "$txid"
}

list_unspent() {
    local wallet="$1"
    local der_xpub_var="der_xpub_$wallet"
    _trace $BDKI -n $NETWORK wallet -w "$wallet" \
        -d "${DESC_TYPE}(${!der_xpub_var})" list_unspent
}

quit() {
    _tit "Timed operations:"
    _log "- rgb import avg time: $IMPORT_TIME ms"
    _log "- rgb issue time: $ISSUE_TIME ms"
    echo
    exit 2
}

issue_asset() {
    _log "unspents before issuance" && list_unspent issuer
    gen_utxo issuer
    txid_issue=$txid
    vout_issue=$vout
    _subtit 'issuing asset'
    cp $CONTRACT_TMPL $CONTRACT_YAML
    local start end
    start=$(date +%s%3N)
    _trace "${RGB[@]}" -d $DATA0 issue "$txid_issue:$vout_issue"
    end=$(date +%s%3N)
    ISSUE_TIME=$((end-start))
    CONTRACT_ID="$(_trace "${RGB[@]}" -d $DATA0 contracts | head -1)"
    _log "contract ID: $CONTRACT_ID"
    _log "contract state after issuance"
    _trace "${RGB[@]}" -d $DATA0 state "$CONTRACT_ID" $IFACE
    [ "$DEBUG" != 0 ] && _log "unspents after issuance" && list_unspent issuer
    _wait_user
}

export_asset() {
    _trace "${RGB[@]}" -d $DATA0 export "$CONTRACT_ID" $CONTRACT_FILE
}

import_asset() {
    local id="$1"
    _trace "${RGB[@]}" -d "data${id}" import $CONTRACT_FILE
}

check_balance() {
    local wallet num expected
    wallet="$1"
    id="$2"
    expected="$3"
    mapfile -t outpoints < <(_trace list_unspent "$wallet" | jq -r '.[] |.outpoint')
    balance=0
    if [ "${#outpoints[@]}" -gt 0 ]; then
        _log "outpoints: ${outpoints[*]}"
        local allocations amount
        allocations=$(_trace "${RGB[@]}" -d "data${id}" state "$CONTRACT_ID" $IFACE \
            | grep 'amount=' | awk -F',' '{print $1" "$2}')
        _log "wallet $wallet allocations:"
        echo "$allocations"
        for utxo in "${outpoints[@]}"; do
            amount=$(echo "$allocations" \
                | grep "$utxo" | awk '{print $1}' | awk -F'=' '{print $2}')
            balance=$((balance + amount))
        done
    fi
    if [ "$balance" != "$expected" ]; then
        _die "balance ($balance) differs from expected ($expected)"
    fi
}

transfer_asset() {
    ## params
    local send_wlt="$1"         # sender wallet name
    local rcpt_wlt="$2"         # recipient wallet name
    local send_id="$3"          # sender id (for CLIs and data dir)
    local rcpt_id="$4"          # recipient id (for CLIs and data dir)
    local txid_send="$5"        # sender txid
    local vout_send="$6"        # sender vout
    local num="$7"              # transfer number
    local amt_send="$8"         # asset amount to send
    local amt_change="$9"       # asset amount to get back as change
    local blnc_send="${10}"     # expected sender starting balance
    local blnc_rcpt="${11}"     # expected recipient starting balance
    local txid_send_2="${12}"   # sender txid n. 2
    local vout_send_2="${13}"   # sender vout n. 2

    ## data variables for sender and recipient
    local rcpt_data send_data
    send_data="data${send_id}"
    rcpt_data="data${rcpt_id}"

    ## starting situation
    _log "spending $amt_send from $txid_send:$vout_send ($send_wlt) with $amt_change change"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        _log "also using $txid_send_2:$vout_send_2 as input"
    fi
    _log "sender unspents before transfer" && list_unspent "$send_wlt"
    _log "recipient unspents before transfer" && list_unspent "$rcpt_wlt"
    _log "expected starting sender balance: $blnc_send"
    _log "expected starting recipient balance: $blnc_rcpt"
    _subtit "initial balances"
    check_balance "$send_wlt" "${send_id}" "$blnc_send"
    _log "sender balance: $balance"
    check_balance "$rcpt_wlt" "${rcpt_id}" "$blnc_rcpt"
    _log "recipient balance: $balance"
    _wait_user
    blnc_send=$((blnc_send-amt_send))
    blnc_rcpt=$((blnc_rcpt+amt_send))
    _log "expected final sender balance: $blnc_send"
    _log "expected final recipient balance: $blnc_rcpt"

    ## generate utxo to receive assets
    _subtit "preparing receiver UTXO"
    gen_utxo "$rcpt_wlt"
    txid_rcpt=$txid
    vout_rcpt=$vout

    ## generate invoice
    _subtit "generating invoice for transfer n. $num"
    local invoice
    invoice="$(_trace "${RGB[@]}" -d "data${rcpt_id}" invoice \
        "$CONTRACT_ID" $IFACE "$amt_send" "$CLOSING_METHOD:$txid_rcpt:$vout_rcpt")"
    _log "invoice: $invoice"

    ## generate addresses to receive asset change and tx btc output
    _subtit "generating new address for issuer"
    local addr_send
    gen_addr_bdk "$send_wlt"
    addr_send=$ADDR

    ## prepare psbt
    _subtit "creating PSBT"
    [ "$DEBUG" != 0 ] && list_unspent "$send_wlt"
    local filter=".[] |select(.outpoint|contains(\"$txid_send\")) |.txout |.amount"
    local amnt amnt_2
    amnt="$(list_unspent "$send_wlt" | jq -r "$filter")"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        filter=".[] |select(.outpoint|contains(\"$txid_send_2\")) |.txout |.amount"
        amnt_2="$(list_unspent "$send_wlt" | jq -r "$filter")"
        amnt=$((amnt + amnt_2))
    fi
    local psbt=tx_${num}.psbt
    local der_xpub_var="der_xpub_$send_wlt"
    local utxos=("$txid_send:$vout_send")
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        utxos+=("$txid_send_2:$vout_send_2")
    fi
    declare inputs=()
    for utxo in "${utxos[@]}"; do
        inputs+=("--utxos" "$utxo")
    done
    [ "$CLOSING_METHOD" = "opret1st" ] && opret=("--add_string" "opret")
    _trace $BDKI -n $NETWORK wallet -w "$send_wlt" \
        -d "${DESC_TYPE}(${!der_xpub_var})" create_tx --enable_rbf --send_all \
        -f 5 "${inputs[@]}" --to "$addr_send:0" "${opret[@]}" \
            | jq -r '.psbt' | base64 -d >"$send_data/$psbt"

    ## set opret/tapret host
    _subtit "setting opret/tapret host in PSBT"
    _trace "${RGB[@]}" -d "data${send_id}" set-host --method $CLOSING_METHOD \
        "$send_data/$psbt"

    ## RGB tansfer
    _subtit "preparing RGB transfer"
    local consignment="consignment_${num}.rgb"
    _trace "${RGB[@]}" -d "data${send_id}" transfer --method $CLOSING_METHOD \
        "$send_data/$psbt" "$invoice" "$send_data/$consignment"
    if ! ls "$send_data/$consignment" >/dev/null 2>&1; then
        _die "could not locate consignment file: $send_data/$consignment"
    fi

    ## show/extract psbt data
    local decoded_psbt
    decoded_psbt="$(_trace "${BCLI[@]}" decodepsbt "$(base64 -w0 "$send_data/$psbt")")"
    if [ "$DEBUG" != 0 ]; then
        _log "showing psbt including RGB transfer data"
        echo "$decoded_psbt" | jq
    fi
    txid_change="$(echo "$decoded_psbt" | jq -r '.tx |.txid')"
    vout_change="$(echo "$decoded_psbt" | jq -r '.tx |.vout |.[] |select(.value != 0) |.n')"
    _log "change outpoint: $txid_change:$vout_change"

    ## inspect consignment (when in debug mode)
    _trace "${RGB[@]}" -d "data${rcpt_id}" inspect \
        "$send_data/$consignment" > "$send_data/$consignment.inspect"
    _log "consignment inspect logged to file: $send_data/$consignment.inspect"

    ## copy generated consignment to recipient
    _trace cp {"$send_data","$rcpt_data"}/"$consignment"

    ## recipient: validate transfer
    _subtit "validating consignment"
    local vldt
    date
    vldt="$(_trace "${RGB[@]}" -d "data${rcpt_id}" validate \
        "$rcpt_data/$consignment" 2>&1)"
    _log "$vldt"
    date
    if echo "$vldt" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi

    ## sign + finalize + broadcast psbt
    _subtit "signing and broadcasting tx"
    local der_xprv_var="der_xprv_$send_wlt"
    local psbt_finalized psbt_signed
    psbt_signed=$(_trace $BDKI -n $NETWORK wallet -w "$send_wlt" \
        -d "${DESC_TYPE}(${!der_xprv_var})" sign \
        --psbt "$(base64 -w0 "$send_data/$psbt")")
    psbt_finalized=$(echo "$psbt_signed" \
        | jq -r 'select(.is_finalized = true) |.psbt')
    [ -n "$psbt_finalized" ] || _die "error signing or finalizing PSBT"
    echo "$psbt_finalized" \
        | base64 -d > "data${send_id}/finalized-bdk_${num}.psbt"
    _log "signed + finalized PSBT: $psbt_finalized"
    _trace $BDKI -n $NETWORK wallet -w "$send_wlt" \
        -d "${DESC_TYPE}(${!der_xpub_var})" -s $ELECTRUM broadcast \
        --psbt "$psbt_finalized"
    _subtit "mining a block"
    gen_blocks 1
    _subtit "syncing wallets"
    sync_wallet "$send_wlt"
    sync_wallet "$rcpt_wlt"
    _wait_user

    ## accept transfer (recipient + sender)
    local accept
    _subtit "accepting transfer (recipient)"
    accept="$(_trace "${RGB[@]}" -d "data${rcpt_id}" accept \
        "$rcpt_data/$consignment" 2>&1)"
    _log "$accept"
    if echo "$accept" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi
    _subtit "accepting transfer (sender)"
    accept="$(_trace "${RGB[@]}" -d "data${send_id}" accept \
        "$send_data/$consignment" 2>&1)"
    _log "$accept"
    if echo "$accept" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi

    ## ending situation
    _log "sender unspents after transfer" && list_unspent "$send_wlt"
    _log "recipient unspents after transfer" && list_unspent "$rcpt_wlt"
    _subtit "final balances"
    check_balance "$send_wlt" "${send_id}" "$blnc_send"
    _log "sender balance: $balance"
    check_balance "$rcpt_wlt" "${rcpt_id}" "$blnc_rcpt"
    _log "recipient balance: $balance"
    _wait_user
}

# cmdline arguments
while [ -n "$1" ]; do
    case $1 in
        tapret1st)
            _log "setting tapret close method"
            CLOSING_METHOD="tapret1st"
            ;;
        opret1st)
            _log "setting opret close method"
            CLOSING_METHOD="opret1st"
            ;;
        wpkh)
            _log "setting wpkh descriptor type"
            DESC_TYPE="wpkh"
            ;;
        tr)
            _log "setting tr descriptor type"
            DESC_TYPE="tr"
            ;;
        "-i")
            _log "enabling pauses for output user inspection"
            INSPECT=1
            ;;
        "-v")
            _log "enabling debug output"
            DEBUG=1
            ;;
        *)
            _die "unsupported argument \"$1\""
            ;;
    esac
    shift
done

# initial setup
check_tools
set_aliases
_tit "installing bdk-cli"
install_bdk_cli
install_rgb_crates
trap cleanup EXIT
_tit "starting services"
check_dirs
start_services
setup_rgb_clients

# wallet setup
_tit "preparing wallets"
prepare_wallets
gen_blocks 103

# asset issuance
_tit "issuing \"USDT\" asset"
issue_asset
quit

# import asset
_tit "exporting asset"
export_asset

# import asset
_tit "importing asset to recipient 1"
import_asset 1


## transfer loop: issuer -> rcpt 1 -> issuer -> rcpt 2
#_tit "transferring asset from issuer to recipient 1"
#transfer_asset issuer rcpt1 0 1 "$txid_issue" "$vout_issue" 1 2000 0 2000 0
#
#_tit "transferring asset from recipient 1 back to issuer"
#transfer_asset rcpt1 issuer 1 0 "$txid_rcpt" "$vout_rcpt" 2 2000 0 2000 0
#
#_tit "transferring asset from issuer to recipient 2 (2nd send for issuer)"
#transfer_asset issuer rcpt2 0 2 "$txid_rcpt" "$vout_rcpt" 3 2000 0 2000 0
#
#_tit "transferring asset from recipient 2 to issuer (spend output of previous transfer)"
#transfer_asset rcpt2 issuer 2 0 "$txid_rcpt" "$vout_rcpt" 4 2000 0 2000 0


## transfer loop with change spending
_tit "transferring asset from issuer to recipient 1 (spend issuance)"
transfer_asset issuer rcpt1 0 1 "$txid_issue" "$vout_issue" 1 100 1900 2000 0

_tit "transferring asset from issuer to recipient 1 (spending change)"
transfer_asset issuer rcpt1 0 1 "$txid_change" "$vout_change" 2 200 1700 1900 100

_tit "transferring asset from recipient 1 to recipient 2 (spend received)"
transfer_asset rcpt1 rcpt2 1 2 "$txid_rcpt" "$vout_rcpt" 3 150 150 300 0

_tit "transferring asset from recipient 2 to issuer"
transfer_asset rcpt2 issuer 2 0 "$txid_rcpt" "$vout_rcpt" 4 100 50 150 1700

_tit "transferring asset from issuer to recipient 1 (spend received back)"
transfer_asset issuer rcpt2 0 2 "$txid_rcpt" "$vout_rcpt" 5 50 1750 1800 50
