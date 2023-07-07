#!/usr/bin/env bash

# closing method: Tapret (tapret1st) or OP_RETURN (opret1st)
CLOSING_METHOD="opret1st"

# wallet and network
BDK_CLI_VER="0.27.1"
RGB_CONTRACTS_VER="0.10.0-beta.2"
DERIVE_PATH="m/86'/1'/0'/9"
DESC_TYPE="wpkh"
ELECTRUM="localhost:50001"
NETWORK="regtest"
IFACE="RGB20"
CONTRACT_DIR="contracts"

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
    local required_tools="base64 cargo cut docker grep head jq ss"
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
        --git "https://github.com/RGB-WG/rgb" --branch "master" \
        --root ./$crate --all-features \
        || _die "error installing $crate"
}

cleanup() {
    docker compose down
    #rm -rf data{0,1,2,core,index}
}

setup_rgb_clients() {
    local data num schemata_dir
    data="data"
    schemata_dir="./rgb-schemata/schemata"
    for num in 0 1 2; do
        _trace "${RGB[@]}" -d ${data}${num} import $schemata_dir/NonInflatableAssets.rgb
        _trace "${RGB[@]}" -d ${data}${num} import $schemata_dir/NonInflatableAssets-RGB20.rgb
    done
    SCHEMA="$(_trace "${RGB[@]}" -d ${data}${num} schemata | awk '{print $1}')"
    _log "schema: $SCHEMA"
    [ "$DEBUG" != 0 ] && _trace "${RGB[@]}" -d ${data}${num} interfaces
}

start_services() {
    docker compose down
    # see docker-compose.yml for the exposed ports
    if [ -n "$(ss -HOlnt 'sport = :50001')" ];then
        _die "port 50001 is already bound, electrs service can't start"
    fi
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
        echo "xprv: ${!xprv_var}"
        echo "der_xprv: ${!der_xprv_var}"
        echo "der_xpub: ${!der_xpub_var}"
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

get_issue_utxo() {
    _subtit "creating issuance UTXO"
    _log "unspents before issuance" && list_unspent issuer
    gen_utxo issuer
    TXID_ISSUE=$txid
    VOUT_ISSUE=$vout
}

issue_asset() {
    local contract_base contract_tmpl contract_yaml
    local contract_id contract_name issuance
    contract_name="$1"
    _subtit "issuing asset \"$contract_name\""
    contract_base=${CONTRACT_DIR}/${contract_name}
    contract_tmpl=${contract_base}.yaml.template
    contract_yaml=${contract_base}.yaml
    cp "$contract_tmpl" "$contract_yaml"
    sed -i \
        -e "s/issued_supply/2000/" \
        -e "s/created_timestamp/$(date +%s)/" \
        -e "s/closing_method/$CLOSING_METHOD/" \
        -e "s/txid/$TXID_ISSUE/" \
        -e "s/vout/$VOUT_ISSUE/" \
        "$contract_yaml"
    issuance="$(_trace "${RGB[@]}" -d $DATA0 issue "$SCHEMA" $IFACE "$contract_yaml" 2>&1)"
    contract_id="$(echo "$issuance" | grep '^A new contract' | cut -d' ' -f4)"
    printf -v "CONTRACT_ID_$contract_name" '%s' "$contract_id"
    _log "contract ID: $contract_id"
    _log "contract state after issuance"
    _trace "${RGB[@]}" -d $DATA0 state "$contract_id" $IFACE
    [ "$DEBUG" != 0 ] && _log "unspents after issuance" && list_unspent issuer
    _wait_user
}

export_asset() {
    local contract_file contract_name
    contract_name="$1"
    contract_file=${CONTRACT_DIR}/${contract_name}.rgb
    contract_id="CONTRACT_ID_$contract_name"
    contract_id="${!contract_id}"
    _trace "${RGB[@]}" -d $DATA0 export "$contract_id" "$contract_file"
}

import_asset() {
    local contract_file contract_name id
    contract_name="$1"
    id="$2"
    contract_file=${CONTRACT_DIR}/${contract_name}.rgb
    _trace "${RGB[@]}" -d "data${id}" import "$contract_file"
}

check_balance() {
    local wallet num expected contract_name
    wallet="$1"
    id="$2"
    expected="$3"
    contract_name="$4"
    _subtit "checking \"$contract_name\" balance for $wallet"
    contract_id="CONTRACT_ID_$contract_name"
    contract_id="${!contract_id}"
    mapfile -t outpoints < <(_trace list_unspent "$wallet" | jq -r '.[] |.outpoint')
    BALANCE=0
    if [ "${#outpoints[@]}" -gt 0 ]; then
        _log "outpoints:"
        # shellcheck disable=2001
        echo -n "    " && echo "${outpoints[*]}" | sed 's/ /\n    /g'
        local allocations amount
        allocations=$(_trace "${RGB[@]}" -d "data${id}" state "$contract_id" $IFACE \
            | grep 'amount=' | awk -F',' '{print $1" "$2}')
        _log "allocations:"
        echo "$allocations"
        for utxo in "${outpoints[@]}"; do
            amount=$(echo "$allocations" \
                | grep "$utxo" | awk '{print $1}' | awk -F'=' '{print $2}')
            BALANCE=$((BALANCE + amount))
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

transfer_asset() {
    transfer_create "$@"    # parameter pass-through
    transfer_complete       # uses global variables set by transfer_create
    # unset global variables set by transfer operations
    unset BALANCE CONSIGNMENT DER_XPUB_VAR NAME PSBT
    unset BLNC_RCPT BLNC_SEND RCPT_ID RCPT_WLT SEND_ID SEND_WLT
}
transfer_create() {
    ## params
    SEND_WLT="$1"               # sender wallet name
    RCPT_WLT="$2"               # recipient wallet name
    SEND_ID="$3"                # sender id (for CLIs and data dir)
    RCPT_ID="$4"                # recipient id (for CLIs and data dir)
    local txid_send="$5"        # sender txid
    local vout_send="$6"        # sender vout
    local num="$7"              # transfer number
    local amt_send="$8"         # asset amount to send
    local amt_change="$9"       # asset amount to get back as change
    BLNC_SEND="${10}"           # expected sender starting balance
    BLNC_RCPT="${11}"           # expected recipient starting balance
    local witness="${12}"       # 0 for blinded UTXO, witness UTXO otherwise
    NAME="${13:-"usdt"}"        # optional contract name (default: usdt)
    local txid_send_2="${14}"   # optional sender txid n. 2
    local vout_send_2="${15}"   # optional sender vout n. 2

    ## data variables
    local contract_id rcpt_data send_data
    contract_id="CONTRACT_ID_$NAME"
    contract_id="${!contract_id}"
    send_data="data${SEND_ID}"
    rcpt_data="data${RCPT_ID}"

    ## starting situation
    _log "spending $amt_send from $txid_send:$vout_send ($SEND_WLT) with $amt_change change"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        _log "also using $txid_send_2:$vout_send_2 as input"
    fi
    _log "sender unspents before transfer" && list_unspent "$SEND_WLT"
    _log "recipient unspents before transfer" && list_unspent "$RCPT_WLT"
    _log "expected starting sender balance: $BLNC_SEND"
    _log "expected starting recipient balance: $BLNC_RCPT"
    _subtit "initial balances"
    check_balance "$SEND_WLT" "${SEND_ID}" "$BLNC_SEND" "$NAME"
    _log "sender balance: $BALANCE"
    check_balance "$RCPT_WLT" "${RCPT_ID}" "$BLNC_RCPT" "$NAME"
    _log "recipient balance: $BALANCE"
    _wait_user
    BLNC_SEND=$((BLNC_SEND-amt_send))
    BLNC_RCPT=$((BLNC_RCPT+amt_send))
    _log "expected final sender balance: $BLNC_SEND"
    _log "expected final recipient balance: $BLNC_RCPT"
    [ "$BLNC_SEND" = "$amt_change" ] || \
        _die "expected final sender balance ($BLNC_SEND) differs from the provided one ($amt_change)"

    ## generate invoice
    # generate UTXO
    _subtit "preparing receiver UTXO"
    gen_utxo "$RCPT_WLT"
    txid_rcpt=$txid
    vout_rcpt=$vout
    # generate invoice
    _subtit "generating invoice for transfer n. $num"
    local invoice
    invoice="$(_trace "${RGB[@]}" -d "$rcpt_data" invoice \
        "$contract_id" $IFACE "$amt_send" "$CLOSING_METHOD:$txid_rcpt:$vout_rcpt")"
    # replace invoice blinded UTXO with an address if witness UTXO is selected
    if [ "$witness" != 0 ]; then
        # generate address
        gen_addr_bdk "$RCPT_WLT"
        local addr_rcpt=$ADDR
        invoice="${invoice%+*}"         # drop +<blinded>
        invoice="${invoice}+$addr_rcpt" # add +<address>
    fi
    _log "invoice: $invoice"

    ## generate addresses to receive asset change and tx btc output
    _subtit "generating new address for issuer"
    local addr_send
    gen_addr_bdk "$SEND_WLT"
    addr_send=$ADDR

    ## prepare psbt
    _subtit "creating PSBT"
    [ "$DEBUG" != 0 ] && list_unspent "$SEND_WLT"
    local filter=".[] |select(.outpoint|contains(\"$txid_send\")) |.txout |.amount"
    local amnt amnt_2
    amnt="$(list_unspent "$SEND_WLT" | jq -r "$filter")"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        filter=".[] |select(.outpoint|contains(\"$txid_send_2\")) |.txout |.amount"
        amnt_2="$(list_unspent "$SEND_WLT" | jq -r "$filter")"
        amnt=$((amnt + amnt_2))
    fi
    PSBT=tx_${num}.psbt
    DER_XPUB_VAR="der_xpub_$SEND_WLT"
    local utxos=("$txid_send:$vout_send")
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        utxos+=("$txid_send_2:$vout_send_2")
    fi
    declare inputs=()
    for utxo in "${utxos[@]}"; do
        inputs+=("--utxos" "$utxo")
    done
    local psbt_to=(--send_all --to "$addr_send:0")
    if [ "$witness" != 0 ]; then
        # get unspent amount from input UTXOs + compute change amt
        local input_amt utxo_amt change_amt rcpt_amt fees
        fees=1000
        input_amt=0
        for utxo in "${utxos[@]}"; do
            local amt_filter=".[] |select(.outpoint == \"$utxo\") |.txout |.value"
            utxo_amt=$(list_unspent "$SEND_WLT" | jq -r "$amt_filter")
            input_amt=$((input_amt+utxo_amt))
        done
        rcpt_amt=5000
        change_amt=$((input_amt-rcpt_amt-fees))
        _log "input amount: $input_amt"
        # set outputs to change with computed amount + rcpt
        psbt_to=(--to "$addr_send:$change_amt" --to "$addr_rcpt:$rcpt_amt")
    fi
    [ "$CLOSING_METHOD" = "opret1st" ] && opret=("--add_string" "opret")
    _trace $BDKI -n $NETWORK wallet -w "$SEND_WLT" \
        -d "${DESC_TYPE}(${!DER_XPUB_VAR})" create_tx --enable_rbf \
        -f 5 "${inputs[@]}" "${psbt_to[@]}" "${opret[@]}" \
            | jq -r '.psbt' | base64 -d >"$send_data/$PSBT"

    ## set opret/tapret host
    _subtit "setting opret/tapret host in PSBT"
    _trace "${RGB[@]}" -d "$send_data" set-host --method $CLOSING_METHOD \
        "$send_data/$PSBT"

    ## RGB tansfer
    _subtit "preparing RGB transfer"
    CONSIGNMENT="consignment_${num}.rgb"
    _trace "${RGB[@]}" -d "$send_data" transfer --method $CLOSING_METHOD \
        "$send_data/$PSBT" "$invoice" "$send_data/$CONSIGNMENT"
    if ! ls "$send_data/$CONSIGNMENT" >/dev/null 2>&1; then
        _die "could not locate consignment file: $send_data/$CONSIGNMENT"
    fi

    ## show/extract psbt data
    local decoded_psbt
    decoded_psbt="$(_trace "${BCLI[@]}" decodepsbt "$(base64 -w0 "$send_data/$PSBT")")"
    if [ "$DEBUG" != 0 ]; then
        _log "showing psbt including RGB transfer data"
        echo "$decoded_psbt" | jq
    fi
    txid_change="$(echo "$decoded_psbt" | jq -r '.tx |.txid')"
    # select vout which is not OP_RETURN (0) nor witness UTXO (rcpt_amt)
    vout_change="$(echo "$decoded_psbt" | jq -r '.tx |.vout |.[] |select(.value > 0.001) |.n')"
    _log "change outpoint: $txid_change:$vout_change"

    ## inspect consignment (when in debug mode)
    _trace "${RGB[@]}" -d "$rcpt_data" inspect \
        "$send_data/$CONSIGNMENT" > "$send_data/$CONSIGNMENT.inspect"
    _log "consignment inspect logged to file: $send_data/$CONSIGNMENT.inspect"

    ## copy generated consignment to recipient
    _trace cp {"$send_data","$rcpt_data"}/"$CONSIGNMENT"
}

transfer_complete() {
    ## recipient: validate transfer
    _subtit "validating consignment"
    local rcpt_data send_data vldt
    send_data="data${SEND_ID}"
    rcpt_data="data${RCPT_ID}"
    vldt="$(_trace "${RGB[@]}" -d "$rcpt_data" validate \
        "$rcpt_data/$CONSIGNMENT" 2>&1)"
    _log "$vldt"
    if echo "$vldt" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi

    ## sign + finalize + broadcast psbt
    _subtit "signing and broadcasting tx"
    local der_xprv_var="der_xprv_$SEND_WLT"
    local psbt_finalized psbt_signed
    psbt_signed=$(_trace $BDKI -n $NETWORK wallet -w "$SEND_WLT" \
        -d "${DESC_TYPE}(${!der_xprv_var})" sign \
        --psbt "$(base64 -w0 "$send_data/$PSBT")")
    psbt_finalized=$(echo "$psbt_signed" \
        | jq -r 'select(.is_finalized = true) |.psbt')
    [ -n "$psbt_finalized" ] || _die "error signing or finalizing PSBT"
    echo "$psbt_finalized" \
        | base64 -d > "$send_data/finalized-bdk_${num}.psbt"
    _log "signed + finalized PSBT: $psbt_finalized"
    _trace $BDKI -n $NETWORK wallet -w "$SEND_WLT" \
        -d "${DESC_TYPE}(${!DER_XPUB_VAR})" -s $ELECTRUM broadcast \
        --psbt "$psbt_finalized"
    _subtit "mining a block"
    gen_blocks 1
    _subtit "syncing wallets"
    sync_wallet "$SEND_WLT"
    sync_wallet "$RCPT_WLT"
    _wait_user

    ## accept transfer (recipient + sender)
    local accept
    _subtit "accepting transfer (recipient)"
    accept="$(_trace "${RGB[@]}" -d "data${RCPT_ID}" accept \
        "$rcpt_data/$CONSIGNMENT" 2>&1)"
    _log "$accept"
    if echo "$accept" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi
    _subtit "accepting transfer (sender)"
    accept="$(_trace "${RGB[@]}" -d "$send_data" accept \
        "$send_data/$CONSIGNMENT" 2>&1)"
    _log "$accept"
    if echo "$accept" | grep -q 'Consignment is NOT valid'; then
        _die "validation failed"
    fi

    ## ending situation
    _log "sender unspents after transfer" && list_unspent "$SEND_WLT"
    _log "recipient unspents after transfer" && list_unspent "$RCPT_WLT"
    _subtit "final balances"
    check_balance "$SEND_WLT" "${SEND_ID}" "$BLNC_SEND" "$NAME"
    _log "sender balance: $BALANCE"
    check_balance "$RCPT_WLT" "${RCPT_ID}" "$BLNC_RCPT" "$NAME"
    _log "recipient balance: $BALANCE"
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

# wallet setup
_tit "preparing RGB clients"
setup_rgb_clients
_tit "preparing wallets"
prepare_wallets
gen_blocks 103

# asset issuance
_tit "issuing assets"
get_issue_utxo
issue_asset "usdt"
issue_asset "other"

# check balances
_tit "checking asset balances after issuance"
check_balance "issuer" "0" "2000" "usdt"
check_balance "issuer" "0" "2000" "other"

# export asset
_tit "exporting asset"
export_asset usdt

# import asset
_tit "importing asset to recipient 1"
import_asset usdt 1


# transfer loop:
#   1. issuer -> rcpt 1 (spend issuance)
#     1a. only initiate tranfer, don't complete (aborted transfer)
#     1b. restart transfer and complete it
#   2. check asset balances (blank)
#   3. issuer -> rcpt 1 (spend change)
#   4. rcpt 1 -> rcpt 2 (spend received)
#   5. rcpt 2 -> issuer (close loop)
#   6. issuer -> rcpt 1 (spend received back)
#   7. rcpt 1 -> rcpt 2 (WitnessUtxo)
_tit "creating transfer from issuer to recipient 1 (but not cmpleting it)"
transfer_create issuer rcpt1 0 1 "$TXID_ISSUE" "$VOUT_ISSUE" 1 100 1900 2000 0 0
_tit "transferring asset from issuer to recipient 1 (spend issuance)"
transfer_asset issuer rcpt1 0 1 "$TXID_ISSUE" "$VOUT_ISSUE" 1 100 1900 2000 0 0

_tit "checking issuer asset balances after the 1st transfer (blank transition)"
check_balance "issuer" "0" "1900" "usdt"
check_balance "issuer" "0" "2000" "other"

_tit "transferring asset from issuer to recipient 1 (spend change)"
transfer_asset issuer rcpt1 0 1 "$txid_change" "$vout_change" 2 200 1700 1900 100 0

_tit "transferring asset from recipient 1 to recipient 2 (spend received)"
transfer_asset rcpt1 rcpt2 1 2 "$txid_rcpt" "$vout_rcpt" 3 150 150 300 0 0

_tit "transferring asset from recipient 2 to issuer"
transfer_asset rcpt2 issuer 2 0 "$txid_rcpt" "$vout_rcpt" 4 100 50 150 1700 0

_tit "transferring asset from issuer to recipient 1 (spend received back)"
transfer_asset issuer rcpt1 0 1 "$txid_rcpt" "$vout_rcpt" 5 50 1750 1800 150 0

_tit "transferring asset from recipient 1 to recipient 2 (spend with witness UTXO)"
transfer_asset rcpt1 rcpt2 1 2 "$txid_rcpt" "$vout_rcpt" 6 40 160 200 50 1

_tit "checking final asset balances"
check_balance "issuer" "0" "1750" "usdt"
check_balance "rcpt1" "1" "160" "usdt"
check_balance "rcpt2" "2" "90" "usdt"
check_balance "issuer" "0" "2000" "other"

_tit "sandbox run finished"
