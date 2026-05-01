use anchor_lang::prelude::*;

#[account]
pub struct EscrowState {
    pub transfer_id: [u8; 32],  // matches EVM bytes32 transferId
    pub source_zone: [u8; 32],  // "evm:amoy" padded to 32 bytes
    pub evm_sender:  [u8; 20],  // EVM sender address
    pub beneficiary: Pubkey,    // Solana recipient
    pub mint:        Pubkey,    // wINRX SPL token mint
    pub amount:      u64,       // SPL units (6 decimals)
    pub created_at:  i64,       // unix timestamp
    pub status:      EscrowStatus,
    pub bump:        u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum EscrowStatus {
    Locked,
    Released,
    Refunded,
}

impl EscrowState {
    pub const LEN: usize = 8   // discriminator
        + 32 + 32 + 20 + 32 + 32 + 8 + 8 + 1 + 1 + 32; // padding
}
