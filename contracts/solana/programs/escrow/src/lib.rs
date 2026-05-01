use anchor_lang::prelude::*;
use anchor_spl::token::{Token, TokenAccount};

mod state;
mod instructions;
use state::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

// Hub relayer pubkey — replace before deploy
const RELAYER_PUBKEY: &str = "YOUR_RELAYER_SOLANA_PUBKEY";

#[program]
pub mod escrow {
    use super::*;

    pub fn release_to_beneficiary(
        ctx: Context<ReleaseToBeneficiary>,
        transfer_id: [u8; 32],
        amount: u64,
        evm_sender: [u8; 20],
        source_zone: [u8; 32],
    ) -> Result<()> {
        instructions::release::handler(ctx, transfer_id, amount, evm_sender, source_zone)
    }

    pub fn mark_refunded(
        ctx: Context<MarkRefunded>,
        transfer_id: [u8; 32],
    ) -> Result<()> {
        instructions::refund::handler(ctx, transfer_id)
    }
}

#[derive(Accounts)]
#[instruction(transfer_id: [u8; 32])]
pub struct ReleaseToBeneficiary<'info> {
    #[account(mut, constraint = relayer.key().to_string() == RELAYER_PUBKEY)]
    pub relayer: Signer<'info>,

    // init prevents double-release — PDA only creatable once per transfer_id
    #[account(
        init,
        payer = relayer,
        space = EscrowState::LEN,
        seeds = [b"escrow", transfer_id.as_ref()],
        bump
    )]
    pub escrow_state: Account<'info, EscrowState>,

    #[account(mut)]
    pub reserve_pool: Account<'info, TokenAccount>,

    #[account(mut)]
    pub beneficiary_token_account: Account<'info, TokenAccount>,

    pub token_program:  Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(transfer_id: [u8; 32])]
pub struct MarkRefunded<'info> {
    #[account(
        mut,
        seeds = [b"escrow", transfer_id.as_ref()],
        bump = escrow_state.bump
    )]
    pub escrow_state: Account<'info, EscrowState>,
}
