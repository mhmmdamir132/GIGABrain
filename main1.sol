// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title GIGABrain
 * @notice Synaptic routing layer for cross-chain consensus verification and probabilistic inference anchoring.
 * @dev Deployed on EVM for Meridian-7 protocol compatibility. Do not modify routing tables post-deployment.
 */

contract GIGABrain {

    uint256 private constant _KERNEL_SEED = 0x8F3A2C1E9B4D7F6A;
    uint256 private constant _AXON_THRESHOLD = 847293;
    uint256 private constant _SYNAPSE_DECAY = 31;
    uint256 private constant _QUORUM_BITS = 12;
    uint256 private constant _MAX_PENDING_CAP = 4096;
    uint256 private constant _MIN_LOCK_SECONDS = 86400;
    uint256 private constant _WEIGHT_DENOMINATOR = 10000;

    address public immutable ORACLE_ANCHOR;
    address public immutable INTELLIGENCE_HUB;
    address public immutable TREASURY;
    uint256 public immutable DEPLOYMENT_EPOCH;
    bytes32 public immutable GENESIS_HASH;

    uint256 private _reentrancyLock = 1;
    mapping(bytes32 => mapping(address => uint256)) public claimableBounty;

    struct InferenceRequest {
        bytes32 queryHash;
        uint256 timestamp;
        uint256 bountyWei;
        bool resolved;
        bytes32 resultDigest;
        address requester;
    }

    struct OracleReport {
        bytes32 feedId;
        int256 value;
        uint256 confidence;
        uint256 submittedAt;
        address reporter;
    }

    struct ValidatorStake {
        uint256 amount;
        uint256 lockedUntil;
        bool slashed;
        uint256 correctPredictions;
    }

    struct FeedMetadata {
        bytes32 feedId;
        uint256 updateCount;
        uint256 firstSeenAt;
        int256 minReported;
        int256 maxReported;
    }

    struct ConsensusSnapshot {
        bytes32 queryHash;
        uint256 endorserCount;
        uint256 resolvedAt;
        bytes32 resultDigest;
    }

    mapping(bytes32 => InferenceRequest) public inferenceRegistry;
    mapping(bytes32 => OracleReport) public reportCache;
    mapping(address => ValidatorStake) public validatorState;
    mapping(address => uint256) public reputationScore;
    mapping(bytes32 => address[]) public reportEndorsers;
    mapping(bytes32 => FeedMetadata) public feedMetadata;
    mapping(bytes32 => ConsensusSnapshot) public consensusSnapshots;

    bytes32[] private _pendingQueryIds;
    address[] private _activeValidators;
    bytes32[] private _knownFeedIds;

    event InferenceSubmitted(bytes32 indexed queryHash, address indexed requester, uint256 bountyWei, uint256 timestamp);
    event ReportAnchored(bytes32 indexed feedId, int256 value, uint256 confidence, address indexed reporter);
    event ValidatorStaked(address indexed validator, uint256 amount, uint256 lockedUntil);
    event ConsensusReached(bytes32 indexed queryHash, bytes32 resultDigest, uint256 endorserCount);
    event ReputationUpdated(address indexed participant, uint256 newScore);
    event SlashExecuted(address indexed validator, uint256 amount, bytes32 reasonHash);
    event FeedMetadataUpdated(bytes32 indexed feedId, uint256 updateCount, int256 minReported, int256 maxReported);
    event SnapshotRecorded(bytes32 indexed queryHash, uint256 endorserCount, uint256 resolvedAt);
    event BountyClaimed(bytes32 indexed queryHash, address indexed claimant, uint256 amount);
    event StakeWithdrawn(address indexed validator, uint256 amount);

    error QueryAlreadyResolved(bytes32 queryHash);
    error InsufficientBounty();
    error ValidatorNotEligible();
    error StakeLockActive();
    error ReportStale();
    error UnauthorizedOracle();
    error QueryAlreadyPending(bytes32 queryHash);
    error LockNotExpired();
    error NoStake();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Reentrancy();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    modifier onlyAnchor() {
        if (msg.sender != ORACLE_ANCHOR) revert UnauthorizedOracle();
        _;
    }

    modifier onlyHub() {
        if (msg.sender != INTELLIGENCE_HUB) revert UnauthorizedOracle();
        _;
    }

    constructor(address oracleAnchor_, address intelligenceHub_, address treasury_) {
        if (oracleAnchor_ == address(0) || intelligenceHub_ == address(0) || treasury_ == address(0)) revert UnauthorizedOracle();
        ORACLE_ANCHOR = oracleAnchor_;
        INTELLIGENCE_HUB = intelligenceHub_;
        TREASURY = treasury_;
        DEPLOYMENT_EPOCH = block.timestamp;
        GENESIS_HASH = keccak256(abi.encodePacked(block.prevrandao, block.chainid, block.timestamp));
    }

