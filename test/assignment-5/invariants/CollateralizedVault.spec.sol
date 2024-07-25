// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title InvariantsSpec
/// @notice Invariants specification for the protocol
/// @dev Contains pseudo code and description for the invariants in the protocol

abstract contract InvariantsSpec {


// Sum of deposits ≤ contract collateral balance - invariant_CollateralPreservation
// Sum of borrows + repayments = initial contract underlying balance - invariant_UnderlyingPreservation
// No price change, single block, no way for positions to become unhealthy - invariant_NoUnhealthyPositions - separate suite with no creation of unhealthy positions
// No price change, no way for protocol to become insolvent - invariant_NoInsolventPositions
// No insolvent positions, overcollateralized position gets liquidated, protocol stays overcollateralized - invariant_OvercollateralizedProtocol
// Debt can always be repaid by any amount - fuzz testing?
// Collateral can always be withdrawn down to the healthy position level - invariant_WithdrawalDownToHealthy
// Unhealthy positions can't increase in debt (except for borrowing interest, and for liquidations) - invariant_UnhealthyDoNotIncreaseDebt
// Interest rate can't grow beyond hard-coded limit for any period of time
// A position can only be liquidated if it is unhealthy - unit testing?
// 
// If lending out deposits:
// Sum of deposits ≤ outstanding debt + contract balance
// 0% rate, no price change, no way for positions to become unhealthy
// 0% rate, price change below overcollateralization, no way for positions to become insolvent
//
// If using deposit and borrow caps:
// The individual and total deposits are under the respective caps at the end of any transaction
//
// If using aggregated deposit and borrow counters:
// The aggregated deposit counter is the sum of all deposits
// The aggregated borrow counter is the sum of all borrows
}