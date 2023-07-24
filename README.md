RGB Sandbox
===

## Introduction
This is an RGB sandbox and demo based on RGB version 0.10.
It is based on the original rgb-node demo by [St333p] (version 0.1), [grunch]'s
[guide] and previous rgb-node sandbox versions.

The underlying Bitcoin network is `regtest`.

RGB is operated via the [rgb-contracts] crate.

[BDK] is used for walleting.

This sandbox can help explore RGB features in a self-contained environment
or can be used as a demo of the main RGB functionalities for fungible assets.

Two versions of the demo are available:
- an automated one
- a manual one

The automated version is meant to provide a quick and easy way to see an RGB
token be created and transferred. The manual version is meant to provide a
hands-on experience with an RGB token and gives step-by-step instructions on
how to operate all the required components.

Commands are to be executed in a bash shell. Example output is provided to
allow following the links between the steps. Actual output when executing the
procedure will be different each time.

## Setup
Clone the repository, including (shallow) submodules:
```sh
git clone https://github.com/RGB-Tools/rgb-sandbox --recurse-submodules --shallow-submodules
```

The default setup assumes the user and group IDs are `1000`. If that's not the
case, the `MYUID` and `MYGID` environment variables  in the
`docker-compose.yml` file need to be updated accordingly.

The automated demo does not require any other setup steps.

The manual version requires handling of data directories and services, see the
[dedicated section](#data-and-service-management) for instructions.

Both versions will leave `bdk-cli` and `rgb-contracts` installed, in the
respective directories under the project root. These directories can be safely
removed to start from scratch, doing so will just require the rust crates to be
re-installed on the next run.

### Requirements
- [git]
- [cargo]
- [docker]
- [docker compose]

## Sandbox exploration
The services started with docker compose simulate a small network with a
bitcoin node and an explorer. These can be used to support testing and
exploring the basic functionality of an RGB ecosystem.

Check out the manual demo below to get started with example commands. Refer to
each command's help documentation for additional information.

## Automated demo
To check out the automated demo, run:
```sh
bash demo.sh
```

The automated script will install the required rust crates, create empty
service data directories, start the required services, prepare the wallets,
issue assets, execute a series of asset transfers, the stop the services and
remove the data directories.

For more verbose output during the automated demo, add the `-v` option (`bash
demo.sh -v`), which shows the commands being run and additional
information (including output from additional inspection commands).

The script by default uses `opret1st` as closing method. The `tapret1st`
closing method can be selected via the `--tapret` command-line option (`bash
demo.sh --tapret`).

## Manual demo recording

Note: this has not yet been updated to the 0.10 version.

Following the manual demo and executing all the required steps is a rather long
and error-prone process.

To ease the task of following the steps, a recording of the manual demo
execution is available:
[![demo](https://asciinema.org/a/553660.svg)](https://asciinema.org/a/553660?autoplay=1)

## Manual demo

Note: this has not yet been updated to the 0.10 version.

The manual demo shows how to issue an asset and transfer some to a recipient.

At the beginning of the demo, some shell command aliases and common variables
need to be set, then a series of steps are briefly described and illustrated
with example shell commands.

During each step, commands either use literal values, ones that the user needs
to fill in or variables. Some variables will be the ones set at the beginning
of the demo (uppercase), others need to be set based on the output of the
commands as they are run (lowercase).

Values that need to be filled in with command output follow the command that
produces it and the example value is truncated (ends with `...`), meaning the
instruction should not be copied verbatim and the value should instead be
replaced with the actual output received while following the demo.

### Data and service management
Create data directories and start the required services in Docker containers:
```sh
# create data directories
mkdir data{0,1,core,index}

# start services (first time docker images need to be downloaded...)
docker compose up -d
```

To get a list of the running services you can run:
```sh
docker compose ps
```

To get their respective logs you can run, for instance:
```sh
docker compose logs bitcoind
```

Once finished and in order to clean up containers and data to start the demo
from scratch, run:
```sh
# stop services and remove containers
docker compose down

# remove data directories
rm -fr data{0,1,core,index}
```

### Premise
The rgb-contracts CLI tool does not handle wallet-related functionality, it
performs RGB-specific tasks over data that is provided by an external wallet,
such as BDK. In particular, in order to demonstrate a basic workflow with
issuance and transfer, from the bitcoin wallets we will need:
- an *outpoint_issue* to which the issuer will allocate the new asset
- an *outpoint_receive* where the recipient will receive the asset transfer
- an RGB *invoice* that will be generated using the *outpoint_receive*
- an *addr_change* where the sender will receive the bitcoin and asset change
- a partially signed bitcoin transaction (PSBT) that rgb-contracts will modify
  to anchor a commitment to the transfer

### bdk-cli installation
Wallets will be handled with BDK. We install its CLI to the `bdk-cli` directory
inside the project directory:
```sh
cargo install bdk-cli --version "0.27.1" --root "./bdk-cli" --features electrum
```

### rgb-contracts installation
RGB functionality will be handled with `rgb-contracts`. We install its CLI to
the `rgb-contracts` directory inside the project directory:
```sh
cargo install rgb-contracts --version "0.10.0-rc.3" --root "./rgb-contracts" --all-features
```

### Demo
#### Initial setup
We setup aliases to ease CLI calls:
```sh
alias bcli="docker compose exec -u blits bitcoind bitcoin-cli -regtest"
alias bdk="bdk-cli/bin/bdk-cli"
alias rgb0="rgb-contracts/bin/rgb -n regtest -d data0"
alias rgb1="rgb-contracts/bin/rgb -n regtest -d data1"
```

We set some environment variables:
```sh
CLOSING_METHOD="opret1st"
DERIVE_PATH="m/86'/1'/0'/9"
DESC_TYPE="wpkh"
ELECTRUM="localhost:50001"
ELECTRUM_DOCKER="electrs:50001"
CONSIGNMENT="consignment.rgb"
PSBT="tx.psbt"
IFACE="RGB20"
```
Note: to use "tapret" instead of "opret", change the following variables:
```sh
CLOSING_METHOD="tapret1st"
DERIVE_PATH="m/86'/1'/0'/10"
DESC_TYPE="tr"
```

We prepare the Bitcoin wallets using Bitcoin Core and BDK:
```sh
# Bitcoin Core wallet
bcli createwallet miner
bcli -generate 103

# if there are any bdk wallets from previous runs, they need to be removed
rm -fr ~/.bdk-bitcoin/{issuer,receiver}

# issuer/sender BDK wallet
bdk key generate
# example output:
# {
#   "fingerprint": "b51b4256",
#   "mnemonic": "human viable shoot chief argue crime initial kingdom country cool current search company sorry little memory picture illegal daring payment coral auction girl brief",
#   "xprv": "tprv8ZgxMBicQKsPdLooHXXyjcgK3BYKzfhycADzy1M7CmJiMPCoNZm23mhMMCJnzM5qLK52vtjS1NBKWS64AND2TmHRQdwWPfW7vPkiAoiozZS"
# }

xprv_0="tprv8Zgx..."

bdk key derive -p "$DERIVE_PATH" -x "$xprv_0"
# example output:
# {
#   "xprv": "[b51b4256/86'/1'/0'/9]tprv8j1dcDJVdU55xPP9hgR2fsHBJA2fSNzcrh7ZJL73SAoGWwFmjaZBc4DW6EwRcBvLKqFp64Dapsa8mh5DVgvUXjvXudFpA5Xc9dz4RmboCFf/*",
#   "xpub": "[b51b4256/86'/1'/0'/9]tpubDFhfkdLjmqkkqrQwbL5d5GwHsBYbbiBXRziLar9LrSbfMRWYMyNmnYqNGQ5EQRZM6B8hxUtBQiVXqbTbKGf4ZyHcyVhkdycSYdWPzZY8Z8Y/*"
# }

xprv_der_0="[b51b4256/86'/1'/0'/9]tprv8j1d..."
xpub_der_0="[b51b4256/86'/1'/0'/9]tpubDFhf..."

# receiver BDK wallet
bdk key generate
# example output:
# {
#   "fingerprint": "14eaf7ad",
#   "mnemonic": "obscure enforce east van family romance fashion disagree field lake hazard asset surge cigar north turn before lake team range effort choice mercy violin",
#   "xprv": "tprv8ZgxMBicQKsPegjdKUmwDcFhFnkmnZ8tiJLsJXqy87rymVzJMC6u3SvC9t4C1dEpybRkVoqqmpBrmEYTk3hg2nW7ftH3AuDsvp9Mw2tsw1D"
# }

xprv_1="tprv8Zgx..."

bdk key derive -p "$DERIVE_PATH" -x "$xprv_1"
# example output:
# {
#   "xprv": "[14eaf7ad/86'/1'/0'/9]tprv8iJE5PPQbmPkdKguvdRhKVG2KvV4eL2He6hMrDPCHA7kp6truUoGqkFS1FFYKHFAUEEREvuXuqQkrw7s8xzK61rDPnE8cUjqZKYsspLxFm1/*",
#   "xpub": "[14eaf7ad/86'/1'/0'/9]tpubDEzGDoRek95RWnihpH6Hitv8twzzofDCDQJ98jRVhRv9eb9dXscs2EsJBNa3UsZ4JvWhWUFAwFSmfKUsUboM5qDpgPRCXgP2MwRbgAyATcK/*"
# }

xprv_der_1="[14eaf7ad/86'/1'/0'/9]tprv8iJE..."
xpub_der_1="[14eaf7ad/86'/1'/0'/9]tpubDEzG..."

# generate addresses
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" get_new_address
# example output:
# {
#   "address": "bcrt1qcusj4weuh2kdlwrz2jn3sua3ctvfw84q305wpl"
# }

addr_issue="bcrt1qcu..."

bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" get_new_address
# example output:
{
  "address": "bcrt1q5mgt7tll7e8j9fr93l6wryex8drstvasz0wz4q"
}

addr_change="bcrt1q5m..."

bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" get_new_address
# example output:
# {
#   "address": "bcrt1qfg4kdxhzzny099rsw9sye3se3yh8g4lsmnqwg8"
# }

addr_receive="bcrt1qfg..."

# fund wallets
bcli -rpcwallet=miner sendtoaddress "$addr_issue" 1
bcli -rpcwallet=miner sendtoaddress "$addr_receive" 1
bcli -rpcwallet=miner -generate 1

# sync wallets
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" -s "$ELECTRUM" sync
bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" -s "$ELECTRUM" sync

# list wallet unspents to gather the outpoints
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" list_unspent
# example output:
# [
#   {
#     "is_spent": false,
#     "keychain": "External",
#     "outpoint": "3d19c1c9eaee04708eac80c821da2609ad5307e2d8310340e18323f1b7657e45:1",
#     "txout": {
#       "script_pubkey": "0014c7212abb3cbaacdfb86254a71873b1c2d8971ea0",
#       "value": 100000000
#     }
#   }
# ]

outpoint_issue="3d1...e45:1"

bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" list_unspent
# example output:
# [
#   {
#     "is_spent": false,
#     "keychain": "External",
#     "outpoint": "4be91b2b43b36ca2b430e415b7b7ec219d84262d10bddfc4e89577b2e47f6f19:1",
#     "txout": {
#       "script_pubkey": "00144a2b669ae214c8f2947071604cc619892e7457f0",
#       "value": 100000000
#     }
#   }
# ]

outpoint_receive="4be...f19:1"
```

We setup the RGB clients, importing schema and interface implementation:
```sh
# 1st client
rgb0 import rgb-schemata/schemata/NonInflatableAssets.rgb
# example output:
# Stock file not found, creating default stock
# Wallet file not found, creating new wallet list
# Schema urn:lnp-bp:sc:BEiLYE-am9WhTW1-oK8cpvw4-FEMtzMrf-mKocuGZn-qWK6YF#ginger-parking-nirvana imported to the stash

rgb0 import rgb-schemata/schemata/NonInflatableAssets-RGB20.rgb
# example output:
# Implementation urn:lnp-bp:im:9EUGHCwpuiyrQENdPBVyivVX4sVRBs9yKfteugHtqnGb#titanic-easy-citizen of interface urn:lnp-bp:if:48hc4im9JRcYQAuUSzwFCKVNEa9eZfnhepU8QJpqosXS#laptop-domingo-cool for schema urn:lnp-bp:sc:BEiLYE-am9WhTW1-oK8cpvw4-FEMtzMrf-mKocuGZn-qWK6YF#ginger-parking-nirvana imported to the stash

# 2nd client (same output as 1st client)
rgb1 import rgb-schemata/schemata/NonInflatableAssets.rgb
rgb1 import rgb-schemata/schemata/NonInflatableAssets-RGB20.rgb
```

We retrieve the schema ID and set it as environment variable:
```sh
rgb0 schemata
# example output:
# urn:lnp-bp:sc:BEiLYE-am9WhTW1-oK8cpvw4-FEMtzMrf-mKocuGZn-qWK6YF#ginger-parking-nirvana RGB20

schema="urn:lnp-bp:sc:BEiLYE-am...ing-nirvana"
```

#### Asset issuance
To issue an asset, we first need to prepare a contract definition file, then
use it to actually carry out the issuance.

To prepare the contract file, we copy the provided template and modify the copy
to set the required data:
- issued supply
- created timestamp
- closing method
- issuance txid and vout

We do this with the following command:
```sh
sed \
  -e "s/issued_supply/1000/" \
  -e "s/created_timestamp/$(date +%s)/" \
  -e "s/closing_method/$CLOSING_METHOD/" \
  -e "s/txid:vout/$outpoint_issue/" \
  contracts/usdt.yaml.template > contracts/usdt.yaml
```

To actually issue the asset, run:
```sh
rgb0 issue "$schema" "$IFACE" contracts/usdt.yaml
# example output:
# A new contract rgb:pueJTZ5-PA8DEMsVc-Bzv2PSgvZ-v7ANCbnRT-3wXADdPdx-vqXhvF is issued and added to the stash.
# Use `export` command to export the contract.

contract_id="rgb:AbX...pfW-yVdYUA"
```
This will create a new genesis that includes the asset metadata and the
allocation of the initial amount to the `outpoint_issue`.

You can list known contracts:
```sh
rgb0 contracts
```

You can show the current known state for the contract:
```sh
rgb0 state "$contract_id" "$IFACE"
```

#### Transfer

##### Receiver: generate invoice
In order to receive assets, the receiver needs to provide an invoice to the
sender. The receiver generates an invoice providing the amount to be received
(here `100`) and the outpoint where the assets should be allocated:
```sh
rgb1 invoice "$contract_id" "$IFACE" 100 "$CLOSING_METHOD:$outpoint_receive"
# example output:
# rgb:8Kdfa1Hkn4iXXstH3sCgUoF8YG9eeActB4CUmPmrfnW6/RGB20/100+utxob:rFNYJaK-AeZ7cqZ3q-EBS6bbs5P-wtPe1UR62-iEanYS7oK-yJyptk

invoice="rgb:8Kd...nW6/RGB20/100+utxob:rFN...ptk"
```
Note: this will blind the give outpoint and the invoice will contain a blinded
UTXO in place of the original outpoint (see the `utxob:` part of the invoice).

##### Sender: initiate asset transfer
To send assets, the sender needs to create a consignment and commit to it into
a bitcoin transaction. We need to create a PSBT and then modify to include the
commitment.

Note: when using `tapret1st` closing method, omit the `--add-string opret`
option from the following command, as it creates an `OP_RETURN` output, which
is only relveant for `opret1st`.

We create the PSBT, using `outpoint_issue` as input, `addr_change` for both the
RGB and BTC change:
```sh
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" create_tx \
  -f 5 --send_all --utxos "$outpoint_issue" --to "$addr_change:0" \
  --add_string opret
# example output:
# {
#   "details": {
#     "confirmation_time": null,
#     "fee": 630,
#     "received": 99999370,
#     "sent": 100000000,
#     "transaction": null,
#     "txid": "a5e76d98fa478df5fc49cefd6cd76a4fc054e0b68c05f2f354d42e69dca8250d"
#   },
#   "psbt": "cHNidP8BAGIBAAAAAUV+ZbfxI4PhQAMx2OIHU60JJtohyICsjnAE7urJwRk9AQAAAAD+////Aore9QUAAAAAFgAU8EYjxPkRxp7/IJ2G10cWuG6A4HYAAAAAAAAAAAdqBW9wcmV0aAAAAAABAN4CAAAAAAEBzY6/2OJDebRovPnxc6QBXQ/J/YRwKUYNYvYCMITuhOEAAAAAAP3///8C/AUQJAEAAAAWABRgbl32dLQ8x0BmTsae//hsWpra7QDh9QUAAAAAFgAUxyEquzy6rN+4YlSnGHOxwtiXHqACRzBEAiA9ZtRoxwKbwhlnjG/1alBD9S8Qq9Uga7VmFqorP3xLLQIgTCqx45odK/168XHD+6M6BYaV4wBe14s/opU1sDxnaP0BIQIKoXNhdryTuE5CNI8wyhwGM9nw6sWr3g8pn2p6sSzM9GcAAAABAR8A4fUFAAAAABYAFMchKrs8uqzfuGJUpxhzscLYlx6gIgYCjkwSayO2j7fPTJDtuTrHrfBcsCD73kIMPRu/BqRX3mcYtRtCVlYAAIABAACAAAAAgAkAAAAAAAAAACICAo00rXRVDgqaJlSwAKUlEe41HoTwVfYV0mvsXGtaPHWhGLUbQlZWAACAAQAAgAAAAIAJAAAAAQAAAAAA"
# }

echo "cHNidP8B..." | base64 -d > "data0/$PSBT"
```

We then modify the PSBT to set the commitment host:
```sh
rgb0 set-host --method "$CLOSING_METHOD" "data0/$PSBT"
# PSBT file 'data0/tx.psbt' is updated with opret1st host now set.
```

We generate the consignment, providing the PSBT and the invoice:
```sh
rgb0 transfer --method "$CLOSING_METHOD" "data0/$PSBT" "$invoice" "data0/$CONSIGNMENT"
# example output:
# Transfer is created and saved into 'data0/consignment.rgb'.
# PSBT file 'data0/tx.psbt' is updated with all required commitments and ready to be signed.
# Stash data are updated.
```

The consignment can be inspected, but since the output is very long it's best
output to a file:
```sh
rgb0 inspect "data0/$CONSIGNMENT" > consignment.inspect
```
To view the result, open the `consignment.inspect` file with a text editor.

##### Consignment exchange
For the purpose of this demo, copying the file over to the receiving node's
data directory is sufficient:
```sh
cp data{0,1}/"$CONSIGNMENT"
```

In real-world scenarios, consignments are exchanged either via [RGB HTTP
JSON-RPC] (e.g. using an [RGB proxy]) or other consignment exchange services.

##### Receiver: validate transfer
Before a transfer can be safely accepted, it needs to be validated:
```sh
rgb1 validate "data1/$CONSIGNMENT"
# example output:
# Consignment has non-mined terminal(s)
# Non-mined terminals:
# - 14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42
# Validation warnings:
# - terminal witness transaction 14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42 is not yet mined.
```

At this point it's normal that validation reports a warning about the witness
transaction not been mined, as the sender has not broadcast it yet. In a real-world scenario, the sender is waiting for approval from the receiver.

Now that validation passed, the receiver can approve the transfer. For this
demo let's just assume it happened, in a real-world scenario an [RGB proxy] can
be used.

##### Sender: sign and broadcast transaction
With the receiver's approval of the transfer, the transaction can be signed and
broadcast:
```sh
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xprv_der_0)" \
  sign --psbt $(base64 -w0 "data0/$PSBT")
# example output:
# {
#   "is_finalized": true,
#   "psbt": "cHNidP8BAH0BAAAAAUV+ZbfxI4PhQAMx2OIHU60JJtohyICsjnAE7urJwRk9AQAAAAD+////Aore9QUAAAAAFgAU8EYjxPkRxp7/IJ2G10cWuG6A4HYAAAAAAAAAACJqIPh1EJ54dEo/JX6K1pBozNwoAGaZR/voD9IRKHY6cSZyaAAAACb8A1JHQgGmhAHot8GqPrQq47n22SAAw6M24EXfpswPkK19FLHvV9YAAGzHuGQSrYE7Ev1xiZ8m4QipkglyvdTA2Vc1TOPGQ+vrECcAAAABbMe4ZBKtgTsS/XGJnybhCKmSCXK91MDZVzVM48ZD6+ugDwAAAAGgDwECAAMAAAAAAADaxFqeahDI7AiEAwAAAAAAAApsTppDR7hz/W3m48n18IPPi35EibFqc1raj0L1qwhvAm/St5+wlcX1eUb9tGbkn4GBOYS2vL2VyeoF9SfNS43ECGQAAAAAAAAAzvkoW1GuVoZZR5hp8nzezD31hXfs/YjE+Fn9BBx1Gv0AAAEA3gIAAAAAAQHNjr/Y4kN5tGi8+fFzpAFdD8n9hHApRg1i9gIwhO6E4QAAAAAA/f///wL8BRAkAQAAABYAFGBuXfZ0tDzHQGZOxp7/+GxamtrtAOH1BQAAAAAWABTHISq7PLqs37hiVKcYc7HC2JceoAJHMEQCID1m1GjHApvCGWeMb/VqUEP1LxCr1SBrtWYWqis/fEstAiBMKrHjmh0r/XrxccP7ozoFhpXjAF7Xiz+ilTWwPGdo/QEhAgqhc2F2vJO4TkI0jzDKHAYz2fDqxaveDymfanqxLMz0ZwAAAAEBHwDh9QUAAAAAFgAUxyEquzy6rN+4YlSnGHOxwtiXHqAiBgKOTBJrI7aPt89MkO25Oset8FywIPveQgw9G78GpFfeZxi1G0JWVgAAgAEAAIAAAACACQAAAAAAAAABBwABCGsCRzBEAiB3xA4eZ39rbRwZJ/EJXxhKlEFWSmoCMPW1uH9jaKP+lAIgUNazN8IA8Mli0UKTmsOsqmv1/m3MTjnbxQeeX+fni2wBIQKOTBJrI7aPt89MkO25Oset8FywIPveQgw9G78GpFfeZyb8A1JHQgNsx7hkEq2BOxL9cYmfJuEIqZIJcr3UwNlXNUzjxkPr6yCmhAHot8GqPrQq47n22SAAw6M24EXfpswPkK19FLHvVwAiAgKNNK10VQ4KmiZUsAClJRHuNR6E8FX2FdJr7FxrWjx1oRi1G0JWVgAAgAEAAIAAAACACQAAAAEAAAAAKfwGTE5QQlA0AGzHuGQSrYE7Ev1xiZ8m4QipkglyvdTA2Vc1TOPGQ+vrIBWtKLR9ET2WzLWuPZXpU0HTgh/1XbJv4qdKAFTZ6WuQCfwGTE5QQlA0AQi2Xx0RbbVYGgj8BU9QUkVUAAAI/AVPUFJFVAEg+HUQnnh0Sj8lforWkGjM3CgAZplH++gP0hEodjpxJnIA"
# }

psbt_signed="cHNidP8B..."

bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" -s "$ELECTRUM" \
    broadcast --psbt "$psbt_signed"
# example output:
# {
#   "txid": "14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42"
# }
```

##### Transaction confirmation
Now the transaction has been broadcast, let's confirm it:
```sh
bcli -rpcwallet=miner -generate 1
```

##### Receiver: accept transfer
Once the transaction has been confirmed, to complete the transfer and see the
new allocation in the contract state, the receiver needs to accept the
transfer:
```sh
rgb1 accept "data1/$CONSIGNMENT"
# example output:
# Consignment is valid
#
# Transfer accepted into the stash
```
Note that accepting a transfer first validates its consignment.

Let's see the contract state from the receiver point of view:
```sh
rgb1 state "$contract_id" "$IFACE"
# example output:
# Global:
#   spec := (naming=(ticker=("USDT"), name=("USD Tether"), details=~), precision=0)
#   data := (terms=("demo RGB20 asset"), media=~)
#   issuedSupply := (1000)
#   created := (1690379039)
#
# Owned:
#   assetOwner:
#     amount=1000, utxo=3d19c1c9eaee04708eac80c821da2609ad5307e2d8310340e18323f1b7657e45:1, witness=~ # owner unknown
#     amount=900, utxo=14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42:0, witness=14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42 # owner unknown
#     amount=100, utxo=4be91b2b43b36ca2b430e415b7b7ec219d84262d10bddfc4e89577b2e47f6f19:1, witness=14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42 # owner unknown
```
The original issuance the transfer allocations can be seen. The receiver can
recognize its allocation from the `utxo`, which corresponds to the
`outpoint_receive` provided when generating the invoice.

##### Sender: accept transfer
The sender doesn't need to explicitly accept the transfer, as it's automatically
been accepted when creating it.

The contract state already reflects the updates situation:
```sh
rgb0 state "$contract_id" "$IFACE"
# example output:
# Global:
#   spec := (naming=(ticker=("USDT"), name=("USD Tether"), details=~), precision=0)
#   data := (terms=("demo RGB20 asset"), media=~)
#   issuedSupply := (1000)
#   created := (1690379039)
#
# Owned:
#   assetOwner:
#     amount=1000, utxo=3d19c1c9eaee04708eac80c821da2609ad5307e2d8310340e18323f1b7657e45:1, witness=~ # owner unknown
#     amount=900, utxo=14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42:0, witness=14c6c910acc08299d5411525751971d8764e5285187353e31acb09097c351f42 # owner unknown
```

Since the `outpoint_receive` was blinded during invoice generation, the payer
has no information on where the asset was allocated by the transfer, so the
receiver's allocation is not visible in the contract state on the sender side.


[BDK]: https://github.com/bitcoindevkit/bdk-cli
[RGB HTTP JSON-RPC]: https://github.com/RGB-Tools/rgb-http-json-rpc
[RGB proxy]: https://github.com/grunch/rgb-proxy-server
[St333p]: https://github.com/St333p
[cargo]: https://github.com/rust-lang/cargo
[docker compose]: https://docs.docker.com/compose/install/
[docker]: https://docs.docker.com/get-docker/
[git]: https://git-scm.com/downloads
[grunch]: https://github.com/grunch
[guide]: https://grunch.dev/blog/rgbnode-tutorial/
[rgb-contracts]: https://github.com/RGB-WG/rgb
