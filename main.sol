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
    event TierMultiplierSet(uint8 tier, uint256 multiplierBps);
    event CooldownBlocksSet(uint256 blocks);

    // -------------------------------------------------------------------------
    // Constants (unique values per contract)
    // -------------------------------------------------------------------------
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MIN_TURBO_DEPOSIT_WEI = 0.01 ether;
    uint256 public constant MAX_TIER_INDEX = 4;
    uint256 public constant DEFAULT_COOLDOWN_BLOCKS = 150;
    uint256 public constant PROTOCOL_SHARE_BPS = 320;

    // -------------------------------------------------------------------------
    // Immutables (constructor-set; no readonly)
    // -------------------------------------------------------------------------
    address public immutable manifoldController;
    address public immutable exhaustPort;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    bool private _intakePaused;
    bool private _reentrancyLock;
    uint256 public cooldownBlocks;
    uint256 public totalIntakeDeposits;
    uint256 public totalRewardPoolWei;
    uint256 public protocolAccruedWei;

    mapping(address => TurboSession) public turboSessionOf;
    mapping(address => uint256) public lastDisengageBlockOf;
    mapping(uint8 => uint256) public tierMultiplierBps; // e.g. 12000 = 120%
    mapping(address => uint256) public pendingBoostRewardOf;
