#!/bin/bash

set -o errexit
set -o xtrace
PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export TOP=${PROJECT_DIR}/config
export PolyjuiceDir=${PROJECT_DIR}/godwoken-examples
export LUMOS_CONFIG_FILE=${PROJECT_DIR}/config/lumos-config.json
export PRIVKEY=deploy/private_key
export ckb_rpc=http://ckb:8114
export DATABASE_URL=postgres://user:password@postgres:5432/lumos

# import some helper function
source ${PROJECT_DIR}/gw_util.sh


# wait for polyjuice complete preparing money before godwoken deployment, avoiding cell comsuming conflict.
cd $PolyjuiceDir
yarn workspace @godwoken-examples/runner clean:temp
yarn prepare-money
cd ../../

# wait for godwoken-examples deploy layer1 sudt script before starting godwoken
cd $PolyjuiceDir
yarn workspace @godwoken-examples/runner clean
yarn prepare-sudt
cd ../../

# update l1_sudt_script_hash in config.toml file(if it exits) with lumos script.sudt.code_hash
codeHash=$(get_sudt_code_hash_from_lumos_file "${PROJECT_DIR}/godwoken-examples/packages/runner/configs/lumos-config.json")
set_key_value_in_toml "l1_sudt_script_type_hash" $codeHash "${PROJECT_DIR}/godwoken/config.toml"

# ready to start godwoken

# first, start ckb-indexer
# todo: should remove to another service. but the port mapping some how not working.
RUST_LOG=error ${PROJECT_DIR}/indexer-data/ckb-indexer -s ${PROJECT_DIR}/indexer-data/ckb-indexer-data -c ${ckb_rpc} > ${PROJECT_DIR}/indexer-data/indexer-log & 
 
# detect which mode to start godwoken
GODWOKEN_CONFIG_FILE=${PROJECT_DIR}/godwoken/config.toml

if test -f "$GODWOKEN_CONFIG_FILE"; then
  if [ "$FORCH_GODWOKEN_REDEPLOY" = true ]; then
    echo "godwoken config.toml exists, but force_godwoken_redeploy is enabled, so use fat mode."
    # fat start, re-deploy godwoken chain 
    export START_MODE="fat_start" 
  else
    echo "godwoken config.toml exists. try search rollup cell.."
    if isRollupCellExits "${GODWOKEN_CONFIG_FILE}";
    then
      # slim start, just start godwoken, no re-deploy scripts
       export START_MODE="slim_start" 
    else
      # fat start, re-deploy godwoken chain 
      export START_MODE="fat_start"
    fi
  fi
else 
  export START_MODE="fat_start"
fi


if [ $START_MODE = "slim_start" ]; then
  cd ${PROJECT_DIR}/godwoken
  #cargo run --bin godwoken
  RUST_LOG=gw_block_producer=info,gw_generator=debug ./target/debug/godwoken
else
  echo 'run deploy mode'
fi


# wait for suffice fund to deploy godwoken scripts
while true; do
    sleep 3;
    MINER_BALANCE=$(ckb-cli --url ${ckb_rpc} wallet get-capacity --wait-for-sync --address ckt1qyqy84gfm9ljvqr69p0njfqullx5zy2hr9kq0pd3n5)
    TOTAL="${MINER_BALANCE##immature*:}"
    TOTAL="${TOTAL##total: }"
    TOTAL=" ${TOTAL%%.*} "
    if [[ "$TOTAL" -gt 1000 ]]; then
      echo 'fund suffice, ready to deploy godwoken script.'
      break
    else
      echo 'fund unsuffice ${TOTAL}, keep waitting.'
    fi
done

echo 'this may takes a little bit of time, please wait...'

# deploy scripts
cd ${PROJECT_DIR}/godwoken
./target/debug/gw-tools deploy-scripts -r ${ckb_rpc} -i deploy/scripts-deploy.json -o deploy/scripts-deploy-result.json -k ${PRIVKEY}
#cargo run --bin gw-tools deploy-scripts -r ${ckb_rpc} -i deploy/scripts-deploy.json -o deploy/scripts-deploy-result.json -k ${PRIVKEY}

# deploy genesis block
./target/debug/gw-tools deploy-genesis -r ${ckb_rpc} -d deploy/scripts-deploy-result.json -p deploy/poa-config.json -u deploy/rollup-config.json -o deploy/genesis-deploy-result.json -k ${PRIVKEY}
#cargo run --bin gw-tools deploy-genesis -r ${ckb_rpc} -d deploy/scripts-deploy-result.json -p deploy/poa-config.json -u deploy/rollup-config.json -o deploy/genesis-deploy-result.json -k ${PRIVKEY}

# copy polyjuice build file
# todo: We should use real validator in the later version
cp ${PROJECT_DIR}/godwoken-polyjuice/build/generator ${PROJECT_DIR}/godwoken/deploy/polyjuice-generator
cp scripts/release/always-success ${PROJECT_DIR}/godwoken/deploy/polyjuice-validator
#cp ${PROJECT_DIR}/godwoken-polyjuice/build/validator ${PROJECT_DIR}/godwoken/deploy/polyjuice-validator

# generate config file
./target/debug/gw-tools generate-config -d ${DATABASE_URL} -r ${ckb_rpc} -g deploy/genesis-deploy-result.json -s deploy/scripts-deploy-result.json -p deploy -o config.toml
#cargo run --bin gw-tools generate-config -r ${ckb_rpc} -g deploy/genesis-deploy-result.json -s deploy/scripts-deploy-result.json -p deploy -o config.toml

# Update block_producer.wallet_config section to your own lock.
cp ${PROJECT_DIR}/config/edit_godwoken_config.sh edit_godwoken_config.sh
./edit_godwoken_config.sh
rm edit_godwoken_config.sh 

# update l1_sudt_script_hash in config.toml file(if it exits) with lumos script.sudt.code_hash
codeHash=$(get_sudt_code_hash_from_lumos_file "${PROJECT_DIR}/godwoken-examples/packages/runner/configs/lumos-config.json")
set_key_value_in_toml "l1_sudt_script_type_hash" $codeHash "${PROJECT_DIR}/godwoken/config.toml"

# prepare runner config file for polyjuice
cp ${PROJECT_DIR}/godwoken/deploy/scripts-deploy-result.json ${PROJECT_DIR}/godwoken-examples/packages/runner/configs/scripts-deploy-result.json
cp ${PROJECT_DIR}/godwoken/config.toml ${PROJECT_DIR}/godwoken-examples/packages/runner/configs/config.toml
# generate godwoken config file for polyjuice
cd ${PROJECT_DIR}/godwoken-examples && yarn gen-config && cd ${PROJECT_DIR}/godwoken 

# start godwoken
RUST_LOG=gw_block_producer=info,gw_generator=debug ./target/debug/godwoken
#cargo run --bin godwoken