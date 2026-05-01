use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer as SplTransfer};
use crate::state::*;
use crate::ReleaseToBeneficiary;

#[event]
pub struct EscrowReleased {
    pub transfer_id: [u8; 32],
    pub beneficiary: Pubkey,
    pub amount:      u64,
}

pub fn handler(
    ctx: Context<ReleaseToBeneficiary>,
    transfer_id: [u8; 32],
    amount: u64,
    evm_sender: [u8; 20],
    source_zone: [u8; 32],
) -> Result<()> {
    let escrow = &mut ctx.accounts.escrow_state;
    let clock = Clock::get()?;

    escrow.transfer_id = transfer_id;
    escrow.source_zone = source_zone;
    escrow.evm_sender  = evm_sender;
    escrow.beneficiary = ctx.accounts.beneficiary_token_account.owner;
    escrow.mint        = ctx.accounts.reserve_pool.mint;
    escrow.amount      = amount;
    escrow.created_at  = clock.unix_timestamp;
    escrow.status      = EscrowStatus::Released;
    escrow.bump        = ctx.bumps.escrow_state;

    // PDA signs via seeds — reserve_pool delegate must be set to escrow_state PDA
    let seeds = &[
        b"escrow".as_ref(),
        transfer_id.as_ref(),
        &[ctx.bumps.escrow_state],
    ];
    let signer_seeds = &[&seeds[..]];

    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.reserve_pool.to_account_info(),
                to:        ctx.accounts.beneficiary_token_account.to_account_info(),
                authority: ctx.accounts.escrow_state.to_account_info(),
            },
            signer_seeds,
        ),
        amount,
    )?;

    emit!(EscrowReleased {
        transfer_id,
        beneficiary: ctx.accounts.beneficiary_token_account.owner,
        amount,
    });

    Ok(())
}
