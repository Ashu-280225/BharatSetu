use anchor_lang::prelude::*;
use crate::state::*;
use crate::MarkRefunded;

pub fn handler(ctx: Context<MarkRefunded>, _transfer_id: [u8; 32]) -> Result<()> {
    let escrow = &mut ctx.accounts.escrow_state;
    require!(escrow.status == EscrowStatus::Locked, ErrorCode::AlreadyProcessed);
    escrow.status = EscrowStatus::Refunded;
    Ok(())
}

#[error_code]
pub enum ErrorCode {
    #[msg("escrow already released or refunded")]
    AlreadyProcessed,
}
