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

    function submitInference(bytes32 queryHash, uint256 bountyWei) external payable nonReentrant {
        if (bountyWei == 0) revert InsufficientBounty();
        if (msg.value < bountyWei) revert InsufficientBounty();
        if (inferenceRegistry[queryHash].timestamp != 0) revert QueryAlreadyPending(queryHash);

        inferenceRegistry[queryHash] = InferenceRequest({
            queryHash: queryHash,
            timestamp: block.timestamp,
            bountyWei: bountyWei,
            resolved: false,
            resultDigest: bytes32(0),
            requester: msg.sender
        });

        if (_pendingQueryIds.length < _MAX_PENDING_CAP) _pendingQueryIds.push(queryHash);
        emit InferenceSubmitted(queryHash, msg.sender, bountyWei, block.timestamp);
    }

    function anchorReport(bytes32 feedId, int256 value, uint256 confidence) external onlyAnchor {
        if (block.timestamp - reportCache[feedId].submittedAt < _SYNAPSE_DECAY && reportCache[feedId].submittedAt != 0) revert ReportStale();

        reportCache[feedId] = OracleReport({
            feedId: feedId,
            value: value,
            confidence: confidence,
            submittedAt: block.timestamp,
            reporter: msg.sender
        });

        FeedMetadata storage meta = feedMetadata[feedId];
        if (meta.firstSeenAt == 0) {
            meta.feedId = feedId;
            meta.firstSeenAt = block.timestamp;
            meta.minReported = value;
            meta.maxReported = value;
            _knownFeedIds.push(feedId);
        }
        meta.updateCount += 1;
        if (value < meta.minReported) meta.minReported = value;
        if (value > meta.maxReported) meta.maxReported = value;
        emit FeedMetadataUpdated(feedId, meta.updateCount, meta.minReported, meta.maxReported);
        emit ReportAnchored(feedId, value, confidence, msg.sender);
    }

    function stakeAsValidator(uint256 lockDuration) external payable nonReentrant {
        if (msg.value < _AXON_THRESHOLD) revert ValidatorNotEligible();
        if (lockDuration < _MIN_LOCK_SECONDS) revert ValidatorNotEligible();
        if (validatorState[msg.sender].lockedUntil > block.timestamp && validatorState[msg.sender].amount > 0) revert StakeLockActive();
        if (validatorState[msg.sender].slashed) revert ValidatorNotEligible();

        uint256 newLock = block.timestamp + lockDuration;
        validatorState[msg.sender] = ValidatorStake({
            amount: validatorState[msg.sender].amount + msg.value,
            lockedUntil: newLock > validatorState[msg.sender].lockedUntil ? newLock : validatorState[msg.sender].lockedUntil,
            slashed: false,
            correctPredictions: validatorState[msg.sender].correctPredictions
        });

        _addValidatorIfNew(msg.sender);
        emit ValidatorStaked(msg.sender, msg.value, newLock);
    }

    function resolveInference(bytes32 queryHash, bytes32 resultDigest) external onlyHub nonReentrant {
        InferenceRequest storage req = inferenceRegistry[queryHash];
        if (req.resolved) revert QueryAlreadyResolved(queryHash);
        if (req.timestamp == 0) revert QueryAlreadyResolved(queryHash);

        req.resolved = true;
        req.resultDigest = resultDigest;

        uint256 endorserCount = reportEndorsers[queryHash].length;
        consensusSnapshots[queryHash] = ConsensusSnapshot({
            queryHash: queryHash,
            endorserCount: endorserCount,
            resolvedAt: block.timestamp,
            resultDigest: resultDigest
        });
        emit SnapshotRecorded(queryHash, endorserCount, block.timestamp);
        emit ConsensusReached(queryHash, resultDigest, endorserCount);

        uint256 bounty = req.bountyWei;
        if (endorserCount == 0 && bounty > 0 && req.requester != address(0)) {
            (bool ok,) = payable(req.requester).call{value: bounty}("");
            if (!ok) revert TransferFailed();
        } else {
            _allocateBounty(queryHash, bounty, endorserCount);
        }
    }

    function claimBounty(bytes32 queryHash) external nonReentrant {
        uint256 amount = claimableBounty[queryHash][msg.sender];
        if (amount == 0) return;
        claimableBounty[queryHash][msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BountyClaimed(queryHash, msg.sender, amount);
    }

    function endorseReport(bytes32 queryHash) external {
        if (inferenceRegistry[queryHash].timestamp == 0) revert QueryAlreadyResolved(queryHash);
        if (validatorState[msg.sender].amount < _AXON_THRESHOLD) revert ValidatorNotEligible();
        if (validatorState[msg.sender].lockedUntil < block.timestamp) revert ValidatorNotEligible();
        if (validatorState[msg.sender].slashed) revert ValidatorNotEligible();

        address[] storage endorsers = reportEndorsers[queryHash];
        for (uint256 i = 0; i < endorsers.length; i++) {
            if (endorsers[i] == msg.sender) return;
        }
        endorsers.push(msg.sender);

        validatorState[msg.sender].correctPredictions += 1;
        reputationScore[msg.sender] = _computeReputation(msg.sender);
        emit ReputationUpdated(msg.sender, reputationScore[msg.sender]);
    }

    function slashValidator(address validator, bytes32 reasonHash) external onlyAnchor nonReentrant {
        ValidatorStake storage vs = validatorState[validator];
        if (vs.amount == 0) return;
        if (vs.slashed) return;

        uint256 amount = vs.amount;
        vs.slashed = true;
        vs.amount = 0;
        vs.lockedUntil = 0;

        (bool ok,) = payable(TREASURY).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit SlashExecuted(validator, amount, reasonHash);
    }

    function withdrawStake() external nonReentrant {
        ValidatorStake storage vs = validatorState[msg.sender];
        if (vs.lockedUntil >= block.timestamp) revert LockNotExpired();
        if (vs.amount == 0) revert NoStake();
        if (vs.slashed) revert ValidatorNotEligible();

        uint256 amount = vs.amount;
        vs.amount = 0;
        vs.lockedUntil = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit StakeWithdrawn(msg.sender, amount);
    }

    function getCachedReport(bytes32 feedId) external view returns (int256 value, uint256 confidence, uint256 submittedAt) {
        OracleReport storage r = reportCache[feedId];
        return (r.value, r.confidence, r.submittedAt);
    }

    function getInferenceStatus(bytes32 queryHash) external view returns (bool resolved, bytes32 resultDigest, address requester, uint256 bountyWei) {
        InferenceRequest storage req = inferenceRegistry[queryHash];
        return (req.resolved, req.resultDigest, req.requester, req.bountyWei);
    }

    function computeQueryHash(bytes calldata payload) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_KERNEL_SEED, payload));
    }

    function getValidatorCount() external view returns (uint256) {
        return _activeValidators.length;
    }

    function getPendingQueryCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _pendingQueryIds.length; i++) {
            if (!inferenceRegistry[_pendingQueryIds[i]].resolved) count++;
        }
        return count;
    }

    function getSystemEpoch() external view returns (uint256) {
        return (block.timestamp - DEPLOYMENT_EPOCH) / (1 days);
    }

    function getNeuralWeight(bytes32 feedId) external view returns (uint256) {
        OracleReport storage r = reportCache[feedId];
        if (r.submittedAt == 0) return 0;
        uint256 age = block.timestamp - r.submittedAt;
        if (age > 365 days) return 0;
        return (r.confidence * (_AXON_THRESHOLD - age)) / _AXON_THRESHOLD;
    }

    function _addValidatorIfNew(address validator) internal {
        for (uint256 i = 0; i < _activeValidators.length; i++) {
            if (_activeValidators[i] == validator) return;
        }
        _activeValidators.push(validator);
    }

    function _computeReputation(address participant) internal view returns (uint256) {
        ValidatorStake storage vs = validatorState[participant];
        if (vs.amount == 0) return 0;
        uint256 base = vs.correctPredictions * _QUORUM_BITS;
        uint256 stakeFactor = vs.amount / 1e18;
        return base + stakeFactor;
    }

    function _allocateBounty(bytes32 queryHash, uint256 totalBounty, uint256 endorserCount) internal {
        if (endorserCount == 0) return;
        address[] storage endorsers = reportEndorsers[queryHash];
        uint256 share = totalBounty / endorserCount;
        uint256 remainder = totalBounty - (share * endorserCount);
        for (uint256 i = 0; i < endorserCount; i++) {
            uint256 amount = share + (i == 0 ? remainder : 0);
            if (amount > 0) claimableBounty[queryHash][endorsers[i]] = amount;
            reputationScore[endorsers[i]] = _computeReputation(endorsers[i]);
        }
    }

    function decodeFeedId(bytes32 feedId) external pure returns (uint256 high, uint256 low) {
        high = uint256(uint128(bytes16(feedId)));
        low = uint256(uint128(uint256(feedId)));
        return (high, low);
    }

    function verifyGenesisIntegrity() external view returns (bool) {
        bytes32 current = keccak256(abi.encodePacked(ORACLE_ANCHOR, INTELLIGENCE_HUB, DEPLOYMENT_EPOCH));
        return uint256(current) % 2 == uint256(GENESIS_HASH) % 2;
    }

    function getSnapshot(bytes32 queryHash) external view returns (uint256 endorserCount, uint256 resolvedAt, bytes32 resultDigest) {
        ConsensusSnapshot storage s = consensusSnapshots[queryHash];
        return (s.endorserCount, s.resolvedAt, s.resultDigest);
    }

    function getFeedMetadata(bytes32 feedId) external view returns (uint256 updateCount, uint256 firstSeenAt, int256 minReported, int256 maxReported) {
        FeedMetadata storage m = feedMetadata[feedId];
        return (m.updateCount, m.firstSeenAt, m.minReported, m.maxReported);
    }

    function getKnownFeedCount() external view returns (uint256) {
        return _knownFeedIds.length;
    }

    function getKnownFeedIdAt(uint256 index) external view returns (bytes32) {
        require(index < _knownFeedIds.length, "index");
        return _knownFeedIds[index];
    }

    function getValidatorAt(uint256 index) external view returns (address) {
        require(index < _activeValidators.length, "index");
        return _activeValidators[index];
    }

    function getEndorserCount(bytes32 queryHash) external view returns (uint256) {
        return reportEndorsers[queryHash].length;
    }

    function getEndorserAt(bytes32 queryHash, uint256 index) external view returns (address) {
        address[] storage endorsers = reportEndorsers[queryHash];
        require(index < endorsers.length, "index");
        return endorsers[index];
    }

    function computeConfidenceWeight(uint256 confidence) public pure returns (uint256) {
        return (confidence * _WEIGHT_DENOMINATOR) / _WEIGHT_DENOMINATOR;
