//! Test call selfdestruct from a contract account
//!   See ./evm-contracts/SelfDestruct.sol

use crate::helper::{
    account_id_to_eth_address, deploy, new_account_script, new_account_script_with_nonce,
    new_block_info, setup, PolyjuiceArgsBuilder, CKB_SUDT_ACCOUNT_ID,
};
use gw_common::state::State;
use gw_generator::traits::StateExt;
use gw_types::{bytes::Bytes, packed::RawL2Transaction, prelude::*};

const SD_INIT_CODE: &str = include_str!("./evm-contracts/SelfDestruct.bin");
const INIT_CODE: &str = include_str!("./evm-contracts/CallSelfDestruct.bin");

#[test]
fn test_selfdestruct() {
    let (mut tree, generator, creator_account_id) = setup();

    let from_script = gw_generator::sudt::build_l2_sudt_script([1u8; 32].into());
    let from_id = tree.create_account_from_script(from_script).unwrap();
    tree.mint_sudt(CKB_SUDT_ACCOUNT_ID, from_id, 400000)
        .unwrap();
    let mut block_number = 1;

    let beneficiary_script = gw_generator::sudt::build_l2_sudt_script([2u8; 32].into());
    let beneficiary_id = tree.create_account_from_script(beneficiary_script).unwrap();
    assert_eq!(
        tree.get_sudt_balance(CKB_SUDT_ACCOUNT_ID, beneficiary_id)
            .unwrap(),
        0
    );

    let input = format!(
        "{}{}",
        SD_INIT_CODE,
        hex::encode(account_id_to_eth_address(beneficiary_id, true))
    );
    let run_result = deploy(
        &generator,
        &mut tree,
        creator_account_id,
        from_id,
        input.as_str(),
        122000,
        200,
        block_number,
    );
    block_number += 1;
    let sd_account_script = new_account_script_with_nonce(from_id, 0);
    let sd_account_id = tree
        .get_account_id_by_script_hash(&sd_account_script.hash().into())
        .unwrap()
        .unwrap();
    assert_eq!(
        tree.get_sudt_balance(CKB_SUDT_ACCOUNT_ID, sd_account_id)
            .unwrap(),
        200
    );
    assert_eq!(
        tree.get_sudt_balance(CKB_SUDT_ACCOUNT_ID, beneficiary_id)
            .unwrap(),
        0
    );

    let run_result = deploy(
        &generator,
        &mut tree,
        creator_account_id,
        from_id,
        INIT_CODE,
        122000,
        0,
        block_number,
    );
    block_number += 1;
    let new_account_script = new_account_script_with_nonce(from_id, 1);
    let new_account_id = tree
        .get_account_id_by_script_hash(&new_account_script.hash().into())
        .unwrap()
        .unwrap();

    assert_eq!(tree.get_nonce(from_id).unwrap(), 2);
    assert_eq!(tree.get_nonce(sd_account_id).unwrap(), 0);
    assert_eq!(tree.get_nonce(new_account_id).unwrap(), 0);

    {
        // call CallSelfDestruct.proxyDone(sd_account_id);
        let block_info = new_block_info(0, block_number, block_number);
        let input = hex::decode(format!(
            "9a33d968{}",
            hex::encode(account_id_to_eth_address(sd_account_id, true)),
        ))
        .unwrap();
        let args = PolyjuiceArgsBuilder::default()
            .gas_limit(100000)
            .gas_price(1)
            .value(0)
            .input(&input)
            .build();
        let raw_tx = RawL2Transaction::new_builder()
            .from_id(from_id.pack())
            .to_id(new_account_id.pack())
            .args(Bytes::from(args).pack())
            .build();
        let run_result = generator
            .execute(&tree, &block_info, &raw_tx)
            .expect("construct");
        tree.apply_run_result(&run_result).expect("update state");
    }

    assert_eq!(tree.get_nonce(from_id).unwrap(), 3);
    assert_eq!(tree.get_nonce(sd_account_id).unwrap(), 0);
    assert_eq!(tree.get_nonce(new_account_id).unwrap(), 1);
    assert_eq!(
        tree.get_sudt_balance(CKB_SUDT_ACCOUNT_ID, sd_account_id)
            .unwrap(),
        0
    );
    assert_eq!(
        tree.get_sudt_balance(CKB_SUDT_ACCOUNT_ID, beneficiary_id)
            .unwrap(),
        200
    );

    block_number += 1;

    {
        // call SelfDestruct.done();
        let block_info = new_block_info(0, block_number, block_number);
        let input = hex::decode("ae8421e1").unwrap();
        let args = PolyjuiceArgsBuilder::default()
            .gas_limit(31000)
            .gas_price(1)
            .value(0)
            .input(&input)
            .build();
        let raw_tx = RawL2Transaction::new_builder()
            .from_id(from_id.pack())
            .to_id(sd_account_id.pack())
            .args(Bytes::from(args).pack())
            .build();
        let result = generator.execute(&tree, &block_info, &raw_tx);
        println!("result {:?}", result);
        assert!(result.is_err());
    }

    {
        // call CallSelfDestruct.proxyDone(sd_account_id);
        let block_info = new_block_info(0, block_number, block_number);
        let input = hex::decode(format!(
            "9a33d968{}",
            hex::encode(account_id_to_eth_address(sd_account_id, true)),
        ))
        .unwrap();
        let args = PolyjuiceArgsBuilder::default()
            .gas_limit(31000)
            .gas_price(1)
            .value(0)
            .input(&input)
            .build();
        let raw_tx = RawL2Transaction::new_builder()
            .from_id(from_id.pack())
            .to_id(new_account_id.pack())
            .args(Bytes::from(args).pack())
            .build();
        let result = generator.execute(&tree, &block_info, &raw_tx);
        println!("result {:?}", result);
        assert!(result.is_err());
    }
}
