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

    struct TurboSession {
        uint8 tier;
        uint256 depositWei;
        uint256 engagedAtBlock;
        uint256 expiresAtBlock;
        bool active;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier whenIntakeNotPaused() {
        if (_intakePaused) revert IntakePaused();
        _;
    }

    modifier onlyManifoldController() {
        if (msg.sender != manifoldController) revert NotManifoldController();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock) revert ReentrancyLocked();
        _reentrancyLock = true;
        _;
        _reentrancyLock = false;
    }

    // -------------------------------------------------------------------------
    // Constructor (authority addresses passed in; populated with unique values)
    // -------------------------------------------------------------------------
    constructor() {
        manifoldController = 0x7E2f3A4b5C6d7e8F9012345678901234567890aBc;
        exhaustPort = 0x9F1e2D3c4B5a6E7f8901234567890AbCdEf12345;
        cooldownBlocks = DEFAULT_COOLDOWN_BLOCKS;
        _intakePaused = false;

        tierMultiplierBps[0] = 10_000;  // 100%
        tierMultiplierBps[1] = 11_500;  // 115%
        tierMultiplierBps[2] = 13_200;  // 132%
        tierMultiplierBps[3] = 15_100;  // 151%
        tierMultiplierBps[4] = 17_200;  // 172%
    }

    // -------------------------------------------------------------------------
    // External: engage turbo (user deposits ETH, gets tiered boost session)
    // -------------------------------------------------------------------------
    function engageTurbo(uint8 tier) external payable whenIntakeNotPaused nonReentrant {
        if (tier > MAX_TIER_INDEX) revert TierOutOfRange();
        if (tierMultiplierBps[tier] == 0) revert InvalidTierConfig();

        uint256 required = _requiredDepositForTier(tier);
        if (msg.value < required) revert InsufficientIntakeDeposit(required, msg.value);

        TurboSession storage session = turboSessionOf[msg.sender];
        if (session.active) revert NoActiveTurboSession(); // must disengage first

        uint256 durationBlocks = _durationBlocksForTier(tier);
        uint256 expiresAt = block.number + durationBlocks;

        session.tier = tier;
        session.depositWei = msg.value;
        session.engagedAtBlock = block.number;
        session.expiresAtBlock = expiresAt;
        session.active = true;

        totalIntakeDeposits += msg.value;
        uint256 protocolCut = (msg.value * PROTOCOL_SHARE_BPS) / BPS_DENOM;
        protocolAccruedWei += protocolCut;
        totalRewardPoolWei += (msg.value - protocolCut);

        emit TurboEngaged(msg.sender, tier, msg.value, expiresAt);
        emit IntakeDepositReceived(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // External: disengage turbo (after expiry; refund minus protocol share)
    // -------------------------------------------------------------------------
    function disengageTurbo() external nonReentrant {
        TurboSession storage session = turboSessionOf[msg.sender];
        if (!session.active) revert NoActiveTurboSession();
        if (block.number < session.expiresAtBlock) revert TurboSessionNotExpired();

        uint256 refund = _refundAmount(session.depositWei);
        session.active = false;
        totalIntakeDeposits -= session.depositWei;

        lastDisengageBlockOf[msg.sender] = block.number;

        (bool ok,) = msg.sender.call{ value: refund }("");
        require(ok, "clanker_turbocharger: refund failed");

        emit TurboDisengaged(msg.sender, refund);
    }

    // -------------------------------------------------------------------------
    // External: claim accrued boost rewards (from reward pool)
    // -------------------------------------------------------------------------
    function claimRadialBoost() external nonReentrant {
        uint256 amount = pendingBoostRewardOf[msg.sender];
        if (amount == 0) return;

        pendingBoostRewardOf[msg.sender] = 0;
        if (amount > address(this).balance) revert RewardPoolDrainBlocked();

        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "clanker_turbocharger: claim failed");

        emit RadialBoostClaimed(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // External: controller can credit boost rewards to users
    // -------------------------------------------------------------------------
    function creditBoostReward(address user, uint256 amountWei) external onlyManifoldController {
        if (user == address(0)) revert ZeroAddressManifold();
        pendingBoostRewardOf[user] += amountWei;
    }

    // -------------------------------------------------------------------------
    // External: controller can add to reward pool
    // -------------------------------------------------------------------------
    function fundRewardPool() external payable onlyManifoldController {
        if (msg.value > 0) {
            totalRewardPoolWei += msg.value;
        }
    }

    // -------------------------------------------------------------------------
    // External: controller can withdraw protocol share to exhaust port
    // -------------------------------------------------------------------------
    function withdrawProtocolAccrued() external onlyManifoldController nonReentrant {
        uint256 amount = protocolAccruedWei;
        if (amount == 0) return;
        protocolAccruedWei = 0;
        (bool ok,) = exhaustPort.call{ value: amount }("");
        require(ok, "clanker_turbocharger: exhaust transfer failed");
    }

    // -------------------------------------------------------------------------
    // External: controller admin
    // -------------------------------------------------------------------------
    function setIntakePaused(bool paused) external onlyManifoldController {
        _intakePaused = paused;
        emit ManifoldPauseToggled(paused);
    }

    function setCooldownBlocks(uint256 blocks) external onlyManifoldController {
        cooldownBlocks = blocks;
        emit CooldownBlocksSet(blocks);
    }

    function setTierMultiplierBps(uint8 tier, uint256 multiplierBps) external onlyManifoldController {
        if (tier > MAX_TIER_INDEX) revert TierOutOfRange();
        tierMultiplierBps[tier] = multiplierBps;
        emit TierMultiplierSet(tier, multiplierBps);
    }

    // -------------------------------------------------------------------------
    // View: required deposit for tier (scales with tier)
    // -------------------------------------------------------------------------
    function requiredDepositForTier(uint8 tier) external view returns (uint256) {
        if (tier > MAX_TIER_INDEX) revert TierOutOfRange();
        return _requiredDepositForTier(tier);
    }

    // -------------------------------------------------------------------------
    // View: duration in blocks for tier
    // -------------------------------------------------------------------------
    function durationBlocksForTier(uint8 tier) external view returns (uint256) {
        if (tier > MAX_TIER_INDEX) revert TierOutOfRange();
        return _durationBlocksForTier(tier);
    }

    // -------------------------------------------------------------------------
    // View: refund amount after protocol share
    // -------------------------------------------------------------------------
    function refundAmountForDeposit(uint256 depositWei) external pure returns (uint256) {
        return _refundAmount(depositWei);
    }

    // -------------------------------------------------------------------------
    // View: whether user can engage (no active session + cooldown passed)
    // -------------------------------------------------------------------------
    function canEngage(address user) external view returns (bool) {
        if (turboSessionOf[user].active) return false;
        uint256 lastBlock = lastDisengageBlockOf[user];
        if (lastBlock == 0) return true;
        return block.number >= lastBlock + cooldownBlocks;
    }

    // -------------------------------------------------------------------------
    // View: blocks remaining until user can engage again
    // -------------------------------------------------------------------------
    function blocksUntilCanEngage(address user) external view returns (uint256) {
        if (turboSessionOf[user].active) return type(uint256).max;
        uint256 lastBlock = lastDisengageBlockOf[user];
        if (lastBlock == 0) return 0;
        uint256 endBlock = lastBlock + cooldownBlocks;
        if (block.number >= endBlock) return 0;
        return endBlock - block.number;
    }

    // -------------------------------------------------------------------------
    // View: current boost multiplier for user (0 if no active session)
    // -------------------------------------------------------------------------
    function currentBoostMultiplierBps(address user) external view returns (uint256) {
        TurboSession storage session = turboSessionOf[user];
        if (!session.active || block.number >= session.expiresAtBlock) return 10_000;
        return tierMultiplierBps[session.tier];
    }

    // -------------------------------------------------------------------------
    // View: intake paused flag
    // -------------------------------------------------------------------------
    function intakePaused() external view returns (bool) {
        return _intakePaused;
    }

    // -------------------------------------------------------------------------
    // View: session details for user
    // -------------------------------------------------------------------------
    function getSession(address user)
        external
        view
        returns (
            uint8 tier,
            uint256 depositWei,
            uint256 engagedAtBlock,
            uint256 expiresAtBlock,
            bool active
        )
    {
        TurboSession storage s = turboSessionOf[user];
        return (s.tier, s.depositWei, s.engagedAtBlock, s.expiresAtBlock, s.active);
    }

    // -------------------------------------------------------------------------
    // Internal: required deposit scales by tier (tier 0 = min, tier 4 = 5x min)
