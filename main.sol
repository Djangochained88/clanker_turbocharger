// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title clanker_turbocharger
/// @notice Radial intake manifold for clanker yield compression cycles. Tiered boost engagement with cooldown and reward accrual.
/// @dev Build 8472-K | Intake pressure scales by tier; exhaust port receives protocol share.

contract clanker_turbocharger {
    // -------------------------------------------------------------------------
    // Errors (unique naming)
    // -------------------------------------------------------------------------
    error IntakePaused();
    error NotManifoldController();
    error TierOutOfRange();
    error CooldownStillActive(uint256 blocksRemaining);
    error InsufficientIntakeDeposit(uint256 required, uint256 provided);
    error NoActiveTurboSession();
    error TurboSessionNotExpired();
    error ZeroAddressManifold();
    error ReentrancyLocked();
    error InvalidTierConfig();
    error RewardPoolDrainBlocked();

    // -------------------------------------------------------------------------
    // Events (unique naming)
    // -------------------------------------------------------------------------
    event TurboEngaged(address indexed user, uint8 tier, uint256 depositWei, uint256 expiresAtBlock);
    event TurboDisengaged(address indexed user, uint256 refundWei);
    event RadialBoostClaimed(address indexed user, uint256 amountWei);
    event ManifoldPauseToggled(bool paused);
    event IntakeDepositReceived(address indexed from, uint256 amountWei);
    event ExhaustPortUpdated(address indexed previousPort, address indexed newPort);
